// Command-line check of the bridge: speaks game-like Turkish lines in the model's default
// voices, plain and with delivery controls, and writes WAV files with timings.
#include "zb.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static void write_wav(const std::string & path, const float * x, int n, int rate) {
    FILE * f = std::fopen(path.c_str(), "wb");
    if (!f) return;
    auto u32 = [&](uint32_t v) { std::fwrite(&v, 4, 1, f); };
    auto u16 = [&](uint16_t v) { std::fwrite(&v, 2, 1, f); };
    std::fwrite("RIFF", 1, 4, f); u32(36 + n * 2); std::fwrite("WAVEfmt ", 1, 8, f);
    u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16);
    std::fwrite("data", 1, 4, f); u32(n * 2);
    for (int i = 0; i < n; ++i) {
        float v = x[i] < -1 ? -1 : x[i] > 1 ? 1 : x[i];
        int16_t s = (int16_t) (v * 32767);
        std::fwrite(&s, 2, 1, f);
    }
    std::fclose(f);
}

// compare <backbone> <decoder> <default_voices dir> <out dir> <tag>: Gaspard, two sentences, both
// ways of giving the voice, so different model files can be compared on the same lines.
static int compare(int argc, char ** argv) {
    if (argc < 7) return 2;
    void * h = zb_open(argv[2], argv[3], 0);
    if (!h) { std::fprintf(stderr, "open: %s\n", zb_last_error()); return 1; }
    const std::string base = std::string(argv[4]) + "/French/Gaspard_fr_M_1", out = argv[5], tag = argv[6];
    const char * lines[] = {
        "Aradığınız arayana şuanda ulaşılamıyor. Sesli mesaj bırakın yada daha sonra tekrar deneyin.",
        "Bak, seni son gördüğümde bana borcun vardı. Unuttun mu?",
    };
    std::vector<float> voice(512);
    std::vector<int> codes(900 * 10);
    const int vn = zb_load_voice((base + ".embedding.npy").c_str(), voice.data(), 512);
    const int frames = zb_load_codes((base + ".codes.npy").c_str(), codes.data(), 900);
    for (int li = 0; li < 2; ++li)
        for (int mode = 0; mode < 2; ++mode) {
            float * pcm = nullptr;
            zb_timing t;
            const int n = mode ? zb_speak_like(h, lines[li], codes.data(), frames, -1, 450, 7, &pcm, &t)
                               : zb_speak(h, lines[li], voice.data(), vn, -1, 450, 7, &pcm, &t);
            const std::string name = "gaspard-" + tag + (mode ? "-ornekten" : "-ozetten") + "-cumle" + std::to_string(li + 1);
            if (n < 0) { std::printf("%s: FAILED: %s\n", name.c_str(), zb_last_error()); continue; }
            const double seconds = (double) n / zb_sample_rate(h);
            std::printf("%s: %.2f s of sound; model %.0f ms, decoder %.0f ms, total %.0f ms (%.2fx real time)\n",
                        name.c_str(), seconds, t.generate_ms, t.decode_ms, t.total_ms, t.total_ms / 1000.0 / seconds);
            write_wav(out + "/" + name + ".wav", pcm, n, zb_sample_rate(h));
            zb_release(pcm);
        }
    zb_close(h);
    return 0;
}

// studio <backbone> <decoder> <default_voices dir> <out dir>: the settings of the model's own
// studio (bright, loud, quick) against leaving them to the model, in two voices.
static int studio(int argc, char ** argv) {
    if (argc < 6) return 2;
    void * h = zb_open(argv[2], argv[3], 0);
    if (!h) { std::fprintf(stderr, "open: %s\n", zb_last_error()); return 1; }
    const std::string voices = argv[4], out = argv[5];
    const char * names[][2] = {{"Minjun", "Korean/Minjun_ko_M_1"}, {"Gaspard", "French/Gaspard_fr_M_1"}, {"Ximena", "Spanish/Ximena_es_F_1"}};
    const char * lines[] = {
        "Aradığınız arayana şuanda ulaşılamıyor. Sesli mesaj bırakın yada daha sonra tekrar deneyin.",
        "Çabuk arabaya bin, polisler geliyor!",
        "Bak, seni son gördüğümde bana borcun vardı. Unuttun mu?",
    };
    struct setting { const char * tag; double lufs, hz, cps; };
    const setting settings[] = {{"ayarsiz", 0, 0, 0}, {"studyo", -17.0, 20000.0, 20.3}, {"studyo-orta-hiz", -17.0, 20000.0, 15.0}};
    std::vector<float> voice(512);
    for (auto & nm : names) {
        const int vn = zb_load_voice((voices + "/" + nm[1] + ".embedding.npy").c_str(), voice.data(), 512);
        for (int li = 0; li < 3; ++li) {
            if (std::strcmp(nm[0], "Minjun") && li != 0) continue;
            for (const setting & st : settings) {
                float * pcm = nullptr;
                zb_timing t;
                const int n = zb_speak_set(h, lines[li], voice.data(), vn, st.lufs, st.hz, st.cps, "", 0.0f, 450, 7, &pcm, &t);
                const std::string name = std::string("z-") + nm[0] + "-cumle" + std::to_string(li + 1) + "-" + st.tag;
                if (n < 0) { std::printf("%s: FAILED: %s\n", name.c_str(), zb_last_error()); continue; }
                const double seconds = (double) n / zb_sample_rate(h);
                std::printf("%s: %.2f s of sound; first frame after %.0f ms, total %.0f ms (%.2fx real time)\n",
                            name.c_str(), seconds, t.first_frame_ms, t.total_ms, t.total_ms / 1000.0 / seconds);
                write_wav(out + "/" + name + ".wav", pcm, n, zb_sample_rate(h));
                zb_release(pcm);
            }
        }
    }
    zb_close(h);
    return 0;
}

// lines <backbone> <decoder> <voice.npy> <out dir> <text file>: one WAV per line of the text file,
// spoken the way the iPhone app does today (studio delivery settings, no alignment guard).
static int lines_mode(int argc, char ** argv) {
    if (argc < 7) return 2;
    void * h = zb_open(argv[2], argv[3], 0);
    if (!h) { std::fprintf(stderr, "open: %s\n", zb_last_error()); return 1; }
    std::vector<float> voice(512);
    const int vn = zb_load_voice(argv[4], voice.data(), 512);
    if (vn <= 0) { std::fprintf(stderr, "voice: %s\n", zb_last_error()); return 1; }
    const std::string out = argv[5];
    FILE * f = std::fopen(argv[6], "rb");
    if (!f) return 1;
    char buf[2048];
    int li = 0;
    while (std::fgets(buf, sizeof buf, f)) {
        std::string line = buf;
        while (!line.empty() && (line.back() == '\n' || line.back() == '\r')) line.pop_back();
        if (line.empty()) continue;
        ++li;
        float * pcm = nullptr;
        zb_timing t;
        const int n = zb_speak_set(h, line.c_str(), voice.data(), vn, -17.0, 20000.0, 20.0, "", 0.0f, 450, 7, &pcm, &t);
        const std::string name = "cumle" + std::to_string(li) + "-1-eski";
        if (n < 0) { std::printf("%s: FAILED: %s\n", name.c_str(), zb_last_error()); continue; }
        const double seconds = (double) n / zb_sample_rate(h);
        std::printf("%s: %.2f s of sound; first frame after %.0f ms, total %.0f ms (%.2fx real time)\n",
                    name.c_str(), seconds, t.first_frame_ms, t.total_ms, t.total_ms / 1000.0 / seconds);
        write_wav(out + "/" + name + ".wav", pcm, n, zb_sample_rate(h));
        zb_release(pcm);
    }
    std::fclose(f);
    zb_close(h);
    return 0;
}

// embed <spk-encoder.gguf> <rate> <out file> <in.f32>...: the speaker vector of each recording (raw
// 32-bit float mono samples), written one after another as 192 floats each (zeros when one failed).
static int embed_mode(int argc, char ** argv) {
    if (argc < 6) return 2;
    void * h = zb_voice_open(argv[2], 0);
    if (!h) { std::fprintf(stderr, "the speaker encoder did not load\n"); return 1; }
    const int rate = std::atoi(argv[3]);
    FILE * out = std::fopen(argv[4], "wb");
    if (!out) return 1;
    for (int i = 5; i < argc; ++i) {
        std::vector<float> audio;
        if (FILE * f = std::fopen(argv[i], "rb")) {
            float buf[4096];
            size_t n;
            while ((n = std::fread(buf, sizeof(float), 4096, f)) > 0) audio.insert(audio.end(), buf, buf + n);
            std::fclose(f);
        }
        float v[192] = {0};
        if (zb_voice_embed(h, audio.data(), (int) audio.size(), rate, v, 192) != 192) std::fprintf(stderr, "failed: %s\n", argv[i]);
        std::fwrite(v, sizeof(float), 192, out);
    }
    std::fclose(out);
    zb_voice_close(h);
    return 0;
}

int main(int argc, char ** argv) {
    if (argc > 1 && !std::strcmp(argv[1], "embed")) return embed_mode(argc, argv);
    if (argc > 1 && !std::strcmp(argv[1], "lines")) return lines_mode(argc, argv);
    if (argc > 1 && !std::strcmp(argv[1], "studio")) return studio(argc, argv);
    if (argc > 1 && !std::strcmp(argv[1], "compare")) return compare(argc, argv);
    if (argc < 6) {
        std::fprintf(stderr, "usage: zb-test <backbone.gguf> <decoder.gguf> <steer.gguf> <default_voices dir> <out dir>\n");
        return 2;
    }
    void * h = zb_open(argv[1], argv[2], 0);
    if (!h) { std::fprintf(stderr, "open: %s\n", zb_last_error()); return 1; }
    const bool controls = zb_load_controls(h, argv[3]) == 1;
    if (!controls) std::printf("no delivery controls: %s\n", zb_last_error());
    const std::string voices = argv[4], out = argv[5];
    const char * names[][2] = {
        {"Gaspard", "French/Gaspard_fr_M_1"},
        {"Ximena", "Spanish/Ximena_es_F_1"},
    };
    const char * lines[] = {
        "Hadi ama, bunu ciddi ciddi mi söylüyorsun?",
        "Çabuk arabaya bin, polisler geliyor!",
        "Bak, seni son gördüğümde bana borcun vardı. Unuttun mu?",
    };
    struct style { const char * tag; const char * controls; float temperature; };
    const style styles[] = {
        {"1-duz", "", 0.0f},
        {"2-sohbet", "delivery.conversational=3;expressive.expressive=4", 0.0f},
        {"3-canli", "delivery.conversational=3;expressive.expressive=6;mood.arousal=3", 0.0f},
        {"4-serbest", "", 0.95f},
    };
    std::vector<float> voice(512);
    for (auto & nm : names) {
        const int vn = zb_load_voice((voices + "/" + nm[1] + ".embedding.npy").c_str(), voice.data(), 512);
        for (int li = 0; li < 3; ++li) {
            if (std::strcmp(nm[0], "Gaspard") && li != 2) continue; // the second voice: one line
            for (const style & st : styles) {
                if (*st.controls && !controls) continue;
                float * pcm = nullptr;
                zb_timing t;
                const int n = zb_speak_styled(h, lines[li], voice.data(), vn, st.controls, st.temperature, -1, 450, 7,
                                              &pcm, &t);
                const std::string name = std::string("zonos-") + nm[0] + "-cumle" + std::to_string(li + 1) + "-" + st.tag;
                if (n < 0) { std::printf("%s: FAILED: %s\n", name.c_str(), zb_last_error()); continue; }
                const double seconds = (double) n / zb_sample_rate(h);
                std::printf("%s: %.2f s of sound; first frame after %.0f ms, total %.0f ms (%.2fx real time)\n",
                            name.c_str(), seconds, t.first_frame_ms, t.total_ms, t.total_ms / 1000.0 / seconds);
                write_wav(out + "/" + name + ".wav", pcm, n, zb_sample_rate(h));
                zb_release(pcm);
            }
        }
    }
    zb_close(h);
    return 0;
}
