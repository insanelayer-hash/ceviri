// zb-serve <backbone> <decoder> <tr alignment .json> <port file>: starts the server the way the
// iPhone app does, writes the port it listens on to <port file> and keeps running.
#include "zb.h"

#include <chrono>
#include <cstdio>
#include <thread>

int main(int argc, char ** argv) {
    if (argc < 5) return 2;
    const int port = zb_server_start(argv[1], argv[2], "tr", argv[3], 0);
    if (port <= 0) { std::fprintf(stderr, "the server did not start\n"); return 1; }
    if (FILE * f = std::fopen(argv[4], "w")) { std::fprintf(f, "%d\n", port); std::fclose(f); }
    std::fprintf(stderr, "zb-serve: listening on %d\n", port);
    for (;;) std::this_thread::sleep_for(std::chrono::seconds(60));
}
