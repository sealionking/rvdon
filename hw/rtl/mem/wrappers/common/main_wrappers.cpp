// SPDX-License-Identifier: Apache-2.0
// Copyright © 2024-2026 DiVo Gen²AI
#include <verilated.h>
#include <iostream>

// Generic main for wrapper testbenches
// Usage: tb_litedram or tb_ddr3ctrl

#if defined(TB_LITEDRAM)
#include "Vtb_wrapper_litedram_standalone.h"
#define TOP_TYPE Vtb_wrapper_litedram_standalone
#elif defined(TB_DDR3CTRL)
#include "Vtb_wrapper_ddr3ctrl_standalone.h"
#define TOP_TYPE Vtb_wrapper_ddr3ctrl_standalone
#elif defined(TB_CVA6_AXI)
#include "Vtb_wrapper_cva6_axi_standalone.h"
#define TOP_TYPE Vtb_wrapper_cva6_axi_standalone
#elif defined(TB_BAIYANG_DDR4)
#include "Vtb_wrapper_baiyang_ddr4_standalone.h"
#define TOP_TYPE Vtb_wrapper_baiyang_ddr4_standalone
#else
#error "Define TB_LITEDRAM, TB_DDR3CTRL, TB_CVA6_AXI, or TB_BAIYANG_DDR4"
#endif

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    auto top = std::make_unique<TOP_TYPE>();

    top->reset = 1;
    for (int i = 0; i < 10; i++) {
        top->clk = 0; top->eval();
        top->clk = 1; top->eval();
    }
    top->reset = 0;

    for (int cycle = 0; cycle < 100000 && !Verilated::gotFinish(); cycle++) {
        top->clk = 0; top->eval();
        top->clk = 1; top->eval();
    }
    if (!Verilated::gotFinish()) {
        std::cerr << "WARNING: Simulation did not $finish" << std::endl;
    }
    top->final();
    return 0;
}
