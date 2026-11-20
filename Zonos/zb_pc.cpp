// zb-pc <models dir> <voice .npy> <tr alignment .json> <result file> [cpu]
//
// Measures on a desktop computer what the iPhone app does on the phone: starts the model's own server
// (on the graphics card unless "cpu" is given), asks it for game-like Turkish lines the way the app does
// (streamed), and writes down how long the first sound and the whole line take. Then times the speaker
// encoder (a recording of a voice -> its speaker vector), alone and while a line is being spoken.
// The result file is plain text in Turkish; two lines are also saved as WAV files next to it.
#include "zb.h"

#include "httplib.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

namespace {
using Clock = std::chrono::steady_clock;
double ms_since(Clock::time_point t) { return std::chrono::duration<double, std::milli>(Clock::now() - t).count(); }

FILE * g_out = nullptr;
void say(const char * fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    std::vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    std::printf("%s\n", buf);
    std::fflush(stdout);
    if (g_out) { std::fprintf(g_out, "%s\r\n", buf); std::fflush(g_out); }
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

std::string json_text(const std::string & s) {
    std::string out = "\"";
    for (char c : s) {
        if (c == '"' || c == '\\') { out += '\\'; out += c; }
        else out += c;
    }
    return out + "\"";
}

void write_wav(const std::string & path, const std::vector<float> & pcm, int rate) {
    FILE * f = std::fopen(path.c_str(), "wb");
    if (!f) return;
    const uint32_t bytes = (uint32_t) pcm.size() * 2, riff = 36 + bytes, fmt = 16, sr = (uint32_t) rate, br = sr * 2;
    const uint16_t one = 1, align = 2, bits = 16;
    std::fwrite("RIFF", 1, 4, f); std::fwrite(&riff, 4, 1, f); std::fwrite("WAVEfmt ", 1, 8, f);
    std::fwrite(&fmt, 4, 1, f); std::fwrite(&one, 2, 1, f); std::fwrite(&one, 2, 1, f); std::fwrite(&sr, 4, 1, f);
    std::fwrite(&br, 4, 1, f); std::fwrite(&align, 2, 1, f); std::fwrite(&bits, 2, 1, f);
    std::fwrite("data", 1, 4, f); std::fwrite(&bytes, 4, 1, f);
    for (float v : pcm) {
        const int16_t s = (int16_t) std::lround(std::max(-1.0f, std::min(1.0f, v)) * 32767.0f);
        std::fwrite(&s, 2, 1, f);
    }
    std::fclose(f);
}

struct Spoken {
    bool ok = false;
    double first_ms = 0;      // request sent -> first audible sound received
    double total_ms = 0;      // request sent -> last byte
    std::vector<float> pcm;   // 44.1 kHz mono
    std::string error;
};

// One line, asked for exactly as the iPhone app asks (streamed float samples, the voice as a speaker vector).
Spoken speak(int port, const std::string & voice_b64, const std::string & text, double rate, int seed) {
    Spoken s;
    httplib::Client cli("127.0.0.1", port);
    cli.set_read_timeout(300, 0);
    cli.set_connection_timeout(10, 0);
    char cond[160];
    std::snprintf(cond, sizeof cond, "{\"loudness\":-17.0,\"fmax\":20000.0,\"speaking_rate\":%.1f}", rate);
    const std::string body = "{\"text\":" + json_text(text) + ",\"language\":\"tr\",\"seed\":" + std::to_string(seed) +
        ",\"stream\":true,\"format\":\"pcm\",\"speaker_mode\":\"embedding\",\"speaker_embedding_base64\":\"" + voice_b64 +
        "\",\"condition_values\":" + cond + "}";
    std::string raw;
    bool heard = false;
    size_t looked = 0;
    const auto t0 = Clock::now();
    httplib::Request req;
    req.method = "POST";
    req.path = "/v2/generate";
    req.headers.emplace("Content-Type", "application/json");
    req.body = body;
    req.content_receiver = [&](const char * data, size_t len, uint64_t, uint64_t) {
        raw.append(data, len);
        // "First sound" = the first sample that is not silence (the app trims leading silence the same way).
        while (!heard && looked + 4 <= raw.size()) {
            float v;
            std::memcpy(&v, raw.data() + looked, 4);
            looked += 4;
            if (std::fabs(v) > 0.006f) { heard = true; s.first_ms = ms_since(t0); }
        }
        return true;
    };
    httplib::Response res;
    httplib::Error err = httplib::Error::Success;
    const bool sent = cli.send(req, res, err);
    s.total_ms = ms_since(t0);
    if (!sent) { s.error = "baglanti hatasi " + std::to_string((int) err); return s; }
    if (res.status != 200) { s.error = "sunucu " + std::to_string(res.status) + ": " + raw.substr(0, 200); return s; }
    s.pcm.resize(raw.size() / 4);
    std::memcpy(s.pcm.data(), raw.data(), s.pcm.size() * 4);
    s.ok = heard && s.pcm.size() > 4410;
    if (!s.ok) s.error = "ses cikmadi";
    return s;
}

double median(std::vector<double> v) {
    if (v.empty()) return 0;
    std::sort(v.begin(), v.end());
    return v[v.size() / 2];
}

double cosine(const float * a, const float * b, int n) {
    double ab = 0, aa = 0, bb = 0;
    for (int i = 0; i < n; ++i) { ab += a[i] * b[i]; aa += a[i] * a[i]; bb += b[i] * b[i]; }
    return aa > 0 && bb > 0 ? ab / std::sqrt(aa * bb) : 0;
}
}

int main(int argc, char ** argv) {
    if (argc < 5) {
        std::fprintf(stderr, "usage: zb-pc <models dir> <voice .npy> <tr alignment .json> <result file> [cpu]\n");
        return 2;
    }
    const std::string models = argv[1], voice_path = argv[2], heads = argv[3], result = argv[4];
    const bool gpu = !(argc > 5 && !std::strcmp(argv[5], "cpu"));
    const std::string dir = result.find_last_of("/\\") == std::string::npos ? "." : result.substr(0, result.find_last_of("/\\"));
    g_out = std::fopen(result.c_str(), "wb");

    const std::string voice_file = read_file(voice_path);
    float voice[512];
    const int voice_n = zb_load_voice(voice_path.c_str(), voice, 512);
    if (voice_file.empty() || voice_n != 192) { say("HATA: ses dosyasi okunamadi: %s", voice_path.c_str()); return 1; }
    const std::string voice_b64 = base64(voice_file);

    say("TR Altyazi - bilgisayar olcumu (%s)", gpu ? "ekran karti" : "islemci");
    say("");
    auto t = Clock::now();
    const int port = zb_server_start((models + "/backbone-ptq-edit.gguf").c_str(), (models + "/zac-keep2.gguf").c_str(), "tr",
                                     heads.c_str(), gpu ? 1 : 0);
    if (port <= 0) { say("HATA: ses modeli acilamadi (gunluk.txt dosyasina bakin)."); return 1; }
    say("Model yuklendi: %.1f sn", ms_since(t) / 1000);

    // The same kind of lines the game produces: short replies and full sentences.
    struct Line { const char * text; double rate; };
    const Line lines[] = {
        {"Evet. İki dakika.", 14},
        {"Merhaba. Joey burada.", 14},
        {"Hey, Joey, bekle biraz.", 14},
        {"Bunu daha önce de konuşmuştuk, değil mi?", 17},
        {"Hey, Joey, arabamı getirmesi için birini gönderir misin?", 17},
        {"Bak, sana bir şey söyleyeceğim ama kimseye anlatmayacağına söz ver.", 20},
        {"Bu şehirde herkes bir şeyler saklıyor, sen de dahil, o yüzden bana ahlak dersi verme.", 20},
    };
    const int n_lines = (int) (sizeof lines / sizeof lines[0]);

    // The first requests after loading are slower (the model warms up); they are shown but not counted.
    t = Clock::now();
    for (int i = 0; i < 2; ++i) {
        const Spoken w = speak(port, voice_b64, "Tamam, hazırım. Başlayalım mı?", 17, 1 + i);
        if (!w.ok) { say("HATA: ilk deneme basarisiz: %s", w.error.c_str()); return 1; }
        say("Isinma %d: ilk ses %.0f ms, tamami %.0f ms", i + 1, w.first_ms, w.total_ms);
    }
    say("");
    say("SES URETIMI (her satir 3 kez; ilk ses = istekten ilk duyulan sese kadar)");
    std::vector<double> firsts, speeds;
    std::vector<float> sample;   // a few seconds of produced speech, for the speaker encoder below
    int failed = 0;
    for (int li = 0; li < n_lines; ++li) {
        std::vector<double> f, tot, secs;
        for (int seed : {3, 7, 11}) {
            const Spoken s = speak(port, voice_b64, lines[li].text, lines[li].rate, seed);
            if (!s.ok) { ++failed; say("  basarisiz: %s", s.error.c_str()); continue; }
            const double seconds = s.pcm.size() / 44100.0;
            f.push_back(s.first_ms); tot.push_back(s.total_ms); secs.push_back(seconds);
            firsts.push_back(s.first_ms); speeds.push_back(seconds * 1000 / s.total_ms);
            if (seed == 3 && (li == 4 || li == 6)) write_wav(dir + (li == 4 ? "/ornek-1.wav" : "/ornek-2.wav"), s.pcm, 44100);
            if (li == 6 && seed == 3) sample = s.pcm;
        }
        if (f.empty()) continue;
        say("  %2d harf: ilk ses %4.0f ms | tamami %5.0f ms | ses %.1f sn | %.1f kat hizli", (int) std::strlen(lines[li].text),
            median(f), median(tot), median(secs), median(secs) * 1000 / median(tot));
    }
    say("");
    say("OZET ses: ilk ses ortanca %.0f ms (en iyi %.0f, en kotu %.0f), uretim hizi %.1f kat, basarisiz %d", median(firsts),
        firsts.empty() ? 0 : *std::min_element(firsts.begin(), firsts.end()),
        firsts.empty() ? 0 : *std::max_element(firsts.begin(), firsts.end()), median(speeds), failed);

    // Speaker encoder: 2 seconds of speech -> speaker vector, as the app does with the game's sound.
    say("");
    say("KONUSANI TANIMA (2 sn'lik sesten ses parmak izi)");
    void * enc = zb_voice_open((models + "/spk-encoder.gguf").c_str(), gpu ? 1 : 0);
    if (!enc || sample.size() < 44100 * 3) {
        say("  HATA: tanima modeli acilamadi ya da ornek ses yok");
    } else {
        // Skip the first half second, take two seconds.
        const float * clip = sample.data() + 22050;
        const int clip_n = 88200;
        float v[512];
        std::vector<double> alone;
        int got = 0;
        for (int i = 0; i < 6; ++i) {
            t = Clock::now();
            got = zb_voice_embed(enc, clip, clip_n, 44100, v, 512);
            const double ms = ms_since(t);
            if (i > 0) alone.push_back(ms);   // the first run warms up
            else say("  ilk calisma (isinma): %.0f ms", ms);
        }
        if (got != 192) say("  HATA: tanima sonuc vermedi");
        else {
            say("  tek basina: ortanca %.0f ms", median(alone));
            say("  uretilen sesin, istenen sese benzerligi: %.2f (0.6 ustu = ayni ses)", cosine(v, voice, 192));
        }
        // The phone's weak spot: recognising a voice while a line is being spoken slows both down.
        std::atomic<bool> stop{false};
        std::vector<double> busy;
        std::thread worker([&] {
            float w[512];
            while (!stop.load()) {
                const auto t1 = Clock::now();
                zb_voice_embed(enc, clip, clip_n, 44100, w, 512);
                busy.push_back(ms_since(t1));
            }
        });
        std::vector<double> f2;
        for (int seed : {3, 7, 11}) {
            const Spoken s = speak(port, voice_b64, lines[4].text, lines[4].rate, seed);
            if (s.ok) f2.push_back(s.first_ms);
        }
        stop.store(true);
        worker.join();
        say("  ikisi ayni anda: ilk ses %.0f ms, tanima %.0f ms", median(f2), median(busy));
        zb_voice_close(enc);
    }
    say("");
    say("Bitti.");
    if (g_out) std::fclose(g_out);
    zb_server_stop();
    return 0;
}
