// The model's speaker encoder: turns a short recording of someone speaking into the
// 192-number speaker vector the model takes as "the voice". The app feeds it the game's
// own sound, so the Turkish line is spoken in the voice of the character who is talking.
#include "zb.h"

#include "spk-encoder.h"

#include <cmath>
#include <cstring>
#include <vector>

extern "C" void * zb_voice_open(const char * spk_encoder_gguf, int use_gpu) {
    auto * m = new spk_model();
    if (!spk_load(*m, spk_encoder_gguf, use_gpu != 0)) {
        spk_free(*m);
        delete m;
        return nullptr;
    }
    return m;
}

extern "C" void zb_voice_close(void * handle) {
    auto * m = static_cast<spk_model *>(handle);
    if (!m) return;
    spk_free(*m);
    delete m;
}

extern "C" int zb_voice_embed(void * handle, const float * audio, int n, int sample_rate, float * out, int capacity) {
    auto * m = static_cast<spk_model *>(handle);
    if (!m || !audio || n <= 0) return 0;
    std::vector<float> embedding;
    if (!spk_embed(*m, audio, n, sample_rate, embedding)) return 0;
    if (embedding.empty() || (int) embedding.size() > capacity) return 0;
    for (float v : embedding)
        if (!std::isfinite(v)) return 0;
    std::memcpy(out, embedding.data(), embedding.size() * sizeof(float));
    return (int) embedding.size();
}
