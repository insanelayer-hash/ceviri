#include "zb.h"

#include "npy.h"
#include "zac.h"
#include "zonos3-generation.h"
#include "zonos3-steer.h"
#include "zonos3-text.h"
#include "zonos3.h"

#include <chrono>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <cstring>
#include <map>
#include <optional>
#include <mutex>
#include <string>
#include <vector>

namespace {

struct zb_ctx {
    zonos3_model lm;
    zac_model zac;
    bool lm_loaded = false, zac_loaded = false;
    zonos3_steer_bundle steer;
    bool steer_loaded = false;
    std::mutex busy; // one line at a time
};

std::string g_error;

double ms_since(std::chrono::steady_clock::time_point t0) {
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
}

} // namespace

extern "C" {

const char * zb_last_error(void) { return g_error.c_str(); }

void * zb_open(const char * backbone_gguf, const char * decoder_gguf, int use_gpu) {
    auto * c = new zb_ctx();
    if (!zonos3_model_load(c->lm, backbone_gguf, use_gpu != 0)) {
        g_error = "the voice model could not be loaded";
        zb_close(c);
        return nullptr;
    }
    c->lm_loaded = true;
    if (!zac_load(c->zac, decoder_gguf, use_gpu != 0)) {
        g_error = "the waveform decoder could not be loaded";
        zb_close(c);
        return nullptr;
    }
    c->zac_loaded = true;
    return c;
}

void zb_close(void * handle) {
    auto * c = static_cast<zb_ctx *>(handle);
    if (!c) return;
    if (c->zac_loaded) zac_free(c->zac);
    if (c->lm_loaded) zonos3_model_free(c->lm);
    delete c;
}

int zb_load_voice(const char * npy_path, float * out, int capacity) {
    std::vector<float> data;
    std::vector<int64_t> shape;
    if (!npy::load_f32(npy_path, data, shape) || data.empty() || (int) data.size() > capacity) return 0;
    std::memcpy(out, data.data(), data.size() * sizeof(float));
    return (int) data.size();
}

int zb_sample_rate(void * handle) {
    auto * c = static_cast<zb_ctx *>(handle);
    return c ? c->zac.sample_rate : 0;
}

int zb_rate_buckets(void * handle) {
    auto * c = static_cast<zb_ctx *>(handle);
    if (!c) return 0;
    const int idx = zonos3_condition_index(c->lm, "speaking_rate");
    return idx < 0 || idx >= (int) c->lm.hp.cond_bucket_counts.size() ? 0 : (int) c->lm.hp.cond_bucket_counts[idx];
}

} // extern "C"

static int speak(void * handle, const char * text, const float * voice, int voice_len,
                 const int * ref_codes, int ref_frames, int rate_bucket,
                 int max_frames, unsigned seed, float ** out, zb_timing * timing,
                 const char * controls = nullptr, float temperature = 0.0f,
                 double loudness = 0.0, double bandwidth = 0.0, double rate_cps = 0.0) {
    auto * c = static_cast<zb_ctx *>(handle);
    if (!c || !text || !out) return -1;
    std::lock_guard<std::mutex> lock(c->busy);
    const auto t0 = std::chrono::steady_clock::now();
    zb_timing t = {};

    zonos3_prompt_options opt;
    std::vector<float> speaker; // a copy: some controls move the voice itself
    if (voice) {
        if (voice_len != (int) c->lm.hp.speaker_dim) {
            g_error = "the voice has the wrong size";
            return -1;
        }
        speaker.assign(voice, voice + voice_len);
    } else if (ref_codes && ref_frames > 0) {
        opt.reference_codes = ref_codes;
        opt.reference_frames = std::min(ref_frames, (int) zonos3_generation().reference_max_frames);
    }
    // Condition rows: loudness and bandwidth stay "unknown" (the class one past the last);
    // only the speaking rate is set when asked for.
    const int n_cond = (int) c->lm.hp.cond_bucket_counts.size();
    if (rate_bucket >= 0 && n_cond > 0) {
        opt.condition_buckets.resize(n_cond);
        for (int i = 0; i < n_cond; ++i) opt.condition_buckets[i] = (int32_t) c->lm.hp.cond_bucket_counts[i];
        const int idx = zonos3_condition_index(c->lm, "speaking_rate");
        if (idx >= 0 && idx < n_cond && rate_bucket < (int) c->lm.hp.cond_bucket_counts[idx])
            opt.condition_buckets[idx] = rate_bucket;
    }

    // Delivery controls: "name=dose;name=dose".
    zonos3_steering steering;
    std::string err;
    if (controls && *controls) {
        if (!c->steer_loaded) {
            g_error = "delivery controls need the steering file";
            return -1;
        }
        std::map<std::string, double> doses;
        std::string all = controls;
        size_t pos = 0;
        while (pos < all.size()) {
            size_t end = all.find(';', pos);
            if (end == std::string::npos) end = all.size();
            const std::string item = all.substr(pos, end - pos);
            const size_t eq = item.find('=');
            if (eq != std::string::npos && eq > 0) doses[item.substr(0, eq)] = std::atof(item.c_str() + eq + 1);
            pos = end + 1;
        }
        std::optional<zonos3_steer_release_frames> release;
        const double unset = std::nan("");
        if (!zonos3_steer_request_release(&c->steer, unset, unset, unset, ZONOS3_FRAME_RATE, release, err) ||
            !zonos3_steer_resolve(c->steer, doses, {}, (int) utf8_length(text), ZONOS3_STEER_FRAMES_PER_CHAR,
                                  speaker.empty() ? nullptr : &speaker, steering, err, release ? &*release : nullptr)) {
            g_error = "delivery controls: " + err;
            return -1;
        }
    }
    if (!speaker.empty()) opt.speaker_embedding = speaker.data();

    // Delivery settings given as values: each becomes its class in the model's own tables.
    if (n_cond > 0 && (loudness != 0.0 || bandwidth != 0.0 || rate_cps != 0.0)) {
        if (opt.condition_buckets.empty()) {
            opt.condition_buckets.resize(n_cond);
            for (int i = 0; i < n_cond; ++i) opt.condition_buckets[i] = (int32_t) c->lm.hp.cond_bucket_counts[i];
        }
        const char * names[3] = {"loudness", "fmax", "speaking_rate"};
        const double values[3] = {loudness, bandwidth, rate_cps};
        for (int k = 0; k < 3; ++k) {
            if (values[k] == 0.0) continue;
            const int idx = zonos3_condition_index(c->lm, names[k]);
            if (idx < 0 || idx >= n_cond) continue;
            const int bucket = zonos3_condition_bucket(c->lm, idx, values[k]);
            if (bucket >= 0) opt.condition_buckets[idx] = bucket;
        }
    }

    zonos3_prompt prompt;
    if (!zonos3_build_prompt(c->lm, text, opt, prompt, &err)) {
        g_error = "the line could not be prepared: " + err;
        return -1;
    }
    t.prompt_rows = prompt.n_rows;
    if (max_frames <= 0) max_frames = 450;
    if ((int64_t) prompt.n_rows + max_frames > (int64_t) c->lm.hp.n_ctx_train) {
        g_error = "the line is too long";
        return -1;
    }

    zonos3_sampling sp;
    sp.seed = seed;
    if (temperature > 0) sp.temperature = temperature;
    std::vector<int32_t> generated;
    int eos_frame = -1;
    bool first = true;
    const int n_frames = zonos3_generate(
        c->lm, prompt, max_frames, sp, 1.0f, generated, eos_frame, true, nullptr,
        [&](int, const int32_t *, int) {
            if (first) { t.first_frame_ms = ms_since(t0); first = false; }
            return true;
        },
        &steering);
    if (n_frames <= 0) {
        g_error = "nothing was generated";
        return -1;
    }
    t.frames = n_frames;
    t.generate_ms = ms_since(t0);

    // The audio stream is the silence rows of the prompt followed by the generated rows.
    const int ncb = (int) c->lm.hp.n_codebooks, prefill = prompt.prefill_frames;
    std::vector<int32_t> codes = zonos3_prefill_codes(c->lm, prompt);
    codes.insert(codes.end(), generated.begin(), generated.end());
    std::vector<float> audio;
    const auto t1 = std::chrono::steady_clock::now();
    if (!zac_decode(c->zac, codes.data(), prefill + n_frames, ncb, eos_frame, audio) || audio.empty()) {
        g_error = "the sound could not be decoded";
        return -1;
    }
    const size_t drop = std::min(audio.size(), (size_t) prefill * zac_samples_per_frame(c->zac));
    audio.erase(audio.begin(), audio.begin() + drop);
    const float gain = zac_output_gain(c->zac, -1.0);
    for (float & v : audio) v *= gain;
    zonos3_soft_limit(audio.data(), audio.size());
    t.decode_ms = ms_since(t1);
    t.total_ms = ms_since(t0);

    auto * buf = static_cast<float *>(std::malloc(audio.size() * sizeof(float)));
    if (!buf) return -1;
    std::memcpy(buf, audio.data(), audio.size() * sizeof(float));
    *out = buf;
    if (timing) *timing = t;
    return (int) audio.size();
}


extern "C" {

int zb_speak(void * handle, const char * text, const float * voice, int voice_len, int rate_bucket,
             int max_frames, unsigned seed, float ** out, zb_timing * timing) {
    return speak(handle, text, voice, voice_len, nullptr, 0, rate_bucket, max_frames, seed, out, timing);
}

int zb_load_controls(void * handle, const char * steer_gguf) {
    auto * c = static_cast<zb_ctx *>(handle);
    if (!c) return 0;
    std::string err;
    c->steer_loaded = zonos3_steer_load(c->steer, steer_gguf, c->lm, err);
    if (!c->steer_loaded) g_error = "steering file: " + err;
    return c->steer_loaded ? 1 : 0;
}

int zb_speak_styled(void * handle, const char * text, const float * voice, int voice_len, const char * controls,
                    float temperature, int rate_bucket, int max_frames, unsigned seed, float ** out,
                    zb_timing * timing) {
    return speak(handle, text, voice, voice_len, nullptr, 0, rate_bucket, max_frames, seed, out, timing, controls,
                 temperature);
}

int zb_speak_set(void * handle, const char * text, const float * voice, int voice_len, double loudness_lufs,
                 double bandwidth_hz, double rate_cps, const char * controls, float temperature, int max_frames,
                 unsigned seed, float ** out, zb_timing * timing) {
    return speak(handle, text, voice, voice_len, nullptr, 0, -1, max_frames, seed, out, timing, controls, temperature,
                 loudness_lufs, bandwidth_hz, rate_cps);
}

int zb_speak_like(void * handle, const char * text, const int * ref_codes, int ref_frames, int rate_bucket,
                  int max_frames, unsigned seed, float ** out, zb_timing * timing) {
    return speak(handle, text, nullptr, 0, ref_codes, ref_frames, rate_bucket, max_frames, seed, out, timing);
}

// A .npy file of little-endian 32-bit integers with shape (frames, 10).
int zb_load_codes(const char * npy_path, int * out, int capacity_frames) {
    FILE * f = std::fopen(npy_path, "rb");
    if (!f) return 0;
    unsigned char head[10];
    int frames = 0;
    if (std::fread(head, 1, 10, f) == 10 && !std::memcmp(head, "\x93NUMPY", 6) && head[6] == 1) {
        const size_t hlen = head[8] | (head[9] << 8);
        std::string h(hlen, '\0');
        if (std::fread(&h[0], 1, hlen, f) == hlen && h.find("'<i4'") != std::string::npos &&
            h.find("'fortran_order': False") != std::string::npos) {
            const size_t p = h.find("'shape': (");
            int rows = 0, cols = 0;
            if (p != std::string::npos && std::sscanf(h.c_str() + p, "'shape': (%d, %d", &rows, &cols) == 2 &&
                cols == 10 && rows > 0) {
                rows = std::min(rows, capacity_frames);
                if (std::fread(out, sizeof(int), (size_t) rows * 10, f) == (size_t) rows * 10) frames = rows;
            }
        }
    }
    std::fclose(f);
    return frames;
}

void zb_release(float * samples) { std::free(samples); }

} // extern "C"
