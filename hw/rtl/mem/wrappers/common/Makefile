# SPDX-License-Identifier: Apache-2.0
# Copyright © 2024-2026 DiVo Gen²AI
#
# Makefile for Vortex DDR controller wrapper standalone verification
# Requires: Verilator 5.020+
# Usage:
#   make all          — build and run all testbenches
#   make passthrough  — build and run passthrough wrapper test
#   make litedram     — build and run litedram wrapper test
#   make ddr3ctrl     — build and run ddr3ctrl wrapper test
#   make cva6_axi     — build and run cva6_axi wrapper test
#   make baiyang      — build and run baiyang DDR4 APB3 init test
#   make clean        — remove all build artifacts

VERILATOR = verilator
VFLAGS = --cc --exe --build -j 0 --language 1800-2012
VFLAGS += -Wno-fatal -Wno-LATCH -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM

WRAP_DIR = ..
TB_DIR   = .

# ============================================================
# Targets
# ============================================================

.PHONY: all passthrough litedram ddr3ctrl cva6_axi baiyang clean

all: passthrough litedram ddr3ctrl cva6_axi baiyang

# --- passthrough (62 tests) ---
passthrough: obj_dir/tb_passthrough
	./obj_dir/tb_passthrough

obj_dir/tb_passthrough: $(TB_DIR)/tb_wrapper_passthrough_standalone.sv \
                         $(WRAP_DIR)/VX_mem_ctrl_wrapper_passthrough.sv \
                         $(TB_DIR)/VX_mock_axi_memory.sv \
                         $(TB_DIR)/main_passthrough.cpp
	$(VERILATOR) $(VFLAGS) -Mdir obj_dir \
		$(TB_DIR)/tb_wrapper_passthrough_standalone.sv \
		$(WRAP_DIR)/VX_mem_ctrl_wrapper_passthrough.sv \
		$(TB_DIR)/VX_mock_axi_memory.sv \
		$(TB_DIR)/main_passthrough.cpp \
		-o tb_passthrough

# --- litedram (20 tests) ---
litedram: obj_dir_ld/tb_litedram
	./obj_dir_ld/tb_litedram

obj_dir_ld/tb_litedram: $(TB_DIR)/tb_wrapper_litedram_standalone.sv \
                         $(WRAP_DIR)/VX_mem_ctrl_wrapper_litedram.sv \
                         $(TB_DIR)/main_wrappers.cpp
	$(VERILATOR) $(VFLAGS) -CFLAGS -DTB_LITEDRAM -Mdir obj_dir_ld \
		$(TB_DIR)/tb_wrapper_litedram_standalone.sv \
		$(WRAP_DIR)/VX_mem_ctrl_wrapper_litedram.sv \
		$(TB_DIR)/main_wrappers.cpp \
		-o tb_litedram

# --- ddr3ctrl (20 tests) ---
ddr3ctrl: obj_dir_ddr3/tb_ddr3ctrl
	./obj_dir_ddr3/tb_ddr3ctrl

obj_dir_ddr3/tb_ddr3ctrl: $(TB_DIR)/tb_wrapper_ddr3ctrl_standalone.sv \
                           $(WRAP_DIR)/VX_mem_ctrl_wrapper_ddr3ctrl.sv \
                           $(TB_DIR)/main_wrappers.cpp
	$(VERILATOR) $(VFLAGS) -CFLAGS -DTB_DDR3CTRL -Mdir obj_dir_ddr3 \
		$(TB_DIR)/tb_wrapper_ddr3ctrl_standalone.sv \
		$(WRAP_DIR)/VX_mem_ctrl_wrapper_ddr3ctrl.sv \
		$(TB_DIR)/main_wrappers.cpp \
		-o tb_ddr3ctrl

# --- cva6_axi (20 tests, passthrough mode) ---
cva6_axi: obj_dir_cva6/tb_cva6
	./obj_dir_cva6/tb_cva6

obj_dir_cva6/tb_cva6: $(TB_DIR)/tb_wrapper_cva6_axi_standalone.sv \
                       $(WRAP_DIR)/VX_mem_ctrl_wrapper_cva6_axi.sv \
                       $(TB_DIR)/main_wrappers.cpp
	$(VERILATOR) $(VFLAGS) -CFLAGS -DTB_CVA6_AXI -Mdir obj_dir_cva6 \
		$(TB_DIR)/tb_wrapper_cva6_axi_standalone.sv \
		$(WRAP_DIR)/VX_mem_ctrl_wrapper_cva6_axi.sv \
		$(TB_DIR)/main_wrappers.cpp \
		-o tb_cva6

# --- baiyang DDR4 (APB3 init, requires ifdef) ---
baiyang: obj_dir_baiyang/tb_baiyang
	./obj_dir_baiyang/tb_baiyang

obj_dir_baiyang/tb_baiyang: $(TB_DIR)/tb_wrapper_baiyang_ddr4_standalone.sv \
                             $(WRAP_DIR)/VX_mem_ctrl_wrapper_baiyang_ddr4.sv \
                             $(TB_DIR)/main_wrappers.cpp
	$(VERILATOR) $(VFLAGS) -DVX_CFG_YUQUAN_MC_ENABLE \
		-CFLAGS -DTB_BAIYANG_DDR4 -Mdir obj_dir_baiyang \
		$(TB_DIR)/tb_wrapper_baiyang_ddr4_standalone.sv \
		$(WRAP_DIR)/VX_mem_ctrl_wrapper_baiyang_ddr4.sv \
		$(TB_DIR)/main_wrappers.cpp \
		-o tb_baiyang

# --- clean ---
clean:
	rm -rf obj_dir obj_dir_ld obj_dir_ddr3 obj_dir_cva6 obj_dir_baiyang
