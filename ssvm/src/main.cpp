#include <chrono>
#include <cstdio>
#include <cstring>
#include <iostream>

#include "ssvm.hpp"

int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: ssvm <script.hx> | -e <code> [--time]\n");
        return 2;
    }
    bool showTime = false;
    for (int i = 1; i < argc; i++) if (!strcmp(argv[i], "--time")) showTime = true;
    ssvm::VM vm;
    auto t0 = std::chrono::steady_clock::now();
    try {
        if (!strcmp(argv[1], "-e") && argc >= 3) vm.eval(argv[2], "SScript");
        else vm.evalFile(argv[1]);
    } catch (std::exception& e) {
        fflush(stdout);
        fprintf(stderr, "Error: %s\n", e.what());
        return 1;
    }
    if (showTime) {
        double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        fprintf(stderr, "[%.2f ms]\n", ms);
    }
    return 0;
}
