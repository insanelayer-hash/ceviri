// tr-altyazi-ses <models dir> <built-in voices dir> <tr alignment .json> <settings file> [cpu]
//
// The spoken translation, on a desktop computer with a graphics card. The phone only makes the Turkish
// subtitles; this program waits at the TV for each Turkish line (/lines), listens to the game's sound around
// the moment the line appeared (/voice) to tell who is speaking, makes the line in that character's voice
// with ZONOS3-Mini and hands the sound to the TV (/say), which plays it over the game.
//
// A character heard once is remembered (karakter-sesleri.txt next to the settings file): each character is
// the average of the speaker vectors of their lines, so they keep one steady voice derived from their own.
#include "zb.h"

#include "httplib.h"
#include "json.hpp"

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <deque>
#include <filesystem>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

namespace {
using json = nlohmann::json;
using Clock = std::chrono::steady_clock;
double ms_since(Clock::time_point t) { return std::chrono::duration<double, std::milli>(Clock::now() - t).count(); }

// ---- output: the window and a log file --------------------------------------------------------------
std::mutex g_say_mutex;
FILE * g_log = nullptr;
void say(const char * fmt, ...) {
    char buf[2048];
    va_list ap;
    va_start(ap, fmt);
    std::vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    char stamp[16];
    const std::time_t now = std::time(nullptr);
    std::strftime(stamp, sizeof stamp, "%H:%M:%S", std::localtime(&now));
    std::lock_guard<std::mutex> lock(g_say_mutex);
    std::printf("%s  %s\n", stamp, buf);
    std::fflush(stdout);
    if (g_log) { std::fprintf(g_log, "%s  %s\r\n", stamp, buf); std::fflush(g_log); }
}

std::string read_file(const std::string & path) {
    std::string data;
    if (FILE * f = std::fopen(path.c_str(), "rb")) {
        char buf[65536];
        size_t n;
        while ((n = std::fread(buf, 1, sizeof buf, f)) > 0) data.append(buf, n);
        std::fclose(f);
    }
    return data;
}

std::string base64(const std::string & in) {
    static const char * t = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string out;
    size_t i = 0;
    for (; i + 2 < in.size(); i += 3) {
        const unsigned v = (unsigned char) in[i] << 16 | (unsigned char) in[i + 1] << 8 | (unsigned char) in[i + 2];
        out += t[v >> 18 & 63]; out += t[v >> 12 & 63]; out += t[v >> 6 & 63]; out += t[v & 63];
    }
    if (i + 1 == in.size()) {
        const unsigned v = (unsigned char) in[i] << 16;
        out += t[v >> 18 & 63]; out += t[v >> 12 & 63]; out += "==";
    } else if (i + 2 == in.size()) {
        const unsigned v = (unsigned char) in[i] << 16 | (unsigned char) in[i + 1] << 8;
        out += t[v >> 18 & 63]; out += t[v >> 12 & 63]; out += t[v >> 6 & 63]; out += '=';
    }
    return out;
}

// A speaker vector as the .npy file the model's server takes.
std::string npy(const std::vector<float> & v) {
    std::string header = "{'descr': '<f4', 'fortran_order': False, 'shape': (" + std::to_string(v.size()) + ",), }";
    while ((10 + header.size() + 1) % 64 != 0) header += ' ';
    header += '\n';
    std::string out = "\x93NUMPY";
    out += (char) 1; out += (char) 0;
    out += (char) (header.size() & 0xff); out += (char) (header.size() >> 8);
    out += header;
    out.append((const char *) v.data(), v.size() * sizeof(float));
    return out;
}

std::string url_encode(const std::string & s) {
    std::string out;
    char buf[4];
    for (unsigned char c : s) {
        if (std::isalnum(c) || c == '-' || c == '_' || c == '.') out += (char) c;
        else { std::snprintf(buf, sizeof buf, "%%%02X", c); out += buf; }
    }
    return out;
}

// ---- the cast: the characters heard so far ---------------------------------------------------------
struct Member {
    int number = 0;
    std::vector<float> sum;   // of unit vectors
    float lengths = 0;        // of the vectors' lengths
    float count = 0;
    long long used = 0;       // unix seconds
    float pitch = 0;          // how high the character speaks, Hz (0 = not known)
    std::string voice;        // the built-in voice this character speaks Turkish with
};

struct Match {
    int number = 0;
    std::vector<float> vector;
    float similarity = 0;
    bool is_new = false;
    std::string voice;
    float pitch = 0;
};

float length(const std::vector<float> & v) {
    double s = 0;
    for (float x : v) s += (double) x * x;
    return (float) std::sqrt(s);
}

float cosine(const std::vector<float> & a, const std::vector<float> & b) {
    double dot = 0;
    for (size_t i = 0; i < std::min(a.size(), b.size()); ++i) dot += (double) a[i] * b[i];
    return (float) (dot / std::max((double) length(a) * length(b), 1e-9));
}

class Cast {
public:
    explicit Cast(std::string path) : path_(std::move(path)) { load(); }

    int count() { std::lock_guard<std::mutex> l(m_); return (int) members_.size(); }

    // The known character this clip most resembles. `best` is filled even below the threshold.
    bool recognise(const std::vector<float> & v, float threshold, Match & out) {
        std::lock_guard<std::mutex> l(m_);
        int best = -1;
        float best_s = -1;
        for (size_t i = 0; i < members_.size(); ++i) {
            const float s = cosine(members_[i].sum, v);
            if (s > best_s) { best_s = s; best = (int) i; }
        }
        out.similarity = std::max(best_s, 0.0f);
        if (best < 0 || best_s < threshold) return false;
        members_[best].used = std::time(nullptr);
        out.number = members_[best].number;
        out.vector = voice(members_[best]);
        out.voice = members_[best].voice;
        out.pitch = members_[best].pitch;
        return true;
    }

    // The built-in voice of a character (set once, then kept).
    void set_voice(int number, const std::string & name) {
        std::lock_guard<std::mutex> l(m_);
        for (Member & m : members_) if (m.number == number && m.voice != name) { m.voice = name; save(); }
    }

    // How many characters heard in the last ten minutes speak with each built-in voice.
    std::map<std::string, int> voices_in_use() {
        std::lock_guard<std::mutex> l(m_);
        std::map<std::string, int> n;
        const long long now = std::time(nullptr);
        for (const Member & m : members_) if (!m.voice.empty() && now - m.used < 600) ++n[m.voice];
        return n;
    }

    // Like recognise, but the clip also teaches: it joins the character it matches or becomes a new one.
    Match learn(const std::vector<float> & v, float threshold, float pitch, const std::string & new_voice) {
        std::lock_guard<std::mutex> l(m_);
        const float norm = length(v);
        std::vector<float> unit(v.size());
        for (size_t i = 0; i < v.size(); ++i) unit[i] = v[i] / std::max(norm, 1e-9f);
        int best = -1;
        float best_s = -1;
        for (size_t i = 0; i < members_.size(); ++i) {
            const float s = cosine(members_[i].sum, v);
            if (s > best_s) { best_s = s; best = (int) i; }
        }
        Match out;
        if (best >= 0 && best_s >= threshold) {
            Member & m = members_[best];
            // Later clips count, but the voice must not drift: at most 12 clips' worth of weight.
            if (m.count >= 12) {
                const float keep = 11.0f / 12.0f;
                for (float & x : m.sum) x *= keep;
                m.lengths *= keep;
                m.count *= keep;
            }
            for (size_t i = 0; i < unit.size(); ++i) m.sum[i] += unit[i];
            m.lengths += norm;
            m.count += 1;
            m.used = std::time(nullptr);
            if (pitch > 50 && pitch < 500) m.pitch = m.pitch > 0 ? m.pitch * 0.7f + pitch * 0.3f : pitch;
            if (m.voice.empty()) m.voice = new_voice;
            out.number = m.number; out.vector = voice(m); out.similarity = best_s; out.voice = m.voice; out.pitch = m.pitch;
            save();
            return out;
        }
        if (members_.size() >= 60) {
            size_t oldest = 0;
            for (size_t i = 1; i < members_.size(); ++i) if (members_[i].used < members_[oldest].used) oldest = i;
            members_.erase(members_.begin() + oldest);
        }
        Member m;
        m.number = next_++; m.sum = unit; m.lengths = norm; m.count = 1; m.used = std::time(nullptr);
        m.pitch = pitch > 50 && pitch < 500 ? pitch : 0;
        m.voice = new_voice;
        members_.push_back(m);
        out.number = m.number; out.vector = v; out.similarity = std::max(best_s, 0.0f); out.is_new = true;
        out.voice = m.voice; out.pitch = m.pitch;
        save();
        return out;
    }

    // The character used most recently (for a line whose own sound could not be used).
    bool latest(Match & out) {
        std::lock_guard<std::mutex> l(m_);
        if (members_.empty()) return false;
        size_t best = 0;
        for (size_t i = 1; i < members_.size(); ++i) if (members_[i].used > members_[best].used) best = i;
        out.number = members_[best].number;
        out.vector = voice(members_[best]);
        out.voice = members_[best].voice;
        out.pitch = members_[best].pitch;
        return true;
    }

private:
    static std::vector<float> voice(const Member & m) {
        const float n = length(m.sum);
        const float scale = (m.lengths / m.count) / std::max(n, 1e-9f);
        std::vector<float> v(m.sum.size());
        for (size_t i = 0; i < v.size(); ++i) v[i] = m.sum[i] * scale;
        return v;
    }

    void load() {
        const std::string text = read_file(path_);
        size_t pos = 0;
        bool first = true;
        while (pos < text.size()) {
            size_t end = text.find('\n', pos);
            if (end == std::string::npos) end = text.size();
            const std::string row = text.substr(pos, end - pos);
            pos = end + 1;
            std::vector<std::string> f;
            size_t i = 0;
            while (i < row.size()) {
                while (i < row.size() && (row[i] == ' ' || row[i] == '\r')) ++i;
                size_t j = i;
                while (j < row.size() && row[j] != ' ' && row[j] != '\r') ++j;
                if (j > i) f.push_back(row.substr(i, j - i));
                i = j;
            }
            if (first) { first = false; if (!f.empty()) next_ = std::atoi(f[0].c_str()); continue; }
            // number lengths count used [pitch voice] then the 192 numbers ("-" = no voice yet)
            if (f.size() != 196 && f.size() != 198) continue;
            Member m;
            m.number = std::atoi(f[0].c_str()); m.lengths = (float) std::atof(f[1].c_str()); m.count = (float) std::atof(f[2].c_str());
            m.used = std::atoll(f[3].c_str());
            size_t at = 4;
            if (f.size() == 198) { m.pitch = (float) std::atof(f[4].c_str()); if (f[5] != "-") m.voice = f[5]; at = 6; }
            m.sum.resize(192);
            for (size_t k = 0; k < 192; ++k) m.sum[k] = (float) std::atof(f[at + k].c_str());
            if (m.count > 0) members_.push_back(m);
        }
        for (const Member & m : members_) next_ = std::max(next_, m.number + 1);
    }

    // Call with the lock held.
    void save() {
        const std::string tmp = path_ + ".yeni";
        FILE * f = std::fopen(tmp.c_str(), "w");
        if (!f) return;
        std::fprintf(f, "%d %d\n", next_, (int) members_.size());
        for (const Member & m : members_) {
            std::fprintf(f, "%d %.6g %.6g %lld %.1f %s", m.number, m.lengths, m.count, m.used, m.pitch, m.voice.empty() ? "-" : m.voice.c_str());
            for (float x : m.sum) std::fprintf(f, " %.7g", x);
            std::fprintf(f, "\n");
        }
        std::fclose(f);
        std::remove(path_.c_str());
        std::rename(tmp.c_str(), path_.c_str());
    }

    std::string path_;
    std::mutex m_;
    std::vector<Member> members_;
    int next_ = 1;
};

// ---- sound helpers ---------------------------------------------------------------------------------
bool audible(const std::vector<int16_t> & pcm) {
    if (pcm.empty()) return false;
    double sum = 0;
    for (int16_t s : pcm) { const double v = s / 32768.0; sum += v * v; }
    return std::sqrt(sum / pcm.size()) > 0.0056;
}

// How high the voice in a clip is, Hz: per 40 ms by autocorrelation where the sound is voiced, the median.
// 0 when there is too little voiced sound to tell.
float pitch_of(const std::vector<int16_t> & pcm, int rate) {
    const int n = (int) pcm.size(), window = rate / 25, hop = rate / 50, low = rate / 350, high = std::min(rate / 70, window - 1);
    if (n < window || high <= low) return 0;
    std::vector<float> x(n);
    for (int i = 0; i < n; ++i) x[i] = pcm[i] / 32768.0f;
    std::vector<float> pitches;
    for (int at = 0; at + window <= n; at += hop) {
        float zero = 0;
        for (int j = 0; j < window; ++j) zero += x[at + j] * x[at + j];
        if (zero <= 1e-5f) continue;
        float best = 0;
        int best_lag = 0;
        for (int lag = low; lag <= high; ++lag) {
            float sum = 0;
            for (int j = 0; j < window - lag; ++j) sum += x[at + j] * x[at + j + lag];
            if (sum > best) { best = sum; best_lag = lag; }
        }
        if (best_lag > 0 && best / zero > 0.5f) pitches.push_back((float) rate / best_lag);
    }
    if (pitches.size() < 6) return 0;
    std::sort(pitches.begin(), pitches.end());
    return pitches[pitches.size() / 2];
}

const int kQuiet = 200;   // of 32768: about -44 dB

// A spoken line without its dead air: at most 0.16 s of silence inside it, 15 ms before the first sound
// and 60 ms after the last. Cuts fall inside silence, so nothing clicks.
std::vector<int16_t> tightened(const std::vector<int16_t> & in, int rate) {
    if ((int) in.size() <= rate / 10) return in;
    int first = -1, last = -1;
    for (int i = 0; i < (int) in.size(); ++i) if (std::abs((int) in[i]) >= kQuiet) { if (first < 0) first = i; last = i; }
    if (first < 0) return {};
    const int from = std::max(0, first - rate * 15 / 1000), to = std::min((int) in.size(), last + rate * 60 / 1000);
    std::vector<int16_t> out;
    out.reserve(to - from);
    int quiet = 0;
    for (int i = from; i < to; ++i) {
        if (std::abs((int) in[i]) < kQuiet) { if (++quiet > rate * 16 / 100) continue; }
        else quiet = 0;
        out.push_back(in[i]);
    }
    return out;
}

int letters(const std::string & utf8) {
    int n = 0;
    for (unsigned char c : utf8) if ((c & 0xC0) != 0x80) ++n;
    return n;
}

// ---- settings --------------------------------------------------------------------------------------
struct Settings {
    std::string tv, key;       // both come from the settings file (tv=, anahtar=)
    double max_rate = 20;
    double own_voice = 0;      // how much of the character's own voice goes into the Turkish voice (0..1)
};

Settings read_settings(const std::string & path) {
    Settings s;
    const std::string text = read_file(path);
    size_t pos = 0;
    while (pos < text.size()) {
        size_t end = text.find('\n', pos);
        if (end == std::string::npos) end = text.size();
        std::string line = text.substr(pos, end - pos);
        pos = end + 1;
        while (!line.empty() && (line.back() == '\r' || line.back() == ' ')) line.pop_back();
        const size_t eq = line.find('=');
        if (line.empty() || line[0] == '#' || eq == std::string::npos) continue;
        const std::string k = line.substr(0, eq), v = line.substr(eq + 1);
        if (k == "tv") s.tv = v;
        else if (k == "anahtar") s.key = v;
        else if (k == "hiz") s.max_rate = std::max(10.0, std::min(26.0, std::atof(v.c_str())));
        else if (k == "kendi_ses") s.own_voice = std::max(0.0, std::min(100.0, std::atof(v.c_str()))) / 100.0;
    }
    return s;
}

// ---- the work --------------------------------------------------------------------------------------
struct Line {
    int n = 0, chain = 0;
    std::string t;            // the TV's clock when the line appeared (ticks, kept as text)
    long long ticks = 0;
    std::string tr;
    double text_ms = 0;       // how long after the line appeared its Turkish text was ready
    Clock::time_point seen;   // our clock when the line appeared
};

Settings g_set;
int g_port = 0;               // the model's server on this computer
void * g_encoder = nullptr;
std::mutex g_encoder_mutex;
Cast * g_cast = nullptr;
std::vector<float> g_fallback;

// The model's own voices (clean studio voices that speak Turkish well). A character's voice taken from
// the game is an English speaker's, heard through music and effects: used as it is, the Turkish comes out
// with a foreign accent and slurred. So the voice that speaks is a mix: the built-in voice nearest to the
// character (same kind of voice) with a share of the character's own (Settings.own_voice).
struct BuiltIn { std::string name; std::vector<float> v; bool female; };
std::vector<BuiltIn> g_builtin;

bool is_female_name(const std::string & name) { return name == "Ximena" || name == "Imogen" || name == "Seoyeon"; }

const BuiltIn * builtin_named(const std::string & name) {
    for (const BuiltIn & b : g_builtin) if (b.name == name) return &b;
    return nullptr;
}

// A built-in voice for a character heard for the first time: a man's voice for a man, a woman's for a woman
// (by how high they speak; when that cannot be told, by which built-in voices theirs resembles), and among
// those the one the fewest characters of the last minutes already speak with, so people in a scene differ.
std::string pick_voice(float pitch, const std::vector<float> & heard, const std::map<std::string, int> & in_use) {
    bool female;
    if (pitch > 50) female = pitch >= 165;
    else {
        float best_f = -2, best_m = -2;
        for (const BuiltIn & b : g_builtin) { const float c = cosine(b.v, heard); (b.female ? best_f : best_m) = std::max(b.female ? best_f : best_m, c); }
        female = best_f > best_m;
    }
    const BuiltIn * best = nullptr;
    int best_n = 1 << 30;
    for (const BuiltIn & b : g_builtin) {
        if (b.female != female) continue;
        const auto it = in_use.find(b.name);
        const int n = it == in_use.end() ? 0 : it->second;
        if (n < best_n) { best_n = n; best = &b; }
    }
    return best ? best->name : (g_builtin.empty() ? std::string() : g_builtin.front().name);
}

// The voice that speaks: the character's built-in voice with a share of the character's own (Settings.own_voice).
std::vector<float> speaking_voice(const std::vector<float> & heard, const BuiltIn & base) {
    if (heard.empty() || g_set.own_voice <= 0.005) return base.v;
    if (g_set.own_voice >= 0.995) return heard;
    const float a = (float) g_set.own_voice, hn = std::max(length(heard), 1e-9f), bn = std::max(length(base.v), 1e-9f);
    std::vector<float> mix(heard.size());
    for (size_t i = 0; i < mix.size(); ++i) mix[i] = a * heard[i] / hn + (1 - a) * base.v[i] / bn;
    const float scale = (a * hn + (1 - a) * bn) / std::max(length(mix), 1e-9f);
    for (float & x : mix) x *= scale;
    return mix;
}

// "JASON: Evet." -> "Evet.": a speaker's name in capitals before a colon is a label, not something said.
std::string without_label(const std::string & text) {
    const size_t colon = text.find(':');
    if (colon == std::string::npos || colon < 2 || colon > 28 || colon + 1 >= text.size()) return text;
    static const char * lower_tr[] = {"\xC3\xA7", "\xC4\x9F", "\xC4\xB1", "\xC3\xB6", "\xC5\x9F", "\xC3\xBC"};   // ç ğ ı ö ş ü
    const std::string head = text.substr(0, colon);
    for (char c : head) if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) return text;
    for (const char * l : lower_tr) if (head.find(l) != std::string::npos) return text;
    size_t from = colon + 1;
    while (from < text.size() && text[from] == ' ') ++from;
    return from < text.size() ? text.substr(from) : text;
}

const float kQuickMatch = 0.50f, kSlowMatch = 0.50f;

struct Clip {
    std::vector<int16_t> pcm;
    int rate = 0;
    bool own = false;
};

// The game's sound from `before` ms before to `after` ms after the line appeared.
bool voice_clip(httplib::Client & tv, const Line & line, int before, int after, Clip & out) {
    const std::string path = "/voice?k=" + url_encode(g_set.key) + "&t=" + line.t + "&before=" + std::to_string(before) +
        "&after=" + std::to_string(after);
    auto res = tv.Get(path.c_str());
    if (!res || res->status != 200 || res->body.size() < 2) return false;
    int rate = 0, own = 0;
    if (std::sscanf(res->get_header_value("X-Voice").c_str(), "%d,%d", &rate, &own) != 2 || rate <= 0) return false;
    out.rate = rate; out.own = own != 0;
    out.pcm.resize(res->body.size() / 2);
    std::memcpy(out.pcm.data(), res->body.data(), out.pcm.size() * 2);
    return true;
}

bool embed(const std::vector<int16_t> & pcm, int rate, std::vector<float> & out) {
    std::vector<float> audio(pcm.size());
    for (size_t i = 0; i < pcm.size(); ++i) audio[i] = pcm[i] / 32768.0f;
    float v[512];
    std::lock_guard<std::mutex> lock(g_encoder_mutex);
    const int n = zb_voice_embed(g_encoder, audio.data(), (int) audio.size(), rate, v, 512);
    if (n != 192) return false;
    out.assign(v, v + n);
    return true;
}

// One line as sound (44.1 kHz, 16-bit), dead air removed. Empty on failure.
// The alignment guard is on (laci): the server itself notices when the reading skips words or stops early
// and takes that stretch again.
std::vector<int16_t> synthesize(httplib::Client & model, const std::string & text, const std::vector<float> & voice, double rate, int seed) {
    json body = {
        {"text", text}, {"language", "tr"}, {"seed", seed}, {"stream", false}, {"format", "pcm"}, {"laci", true},
        {"speaker_mode", "embedding"}, {"speaker_embedding_base64", base64(npy(voice))},
        {"condition_values", {{"loudness", -17.0}, {"fmax", 20000.0}, {"speaking_rate", rate}}},
    };
    auto res = model.Post("/v2/generate", body.dump(), "application/json");
    if (!res || res->status != 200) {
        say("  ses modeli hata verdi: %s", res ? res->body.substr(0, 160).c_str() : "yanit yok");
        return {};
    }
    std::vector<int16_t> pcm(res->body.size() / 4);
    for (size_t i = 0; i < pcm.size(); ++i) {
        float v;
        std::memcpy(&v, res->body.data() + i * 4, 4);
        pcm[i] = (int16_t) std::lround(std::max(-1.0f, std::min(1.0f, v)) * 32767.0f);
    }
    return tightened(pcm, 44100);
}

// How fast a line is read: the shorter, the calmer; `faster` for a line that has to catch up.
double reading_rate(const std::string & text, bool faster) {
    const int n = letters(text);
    const double base = n <= 30 ? 14 : n <= 55 ? 17 : 20;
    return std::min(g_set.max_rate, faster ? base + 3 : base);
}

// The lines' starts (TV clock), so a voice is learned only from the part before the next line.
std::mutex g_starts_mutex;
std::map<int, long long> g_starts;

// The folder of the settings file: the characters' clips are kept under it.
std::string g_dir = ".";

// What a character sounds like in the game, kept as klipler/karakterN.wav (16-bit mono, up to 12 seconds, the
// clips the voice was learned from one after another). Reference material for trying other voice models.
void keep_clip(int number, const std::vector<int16_t> & pcm, int rate) {
    std::error_code ec;
    std::filesystem::create_directories(g_dir + "/klipler", ec);
    const std::string path = g_dir + "/klipler/karakter" + std::to_string(number) + ".wav";
    std::string old = read_file(path);
    std::vector<int16_t> all;
    if (old.size() > 44) { all.resize((old.size() - 44) / 2); std::memcpy(all.data(), old.data() + 44, all.size() * 2); }
    if ((int) all.size() >= rate * 12) return;
    all.insert(all.end(), pcm.begin(), pcm.end());
    FILE * f = std::fopen(path.c_str(), "wb");
    if (!f) return;
    const uint32_t bytes = (uint32_t) all.size() * 2, riff = 36 + bytes, fmt = 16, sr = (uint32_t) rate, br = sr * 2;
    const uint16_t one = 1, align = 2, bits = 16;
    std::fwrite("RIFF", 1, 4, f); std::fwrite(&riff, 4, 1, f); std::fwrite("WAVEfmt ", 1, 8, f);
    std::fwrite(&fmt, 4, 1, f); std::fwrite(&one, 2, 1, f); std::fwrite(&one, 2, 1, f); std::fwrite(&sr, 4, 1, f);
    std::fwrite(&br, 4, 1, f); std::fwrite(&align, 2, 1, f); std::fwrite(&bits, 2, 1, f);
    std::fwrite("data", 1, 4, f); std::fwrite(&bytes, 4, 1, f);
    std::fwrite(all.data(), 2, all.size(), f);
    std::fclose(f);
}

// Learning runs behind the speaking: two seconds of the character's line, once they have been said.
struct Lesson { Line line; std::string voice; };
std::mutex g_lessons_mutex;
std::condition_variable g_lessons_cv;
std::deque<Lesson> g_lessons;

void learner() {
    httplib::Client tv(g_set.tv, 8090);
    tv.set_connection_timeout(2, 0);
    tv.set_read_timeout(5, 0);
    tv.set_keep_alive(true);
    for (;;) {
        Lesson lesson;
        {
            std::unique_lock<std::mutex> lock(g_lessons_mutex);
            g_lessons_cv.wait(lock, [] { return !g_lessons.empty(); });
            lesson = g_lessons.front();
            g_lessons.pop_front();
        }
        const Line & line = lesson.line;
        const double wait = 1850 - ms_since(line.seen);
        if (wait > 0) std::this_thread::sleep_for(std::chrono::milliseconds((int) wait));
        Clip clip;
        if (!voice_clip(tv, line, 200, 1800, clip)) { say("  [satir %d] ses ogrenilemedi: klip alinamadi", line.chain); continue; }
        if (clip.own || !audible(clip.pcm)) continue;
        // Only up to the next line: after that somebody else may be talking.
        long long next = 0;
        {
            std::lock_guard<std::mutex> lock(g_starts_mutex);
            for (const auto & kv : g_starts) if (kv.second > line.ticks && (next == 0 || kv.second < next)) next = kv.second;
        }
        if (next != 0) {
            const double seconds = 0.2 + (next - line.ticks) / 1e7 - 0.1;
            if (seconds < 1.0) continue;
            const size_t keep = (size_t) (seconds * clip.rate);
            if (keep < clip.pcm.size()) clip.pcm.resize(keep);
        }
        std::vector<float> v;
        if (!embed(clip.pcm, clip.rate, v)) continue;
        const float pitch = pitch_of(clip.pcm, clip.rate);
        const std::string voice = !lesson.voice.empty() ? lesson.voice : pick_voice(pitch, v, g_cast->voices_in_use());
        const Match m = g_cast->learn(v, kSlowMatch, pitch, voice);
        keep_clip(m.number, clip.pcm, clip.rate);
        say("  [satir %d] ses ogrenildi: karakter %d%s (%.2f), %.0f Hz, sesi %s, %d karakter biliniyor", line.chain, m.number,
            m.is_new ? " YENI" : "", m.similarity, m.pitch, m.voice.c_str(), g_cast->count());
    }
}

struct Spoken { std::string text; Clock::time_point when; };
}

int main(int argc, char ** argv) {
#ifdef _WIN32
    SetConsoleOutputCP(65001);
#endif
    if (argc < 5) {
        std::fprintf(stderr, "usage: tr-altyazi-ses <models dir> <built-in voices dir> <tr alignment .json> <settings file> [cpu]\n");
        return 2;
    }
    const std::string models = argv[1], voices_dir = argv[2], heads = argv[3], settings_path = argv[4];
    const bool gpu = !(argc > 5 && !std::strcmp(argv[5], "cpu"));
    const std::string dir = settings_path.find_last_of("/\\") == std::string::npos ? "." : settings_path.substr(0, settings_path.find_last_of("/\\"));
    g_dir = dir;
    g_log = std::fopen((dir + "/ses-gunluk.txt").c_str(), "wb");
    g_set = read_settings(settings_path);
    if (g_set.key.empty()) { say("HATA: ayar.txt icinde 'anahtar=' satiri yok."); return 1; }
    if (g_set.tv.empty()) { say("HATA: ayar.txt icinde 'tv=' satirina televizyonun adresi yazilmali."); return 1; }

    {
        std::error_code ec;
        for (const auto & entry : std::filesystem::directory_iterator(voices_dir, ec)) {
            if (entry.path().extension() != ".npy") continue;
            float v[512];
            if (zb_load_voice(entry.path().string().c_str(), v, 512) != 192) continue;
            const std::string name = entry.path().stem().string();
            g_builtin.push_back({name, std::vector<float>(v, v + 192), is_female_name(name)});
        }
        std::sort(g_builtin.begin(), g_builtin.end(), [](const BuiltIn & a, const BuiltIn & b) { return a.name < b.name; });
        if (g_builtin.empty()) { say("HATA: hazir sesler okunamadi: %s", voices_dir.c_str()); return 1; }
        g_fallback = g_builtin.front().v;
        for (const BuiltIn & b : g_builtin) if (b.name == "Minjun") g_fallback = b.v;
    }

    say("TR Altyazi - sesli ceviri (%s)", gpu ? "ekran karti" : "islemci");
    say("Ses modeli yukleniyor...");
    g_port = zb_server_start((models + "/backbone-ptq-edit.gguf").c_str(), (models + "/zac-keep2.gguf").c_str(), "tr", heads.c_str(), gpu ? 1 : 0);
    if (g_port <= 0) { say("HATA: ses modeli acilamadi."); return 1; }
    g_encoder = zb_voice_open((models + "/spk-encoder.gguf").c_str(), gpu ? 1 : 0);
    if (!g_encoder) { say("HATA: ses tanima modeli acilamadi."); return 1; }
    Cast cast(dir + "/karakter-sesleri.txt");
    g_cast = &cast;

    httplib::Client model("127.0.0.1", g_port);
    model.set_read_timeout(120, 0);
    model.set_keep_alive(true);
    // The first requests after loading are slow: get them out of the way before the game needs us.
    for (int i = 0; i < 2; ++i) synthesize(model, "Tamam, hazırım. Başlayalım mı?", g_fallback, 17, 1 + i);
    {
        std::vector<int16_t> hum(16000);
        for (size_t i = 0; i < hum.size(); ++i) hum[i] = (int16_t) (3000 * std::sin(i * 0.05));
        std::vector<float> v;
        embed(hum, 16000, v);
    }
    say("Hazir. Kayitli karakter sesi: %d. Karakterin kendi sesinin payi: %%%d. TV: %s", cast.count(), (int) std::lround(g_set.own_voice * 100),
        g_set.tv.c_str());
    say("Bu pencere acik kaldigi surece Turkce altyazilar seslendirilir.");

    std::thread(learner).detach();

    httplib::Client tv(g_set.tv, 8090);       // the waiting request
    tv.set_connection_timeout(3, 0);
    tv.set_read_timeout(14, 0);
    tv.set_keep_alive(true);
    httplib::Client fast(g_set.tv, 8090);     // clips and speech
    fast.set_connection_timeout(2, 0);
    fast.set_read_timeout(4, 0);
    fast.set_keep_alive(true);

    int after = -1;
    bool connected = false, complained = false;
    std::map<int, bool> done;                 // lines already handled (said or passed over)
    std::deque<Spoken> recent;
    Clock::time_point playing_until = Clock::now();
    int seed = 3;

    // One line: who is speaking, the line in their voice, off to the TV.
    auto speak_line = [&](Line line) {
        if (done.count(line.chain)) return;         // a line is said once
        done[line.chain] = true;
        while (done.size() > 200) done.erase(done.begin());
        {
            std::lock_guard<std::mutex> lock(g_starts_mutex);
            g_starts[line.chain] = line.ticks;
            while (g_starts.size() > 40) g_starts.erase(g_starts.begin());
        }
        const std::string text = without_label(line.tr);
        if (letters(text) < 2) return;
        if (ms_since(line.seen) > 4500) { say("[satir %d] gec kaldi, atlandi: %s", line.chain, text.c_str()); return; }
        // The same words again within a few seconds: the subtitle flickered, it is not a new line.
        while (!recent.empty() && ms_since(recent.front().when) > 6000) recent.pop_front();
        for (const Spoken & s : recent) if (s.text == text) return;
        const double waiting = std::chrono::duration<double, std::milli>(playing_until - Clock::now()).count();
        if (waiting > 5000) { say("[satir %d] sirada cok ses var, atlandi: %s", line.chain, text.c_str()); return; }

        // Who is speaking? The game's sound since just before the line appeared.
        std::vector<float> heard;       // the character's own voice (empty: not known)
        std::string who, base_name;     // base_name: the built-in voice the line is spoken with
        bool silent = false, is_new = false;
        for (int attempt = 0; attempt < 2 && heard.empty(); ++attempt) {
            const double need = attempt == 0 ? 450 : 800;
            const double have = ms_since(line.seen);
            if (have < need) std::this_thread::sleep_for(std::chrono::milliseconds((int) (need - have)));
            const int span = (int) std::max(need, std::min(ms_since(line.seen) - 30, 1500.0));
            Clip clip;
            silent = false;
            if (!voice_clip(fast, line, 200, span, clip)) { who = "klip yok"; break; }
            if (clip.own) { who = "kendi sesimiz"; break; }
            if (!audible(clip.pcm)) { who = "sessiz"; silent = true; continue; }
            std::vector<float> v;
            if (!embed(clip.pcm, clip.rate, v)) { who = "tanima hatasi"; break; }
            const float pitch = pitch_of(clip.pcm, clip.rate);
            Match m;
            char buf[128];
            if (cast.recognise(v, kQuickMatch, m)) {
                heard = m.vector;
                base_name = m.voice;
                if (base_name.empty() || !builtin_named(base_name)) {
                    // A character from before voices were given out: gets one now and keeps it.
                    base_name = pick_voice(m.pitch > 50 ? m.pitch : pitch, m.vector, cast.voices_in_use());
                    cast.set_voice(m.number, base_name);
                }
                std::snprintf(buf, sizeof buf, "karakter %d (%.2f)", m.number, m.similarity);
            } else {
                heard = v;      // not heard before
                is_new = true;
                base_name = pick_voice(pitch, v, cast.voices_in_use());
                std::snprintf(buf, sizeof buf, "yeni ses (en yakin %.2f, %.0f Hz)", m.similarity, pitch);
            }
            who = buf;
        }
        // Nothing to hear around the line: nobody is talking, it is a title or a sign on the screen.
        if (silent) { say("[satir %d] konusan yok, okunmadi: %s", line.chain, text.c_str()); return; }
        if (heard.empty()) {
            Match m;
            if (cast.latest(m)) { heard = m.vector; base_name = m.voice; who += ", son konusan karakter " + std::to_string(m.number); }
        }
        const BuiltIn * base = builtin_named(base_name);
        if (!base) { base = builtin_named("Minjun"); if (!base) base = &g_builtin.front(); heard.clear(); who += ", yedek ses"; }
        who += std::string(" -> ") + base->name;
        const std::vector<float> voice = speaking_voice(heard, *base);

        // Speak. A line that will start late is read a little faster. The model now and then answers with
        // a blip or stops early: asked again, the last times in the plain built-in voice, and the longest
        // answer is what gets said, so that no line goes unspoken.
        const bool faster = waiting > 1000;
        // How long the whole line takes at least. Full lines come out at 18-20 letters a second at the rates
        // used here (short ones up to 20 at the calmest rate); a line that is over much sooner than its
        // length allows has lost its end, as "…arabamı getirmesi için" without "birini gönderir misin?".
        const int n_letters = letters(text);
        const double enough = std::max(0.25, n_letters / (reading_rate(text, faster) * (n_letters <= 30 ? 1.45 : n_letters <= 55 ? 1.3 : 1.25)));
        std::vector<int16_t> pcm;
        std::string lengths;
        const auto t0 = Clock::now();
        int tries = 0;
        for (int attempt = 0; attempt < 4; ++attempt) {
            ++tries;
            std::vector<int16_t> got = synthesize(model, text, attempt < 2 ? voice : base->v, reading_rate(text, faster), seed++);
            char one[24];
            std::snprintf(one, sizeof one, "%s%.1f", attempt ? " " : "", got.size() / 44100.0);
            lengths += one;
            if (got.size() > pcm.size()) pcm = std::move(got);
            if (pcm.size() / 44100.0 >= enough) break;
        }
        const double made = ms_since(t0);
        if (pcm.size() / 44100.0 < 0.2) { say("[satir %d] ses uretilemedi (%s sn): %s", line.chain, lengths.c_str(), text.c_str()); return; }
        const bool short_one = pcm.size() / 44100.0 < enough;

        const std::string path = "/say?k=" + url_encode(g_set.key) + "&line=" + std::to_string(line.chain) + "&t=" + line.t + "&rate=44100";
        auto sent = fast.Post(path.c_str(), std::string((const char *) pcm.data(), pcm.size() * 2), "application/octet-stream");
        const double seconds = pcm.size() / 44100.0, total = ms_since(line.seen);
        if (!sent || sent->status != 200 || sent->body.rfind("ok", 0) != 0) {
            say("[satir %d] TV almadi (%s): %s", line.chain, sent ? sent->body.c_str() : "yanit yok", text.c_str());
            return;
        }
        const double queue = std::atof(sent->body.c_str() + 2);
        playing_until = Clock::now() + std::chrono::milliseconds((long long) (queue + seconds * 1000));
        recent.push_back({text, Clock::now()});
        say("[satir %d] %s | metin %.0f ms'de geldi | uretim %.0f ms%s | satirdan %.0f ms sonra%s | %.1f sn | %s", line.chain, who.c_str(),
            line.text_ms, made, tries > 1 ? (" (" + std::to_string(tries) + " deneme: " + lengths + " sn" + (short_one ? ", KISA" : "") + ")").c_str() : "", total,
            queue > 50 ? (", sirada " + std::to_string((int) queue) + " ms").c_str() : "", seconds, text.c_str());
        {
            std::lock_guard<std::mutex> lock(g_lessons_mutex);
            g_lessons.push_back({line, is_new ? base_name : std::string()});
            while (g_lessons.size() > 6) g_lessons.pop_front();
        }
        g_lessons_cv.notify_one();
    };

    // A line whose text may still be replaced by a better translation waits a moment for it.
    struct Waiting { Line line; Clock::time_point until; };
    std::map<int, Waiting> waiting_lines;
    const int kFinalWaitMs = 900;

    for (;;) {
        int wait_ms = 8000;
        for (const auto & kv : waiting_lines) {
            const double left = std::chrono::duration<double, std::milli>(kv.second.until - Clock::now()).count();
            wait_ms = std::max(20, std::min(wait_ms, (int) left));
        }
        auto res = tv.Get(("/lines?k=" + url_encode(g_set.key) + "&after=" + std::to_string(after) + "&wait=" + std::to_string(wait_ms)).c_str());
        const auto got = Clock::now();
        if (!res || res->status != 200) {
            if (!complained) {
                say(res && res->status == 403 ? "TV anahtari kabul etmedi (ayar.txt)." : res && res->status == 404
                        ? "TV'deki uygulama eski surum: once TV'yi guncelleyin." : "TV'ye ulasilamiyor (%s). Bekleniyor...", g_set.tv.c_str());
                complained = true;
            }
            connected = false;
            waiting_lines.clear();
            std::this_thread::sleep_for(std::chrono::seconds(2));
            continue;
        }
        json j = json::parse(res->body, nullptr, false);
        if (j.is_discarded() || !j.contains("n")) { std::this_thread::sleep_for(std::chrono::seconds(1)); continue; }
        if (!connected) { say("TV'ye baglandi."); connected = true; complained = false; }
        const int newest = j["n"].get<int>();
        if (newest < after) {
            // The TV's service started again: its line numbers start over.
            done.clear();
            waiting_lines.clear();
            std::lock_guard<std::mutex> lock(g_starts_mutex);
            g_starts.clear();
        }
        if (after < 0 || newest < after) { after = newest; continue; }
        after = newest;

        for (const auto & e : j["lines"]) {
            Line line;
            line.n = e.value("n", 0);
            line.chain = e.value("line", 0);
            line.t = e.value("t", std::string("0"));
            line.ticks = std::atoll(line.t.c_str());
            line.tr = e.value("tr", std::string());
            const double age = e.value("age", 0.0);
            line.text_ms = age;
            line.seen = got - std::chrono::milliseconds((long long) age);
            for (char & c : line.tr) if (c == '\n' || c == '\r' || c == '\t') c = ' ';
            if (done.count(line.chain)) continue;
            if (e.value("final", 1) == 0) {
                auto it = waiting_lines.find(line.chain);
                if (it == waiting_lines.end()) waiting_lines[line.chain] = {line, Clock::now() + std::chrono::milliseconds(kFinalWaitMs)};
                else it->second.line.tr = line.tr;
                continue;
            }
            waiting_lines.erase(line.chain);
            speak_line(line);
        }
        // The better translation did not come in time: the line is said as it stands.
        for (auto it = waiting_lines.begin(); it != waiting_lines.end();) {
            if (Clock::now() >= it->second.until) { const Line line = it->second.line; it = waiting_lines.erase(it); speak_line(line); }
            else ++it;
        }
    }
}
