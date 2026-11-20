// A small C interface to ZONOS3-Mini's C++ runtime (github.com/Zyphra/ZONOS3-Mini, servers/ggml),
// so the Swift app can load the model once and turn Turkish lines into sound on the phone.
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef struct zb_timing {
    int prompt_rows;      // rows of the prompt (voice, conditions, text)
    int frames;           // generated frames (15 per second of speech)
    double first_frame_ms; // from the call to the first generated frame
    double generate_ms;   // the whole language-model part
    double decode_ms;     // codes -> waveform
    double total_ms;
} zb_timing;

// Loads the backbone and the waveform decoder. Returns NULL on failure (zb_last_error says why).
void * zb_open(const char * backbone_gguf, const char * decoder_gguf, int use_gpu);
void zb_close(void * handle);
const char * zb_last_error(void);

// Reads a voice (a 192-number speaker vector saved as .npy). Returns the count read, 0 on failure.
int zb_load_voice(const char * npy_path, float * out, int capacity);

// Speaks `text`. voice: speaker vector or NULL (the model then picks a voice itself).
// rate_bucket: speaking-rate class, or -1 to leave it to the model. On success returns the
// number of samples (mono float, zb_sample_rate() per second) placed in *out, which the caller
// releases with zb_release; on failure returns -1.
int zb_speak(void * handle, const char * text, const float * voice, int voice_len, int rate_bucket,
             int max_frames, unsigned seed, float ** out, zb_timing * timing);
// The same, in the voice of a reference recording given as its codec codes (a default voice's
// .codes.npy: rows of 10 numbers, 15 rows per second). Closer to the original voice than the
// speaker vector, at the price of a longer prompt. ref_frames may be less than the file holds.
int zb_speak_like(void * handle, const char * text, const int * ref_codes, int ref_frames, int rate_bucket,
                  int max_frames, unsigned seed, float ** out, zb_timing * timing);
// Delivery controls (optional): loads the model's steering file (steer.gguf). Returns 1 on success.
int zb_load_controls(void * handle, const char * steer_gguf);
// Like zb_speak, with delivery controls and sampling temperature. controls: "name=dose;name=dose"
// (for example "delivery.conversational=3;expressive.expressive=4"), or NULL/"" for none;
// needs zb_load_controls. temperature: 0 keeps the model's default (0.75).
int zb_speak_styled(void * handle, const char * text, const float * voice, int voice_len, const char * controls,
                    float temperature, int rate_bucket, int max_frames, unsigned seed, float ** out,
                    zb_timing * timing);
// Like zb_speak_styled, with the model's three delivery settings given as values (the same
// ones its studio shows): loudness in LUFS, bandwidth in Hz and speaking rate in characters
// (bytes) per second. A value of 0 leaves that setting to the model.
int zb_speak_set(void * handle, const char * text, const float * voice, int voice_len, double loudness_lufs,
                 double bandwidth_hz, double rate_cps, const char * controls, float temperature, int max_frames,
                 unsigned seed, float ** out, zb_timing * timing);
// Reads reference codes (.npy, 32-bit integers, [frames, 10]). Returns the frames read, 0 on failure.
int zb_load_codes(const char * npy_path, int * out, int capacity_frames);
void zb_release(float * samples);
int zb_sample_rate(void * handle);
int zb_rate_buckets(void * handle);

// The model's own server inside the app (zb_server.cpp): loads the two model files and listens on
// 127.0.0.1. laci_lang/laci_heads_json: the alignment file of a language ("tr" and its .json), or
// NULL. Returns the port (also when already running), -1 on failure. Do not use zb_open at the
// same time: that would hold the model in memory twice.
int zb_server_start(const char * backbone_gguf, const char * decoder_gguf, const char * laci_lang,
                    const char * laci_heads_json, int use_gpu);
void zb_server_stop(void);

// The speaker encoder (spk-encoder.gguf, zb_voice.cpp): a recording of a voice -> its speaker vector.
// audio: mono samples at 16000 or 44100 per second, ideally one to a few seconds of speech.
// zb_voice_embed returns the count of numbers written to out (192), 0 on failure.
void * zb_voice_open(const char * spk_encoder_gguf, int use_gpu);
int zb_voice_embed(void * handle, const float * audio, int n, int sample_rate, float * out, int capacity);
void zb_voice_close(void * handle);

#ifdef __cplusplus
}
#endif
