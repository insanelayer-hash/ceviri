// Runs ZONOS3-Mini's own server (the code behind Zyphra's playground) inside the app, listening
// on this device only. The app then asks it for speech like any client would, so every line
// goes through the model's full request path: text preparation, short-line handling, the
// alignment guard, the output limiter.
#include "zb.h"

#include "server-embed.h"
#include "httplib.h"

#include <chrono>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {
std::mutex g_mutex;
std::unique_ptr<zonos3_server_ctl> g_ctl;
std::thread g_thread;
}

extern "C" int zb_server_start(const char * backbone_gguf, const char * decoder_gguf, const char * laci_lang,
                               const char * laci_heads_json, int use_gpu) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_ctl && !g_ctl->failed.load() && g_ctl->port.load() > 0) return g_ctl->port.load();
    if (g_thread.joinable()) g_thread.join();   // an earlier start that failed
    g_ctl = std::make_unique<zonos3_server_ctl>();
    std::vector<std::string> args = {
        "zonos3-server", backbone_gguf, "--zac", decoder_gguf, "--host", "127.0.0.1", "--port", "0",
        use_gpu ? "--gpu" : "--cpu",
        "--batch", "1",                     // one line at a time: least memory
        "--zac-threads", "1",
        "--tts-default-voices-dir", "",     // the app sends the voice with each request
    };
    if (laci_lang && *laci_lang && laci_heads_json && *laci_heads_json) {
        args.push_back("--laci-heads");
        args.push_back(std::string(laci_lang) + "=" + laci_heads_json);
    }
    zonos3_server_ctl * ctl = g_ctl.get();
    g_thread = std::thread([args, ctl] {
        std::vector<std::string> copy = args;
        std::vector<char *> argv;
        for (std::string & a : copy) argv.push_back(a.data());
        zonos3_server_main((int) argv.size(), argv.data(), ctl);
        ctl->failed.store(true);            // it returned: no longer serving
    });
    // Loading the model files takes a few seconds; a missing or broken file fails at once.
    for (int i = 0; i < 1800; ++i) {
        if (ctl->port.load() > 0 && ctl->svr.load()) return ctl->port.load();
        if (ctl->failed.load()) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    if (httplib::Server * svr = ctl->svr.load()) svr->stop();
    g_thread.join();
    return -1;
}

extern "C" void zb_server_stop(void) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_ctl) return;
    if (httplib::Server * svr = g_ctl->svr.load()) svr->stop();
    if (g_thread.joinable()) g_thread.join();
    g_ctl.reset();
}
