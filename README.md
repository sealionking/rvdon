# RVDon — RISC-V Domain-specific Open Node

> **Protenix/AlphaFold3 Pairformer 加速的 RISC-V 扩展架构**
>
> 由 [DiVo Gen²AI](https://wangjueju.cn) 开发 | 基于 [Vortex RISC-V GPU](https://github.com/vortexgpgpu/vortex) | Apache 2.0

---

## RVDon 是什么

RVDon 是在 Vortex RISC-V GPGPU 架构上扩展的**领域专用加速节点**，为蛋白质结构预测（AlphaFold3 / Protenix）中的 Pairformer 模块提供硬件级加速。

Pairformer 的核心计算模式：

- **Triangle Multiplication (Outgoing/Incoming)**：三角矩阵乘法 + 对称性掩码
- **Triangle Attention**：三角注意力 + 因果掩码 + 在线 Softmax

这些模式在通用 GPU 上通过 WGMMA + 软件掩码实现，存在：
1. 掩码逻辑在标量核上串行执行，浪费算力
2. Flash Attention 的 online softmax 需要多次全局同步
3. 三角对称性未被硬件利用，一半计算是冗余的

RVDon 通过 **PF Extension（Pairformer Extension）指令**在 TCU 流水线中原生支持这些模式，消除冗余计算和软件开销。

---

## PF 扩展指令集

| 指令 | funct3 | 功能 | 状态 |
|------|--------|------|------|
| `PF_TMM` | 3 | 出向三角遮罩矩阵乘（Triangle Multiplication Outgoing） | ✅ RTL + SimX |
| `PF_TMM_INC` | 4 | 入向三角遮罩矩阵乘（Triangle Multiplication Incoming） | ✅ RTL + SimX |
| `PF_FLASH_ATTN` | 5 | Flash Attention（FA_MMA / FA_SOFTMAX / FA_UPDATE 子操作） | 🔄 RTL 调试中 |
| `PF_SLOAD` | — | Strided Load | ⏸ 预留 |

详细规范见 [ARCHITECTURE.md](ARCHITECTURE.md)。

---

## 架构概览

```
┌─────────────────────────────────────────────────────────┐
│                    Vortex RISC-V GPU                     │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐              │
│  │  Core 0  │  │  Core 1  │  │  Core N  │  ...         │
│  │ ┌──────┐ │  │ ┌──────┐ │  │ ┌──────┐ │              │
│  │ │ TCU  │ │  │ │ TCU  │ │  │ │ TCU  │ │              │
│  │ │┌────┐│ │  │ │┌────┐│ │  │ │┌────┐│ │              │
│  │ ││WGMMA│ │  │ ││WGMMA│ │  │ ││WGMMA│ │              │
│  │ │├────┤│ │  │ │├────┤│ │  │ │├────┤│ │              │
│  │ ││PF   ││ │  │ ││PF   ││ │  │ ││PF   ││ │  ← RVDon  │
│  │ ││TMM  ││ │  │ ││TMM  ││ │  │ ││TMM  ││ │    扩展    │
│  │ │├────┤│ │  │ │├────┤│ │  │ │├────┤│ │              │
│  │ ││PF   ││ │  │ ││PF   ││ │  │ ││PF   ││ │            │
│  │ ││FA   ││ │  │ ││FA   ││ │  │ ││FA   ││ │            │
│  │ │└────┘│ │  │ │└────┘│ │  │ │└────┘│ │              │
│  │ └──────┘ │  │ └──────┘ │  │ └──────┘ │              │
│  └──────────┘  └──────────┘  └──────────┘              │
│                       │                                  │
│              ┌────────┴────────┐                         │
│              │  Memory Subsystem│                         │
│              │  ┌─────────────┐ │                         │
│              │  │ DramSim     │ │  ← 默认（行为模型）    │
│              │  ├─────────────┤ │                         │
│              │  │ 白杨 MC     │ │  ← VX_CFG_YUQUAN_MC_   │
│              │  │ AXI4→DFI3.1 │ │    ENABLE 条件编译     │
│              │  └─────────────┘ │                         │
│              └─────────────────┘                         │
└─────────────────────────────────────────────────────────┘
```

PF 扩展**复用 WGMMA 数据通路**，新增：
- 三角/因果掩码门控（替代标量核软件掩码）
- 在线 Softmax 流水线（VX_tcu_fa.sv，3 级流水，16 项 LUT exp 近似）
- 条件编译隔离（`VX_CFG_TCU_PF_*_ENABLE`），禁用时回退原版 Vortex

---

## Memory Controller Wrappers

Vortex GPGPU 的内存子系统通过 `VX_mem_axi_bridge` 暴露标准 AXI4 接口。MC Wrappers 提供从 AXI4 到不同 DDR 控制器的适配层，使 Vortex 社区用户可以根据目标平台选择合适的内存控制器。

```
Vortex L3$ → VX_mem_axi_bridge → AXI4 → MC Wrapper → DDR 控制器
```

### 适配矩阵

| Wrapper | 适配控制器 | 数据宽度 | 协议转换 | 验证 |
|---------|-----------|---------|---------|------|
| `passthrough` | 任何同宽 AXI4 控制器 | 512→512 | 直连 | ✅ 62 tests |
| `litedram` | LiteDRAM (enjoy-digital/litedram) | 512→128 | AXI4→Wishbone B4 | ✅ 20 tests |
| `ddr3ctrl` | ultraembedded/ddr3ctrl | 512→128 | AXI4→简单握手 | ✅ 20 tests |
| `cva6_axi` | CVA6 AXI DRAM | 512→512/128 | 直连/宽度适配 | ✅ 20 tests (passthrough) |
| `baiyang_ddr4` | 白杨 (YuQuan) DDR4 | 512→256 | APB3 初始化+AXI4 | ✅ APB3 初始化验证 |

### 独立验证

所有 wrapper 均可通过 Verilator 独立验证，无需完整 Vortex 构建环境：

```bash
cd hw/rtl/mem/wrappers/common
make all    # 构建并运行所有 5 个 wrapper 的测试
```

详细文档见 [docs/memory-controller-integration.md](docs/memory-controller-integration.md)。

---

## 当前状态

| 模块 | 状态 | 说明 |
|------|------|------|
| PF_TMM RTL | ✅ 验证通过 | 0/128 错误，SimX + RTL 仿真一致 |
| PF_FLASH_ATTN RTL | ✅ 验证通过 | 0/128 错误，FA_SOFTMAX online softmax 流水线正确 |
| SimX 行为模型 | ✅ 功能完成 | PF_TMM + FA_MMA/FA_SOFTMAX/FA_UPDATE |
| Memory Controller Wrappers | ✅ Verilator 验证通过 | 5 个 DDR 控制器适配 wrapper，独立可复现 |
| 白杨 (YuQuan) DDR4 MC 集成 | ✅ Phase M0 完成 | 功能验证通过（DramSim 零回归 + 白杨宏启用 PASSED），第三方独立审查 PASS |
| 回归测试 | ✅ 框架就绪 | `tests/regression/pf_tcu/` |
| LLVM intrinsic | ⏸ 待开发 | vx_pf.h 头文件已定义 intrinsics |
| FPGA 原型 | ⏸ 待开发 | — |

---

## 快速开始

### 前置条件

- Vortex 依赖（见 [Vortex README](https://github.com/vortexgpgpu/vortex)）
- Verilator 5.x（RTL 仿真）
- GCC RISC-V 交叉编译器

### 构建

```bash
# 克隆（含 Vortex 上游）
git clone https://github.com/sealionking/rvdon.git
cd rvdon

# 配置 PF 扩展（默认已启用）
# VX_config.toml 中 VX_CFG_TCU_PF_TMM_ENABLE=true
#                VX_CFG_TCU_PF_FA_ENABLE=true

# 构建 RTL 仿真
make -C build64/sim/rtlsim

# 运行 PF_TMM 回归测试
cd build64/tests/regression/pf_tcu
make run-rtlsim
```

### 使用 PF Intrinsics

```cpp
#include "vx_pf.h"

// 三角遮罩矩阵乘（outgoing）
rvdon::pf::pf_tmm_sync<8>(fragC, fragA, fragB, 0);  // RS path

// 三角遮罩矩阵乘（incoming）
rvdon::pf::pf_tmm_inc_sync<8>(fragC, fragA, fragB, 0);

// Flash Attention: MMA 步
rvdon::pf::fa_mma_sync<8>(fragC, fragA, fragB, 0);

// Flash Attention: Online Softmax 步
rvdon::pf::fa_softmax_sync<8>(fragC, fragS, 0);
```

---

## 文档

| 文档 | 说明 |
|------|------|
| [ARCHITECTURE.md](ARCHITECTURE.md) | 架构规范（PF 扩展 ISA、寄存器映射、编程模型） |
| [CONTRIBUTING.md](CONTRIBUTING.md) | 贡献指南 |
| [docs/](docs/) | 设计文档、阶段报告 |

---

## 项目结构

```
rvdon/
├── hw/rtl/tcu/
│   └── VX_tcu_fa.sv          ← RVDon: FA Online Softmax 流水线
├── hw/rtl/mem/
│   ├── VX_mem_axi_bridge.sv  ← Vortex→AXI4 通用桥接器
│   ├── VX_yuquan_wrapper.sv  ← RVDon: 白杨 MC 适配器 (AXI4→DFI3.1)
│   ├── VX_dfi_sim_model.sv   ← RVDon: DFI 3.1 仿真响应模型
│   ├── wrappers/              ← DDR 控制器适配 wrapper 套件
│   │   ├── VX_mem_ctrl_wrapper_passthrough.sv
│   │   ├── VX_mem_ctrl_wrapper_litedram.sv
│   │   ├── VX_mem_ctrl_wrapper_ddr3ctrl.sv
│   │   ├── VX_mem_ctrl_wrapper_cva6_axi.sv
│   │   ├── VX_mem_ctrl_wrapper_baiyang_ddr4.sv
│   │   └── common/            ← 独立验证 testbench + mock memory
│   └── yuquan/               ← 白杨 DDR4 MC RTL (Chisel→SV)
├── sw/kernel/include/
│   └── vx_pf.h               ← RVDon: PF 扩展 intrinsics
├── tests/regression/pf_tcu/  ← RVDon: PF_TMM/FA 回归测试
├── sim/simx/tcu/
│   └── tcu_unit.cpp           ← RVDon: PF_TMM/FA 行为模型
├── docs/
│   ├── memory-controller-integration.md ← MC wrapper 集成指南
│   └── opensource-plan.md     ← 开源计划
├── ARCHITECTURE.md
├── CONTRIBUTING.md
├── LICENSE
└── README.md
```

---

## 致谢

- [Vortex RISC-V GPGPU](https://github.com/vortexgpgpu/vortex) — 基础 GPGPU 架构
- [白杨 (YuQuan) DDR4 控制器](https://github.com/OpenXiangShan/YuQuan) — 开源 DDR4 内存控制器（Mulan PSL v2）
- [LiteDRAM](https://github.com/enjoy-digital/litedram) — 基于 Migen 的 DDR 控制器（BSD-2-Clause）
- [ddr3ctrl](https://github.com/ultraembedded/ddr3ctrl) — 简单 DDR3 控制器（MIT）
- [Protenix](https://github.com/bytedance/protenix) — AlphaFold3 开源实现
- [Flash Attention](https://github.com/Dao-AILab/flash-attention) — 在线 Softmax 算法

---

## 许可证

Apache License 2.0 — 详见 [LICENSE](LICENSE)

RVDon 基于 Vortex（Apache 2.0）开发。RVDon 新增代码版权归 DiVo Gen²AI 王掬琅（Peter Wang）· 王潇奕（Shawn Wang）所有。

白杨 (YuQuan) DDR4 控制器受其独立许可证约束：Copyright © 2021-2026 BOSC / ICT CAS, Mulan PSL v2。

© 2024-2026 DiVo Gen²AI — 王掬琅（Peter Wang）· 王潇奕（Shawn Wang）— [wangjueju.cn](https://wangjueju.cn) · [jueju.wang](https://jueju.wang)
