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
└─────────────────────────────────────────────────────────┘
```

PF 扩展**复用 WGMMA 数据通路**，新增：
- 三角/因果掩码门控（替代标量核软件掩码）
- 在线 Softmax 流水线（VX_tcu_fa.sv，3 级流水，16 项 LUT exp 近似）
- 条件编译隔离（`VX_CFG_TCU_PF_*_ENABLE`），禁用时回退原版 Vortex

---

## 当前状态

| 模块 | 状态 | 说明 |
|------|------|------|
| PF_TMM RTL | ✅ 验证通过 | 0/128 错误，SimX + RTL 仿真一致 |
| PF_FLASH_ATTN RTL | 🔄 调试中 | FP32 算术已验证，uop 展开和 per-thread 分布 bug 修复中 |
| SimX 行为模型 | ✅ 功能完成 | PF_TMM + FA_MMA/FA_SOFTMAX/FA_UPDATE |
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
├── sw/kernel/include/
│   └── vx_pf.h               ← RVDon: PF 扩展 intrinsics
├── tests/regression/pf_tcu/  ← RVDon: PF_TMM/FA 回归测试
├── sim/simx/tcu/
│   └── tcu_unit.cpp           ← RVDon: PF_TMM/FA 行为模型
├── docs/
│   └── opensource-plan.md     ← 开源计划
├── ARCHITECTURE.md
├── CONTRIBUTING.md
├── LICENSE
└── README.md
```

---

## 致谢

- [Vortex RISC-V GPGPU](https://github.com/vortexgpgpu/vortex) — 基础 GPGPU 架构
- [Protenix](https://github.com/bytedance/protenix) — AlphaFold3 开源实现
- [Flash Attention](https://github.com/Dao-AILab/flash-attention) — 在线 Softmax 算法

---

## 许可证

Apache License 2.0 — 详见 [LICENSE](LICENSE)

RVDon 基于 Vortex（Apache 2.0）开发。RVDon 新增代码版权归 DiVo Gen²AI 所有。

© 2024-2026 DiVo Gen²AI — [wangjueju.cn](https://wangjueju.cn) · [jueju.wang](https://jueju.wang)
