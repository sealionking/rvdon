// SPDX-License-Identifier: Apache-2.0
// Copyright © 2024-2026 DiVo Gen²AI
#include <verilated.h>
#include "Vtb_wrapper_passthrough_standalone.h"
#include <iostream>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    auto top = std::make_unique<Vtb_wrapper_passthrough_standalone>();

    // Reset for 10 cycles
    top->reset = 1;
    for (int i = 0; i < 10; i++) {
        top->clk = 0;
        top->eval();
        top->clk = 1;
        top->eval();
    }
    top->reset = 0;

    // Run test
    for (int cycle = 0; cycle < 10000 && !Verilated::gotFinish(); cycle++) {
        top->clk = 0;
        top->eval();
        top->clk = 1;
        top->eval();
    }
    if (!Verilated::gotFinish()) {
        std::cerr << "WARNING: Simulation did not $finish" << std::endl;
    }
    top->final();
    return 0;
}
