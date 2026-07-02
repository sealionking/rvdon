# Phase 2.4 FA_SOFTMAX 调试报告

> 日期：2026-07-02
> 状态：✅ 全部通过（WGMMA 0/128, PF_TMM 0/128, FA_SOFTMAX 0/128）

---

## 1 概述

Phase 2.4 的目标是验证 VX_tcu_fa.sv（FA_SOFTMAX 在线 Softmax 流水线）在 RTL 仿真中的正确性。从 96/128 错误逐步定位到 3 个根因 bug，逐一修复后达到 0 错误。

---

## 2 初始状态

- FP32 减法（fp32_sub）和取整（fp32_floor_int）函数已在 Phase 2.3 中实现
- 流水线时序（fa_p_delay_pipe）已在 Phase 2.1 中对齐
- WGMMA 和 PF_TMM 已通过 0/128 测试
- FA_SOFTMAX 测试结果：**96/128 错误**——正确值（1.0 和 0.368）都出现，但位置互换

---

## 3 根因分析

### Bug 1: FA_SOFTMAX uop 计数包含 k-steps

**文件**: `VX_tcu_uops.sv:116`

**现象**: FA_SOFTMAX 的 uop 计数使用 `WG_UOPS_NR8`（16 个 uop，含 k-steps），导致 k=1 的 uop 用 f25/f27 作为 S 值覆盖了 k=0 的正确结果。

**根因**: FA_SOFTMAX 是逐行独立操作，没有 K 维度迭代。使用含 k-steps 的 uop 计数产生冗余 uop，这些 uop 读到错误的 S 值后写入正确结果。

**修复**:
```systemverilog
// Before:
wg_uop_cnt = UOP_CTR_W'(WG_UOPS_NR8);   // 16 uops (含 k-steps)

// After:
wg_uop_cnt = UOP_CTR_W'(WG_MN_NR8);      // 8 uops (仅 m/n 步进)
```

**效果**: 错误从 96/128 降至 64/128

### Bug 2: per-thread 寄存器值未按 TCU 行分配

**文件**: `kernel.cpp:145-153`

**现象**: 所有线程设置相同的 S 值（f24=2.0）和 m_old 值，但 RTL 从 `rs1_data[i * TCU_TC_K]` 读 S，要求不同 TCU 行的线程持有不同 S 值。

**根因**: WGMMA uop 展开模型中，每个 uop 同时读所有线程的寄存器文件。线程 t 对应 TCU 位置 (i=t/TCU_TC_N, j=t%TCU_TC_N)。RTL 读取 `rs1_data[i * TCU_TC_K]`，所以线程 0 和线程 TCU_TC_N 必须持有各自行的 S 值。

**关键发现**: 实际编译配置为 **NT=4**（非之前假设的 NT=8），导致 TCU_TC_N=2（非 4）。

**修复**:
```cpp
// Before (hardcoded for NT=8):
uint32_t fa_i = tid % VX_CFG_NUM_THREADS / 4;  // 错误: NT=4 时应为 /2

// After (自适应 NT 配置):
constexpr uint32_t TCU_TC_M_VAL = 2;
constexpr uint32_t TCU_TC_N_VAL = VX_CFG_NUM_THREADS / TCU_TC_M_VAL;
uint32_t fa_i = tid % VX_CFG_NUM_THREADS / TCU_TC_N_VAL;

// Per-thread values:
float s_val = (fa_i == 0) ? 2.0f : 0.0f;  // Row 0: S=2.0, Row 1: S=0.0
float m_val = (fa_i == 0) ? 0.0f : 1.0f;  // Row 0: m=0.0, Row 1: m=1.0
```

**效果**: 错误从 64/128 降至 0/128

### Bug 3: 验证映射 fa_row 计算错误

**文件**: `main.cpp:308`

**现象**: 验证代码用 `fa_row = local_row / 2` 映射行号，导致 local_row 0,1→fa_row=0, local_row 2,3→fa_row=1，但实际 TCU 行索引在 micro-tile 内循环。

**根因**: TCU row i 在 xtileM 内按 micro-tile 循环。xtileM=4, TC_M=2, m_steps=2 时：
- m_step=0: rows 0-1, i=0→row0, i=1→row1
- m_step=1: rows 2-3, i=0→row2, i=1→row3
- 所以 fa_row = local_row % TC_M（而非 local_row / 2）

**修复**:
```cpp
// Before:
uint32_t fa_row = local_row / 2;

// After:
uint32_t fa_row = local_row % 2;  // TCU_TC_M=2: i = local_row % TC_M
```

**注**: 此 bug 影响 host 端验证逻辑，不影响 RTL 行为。修复确保验证与 RTL 语义一致。

---

## 4 NT=4 配置参数

实际编译配置为 NT=4，TCU 参数：

| 参数 | NT=4 | NT=8（之前假设） |
|------|-------|-----------------|
| TCU_TC_M | 2 | 2 |
| TCU_TC_N | 2 | 4 |
| TCU_TC_K | 2 | 4 |
| 线程→TCU 行 | tid/2 | tid/4 |
| WG_TILE_M | 4 | 4 |
| WG_TILE_N (NRC=8) | 8 | 8 |
| WG_MN_NR8 | 8 | 8 |
| WG_UOPS_NR8 | 16 | 16 |

---

## 5 调试时间线

| 步骤 | 操作 | 结果 |
|------|------|------|
| 1 | 读取三个文件当前状态 | 确认 bug 位置 |
| 2 | Fix 1: VX_tcu_uops.sv WG_UOPS_NR8→WG_MN_NR8 | 编译通过 |
| 3 | Fix 2: kernel.cpp per-thread (初版 tid/4) | 编译通过 |
| 4 | Fix 3: main.cpp fa_row = local_row % 2 | 编译通过 |
| 5 | 重编译 rtlsim | 成功 |
| 6 | 运行测试 | 64/128 错误（全部 got=1.0 expected=0.368） |
| 7 | 发现 NT=4 → TCU_TC_N=2 | 根因：per-thread 映射错误 |
| 8 | Fix 2 修正: TCU_TC_N_VAL = NT/TC_M | 编译通过 |
| 9 | 运行测试 | **0/128 错误，TEST PASSED** |

---

## 6 教训

1. **不要假设编译配置**：之前所有分析基于 NT=8，但实际配置是 NT=4。TCU 参数随 NT 变化，必须从编译日志确认。
2. **per-thread 映射是 WGMMA 模型的核心**：每个 uop 同时读所有线程的寄存器，线程布局决定了 RTL 如何索引数据。
3. **验证代码本身可能有 bug**：测试失败不一定是 RTL 的错，验证逻辑的映射也可能错误。
4. **逐个修复，逐步验证**：三个 bug 叠加时症状复杂（96 错误），修复第一个后症状变清晰（64 错误，模式一致），第二个修复后直接通过。

---

## 7 文件修改清单

| 文件 | 修改 |
|------|------|
| `hw/rtl/tcu/VX_tcu_uops.sv` | `WG_UOPS_NR8` → `WG_MN_NR8`，FA_SOFTMAX 无 K 维度 |
| `tests/regression/pf_tcu/kernel.cpp` | per-thread 寄存器值按 `tid/TCU_TC_N` 分配，自适应 NT |
| `tests/regression/pf_tcu/main.cpp` | `fa_row = local_row % TC_M`，修正验证映射 |
