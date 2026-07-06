<p align="center">
  <img src="docs/images/DiVo_Gen2AI_Logo_Landscape.svg" alt="DiVo Gen²AI Logo" width="480">
</p>

# RVDon — RISC-V Domain-specific Open Node

> **三角对称矩阵运算 + 因果注意力加速的 RISC-V 扩展架构**
>
> 由 [DiVo Gen²AI](https://wangjueju.cn) 开发 | 基于 [Vortex RISC-V GPU](https://github.com/vortexgpgpu/vortex) | Apache 2.0

---

## RVDon 是什么

RVDon 是在 Vortex RISC-V GPGPU 架构上扩展的**领域专用加速节点**，为两类广泛存在的计算模式提供硬件级加速：

1. **三角对称矩阵运算** — 对称矩阵乘法、图神经网络邻接矩阵、协方差/距离矩阵
2. **因果注意力（Causal Attention）** — 自回归语言模型（GPT/LLaMA）、序列决策、时序预测

这些模式的共同特征是在通用 GPU 上存在严重的计算浪费：
- 对称矩阵只需计算上/下三角，但 WGMMA 仍执行完整矩阵乘后软件掩码——**浪费 ~50% 算力**
- 因果注意力需要下三角掩码 + online softmax，通用 Flash Attention 需多次全局同步——**延迟高、同步开销大**

RVDon 通过 **PF Extension 指令**在 TCU 流水线中原生支持这些模式，消除冗余计算和软件开销。

### 最初动机：Protenix/AlphaFold3 Pairformer

RVDon 最初为蛋白质结构预测中 Pairformer 模块的三角乘法（Triangle Multiplication）和三角注意力（Triangle Attention）而设计。但这两类操作的本质——**对称性掩码矩阵乘**和**因果掩码在线 Softmax**——远不止生物计算：

| 应用领域 | 三角对称运算 | 因果注意力 |
|----------|:----------:|:--------:|
| 蛋白质结构预测（AlphaFold3/Protenix） | ✅ Pairformer | ✅ Triangle Attention |
| 大语言模型（GPT / LLaMA / DeepSeek） | — | ✅ Decoder causal attention |
| 图神经网络（GNN） | ✅ 邻接/度矩阵对称乘 | ✅ Graph attention |
| 分子动力学 / 药物设计 | ✅ 相互作用矩阵 | — |
| 协方差估计 / PCA | ✅ 对称矩阵运算 | — |
| 时序预测 / 强化学习 | — | ✅ 因果序列建模 |
| 视频理解 | — | ✅ 时序因果注意力 |

---

## PF 扩展指令集

| 指令 | funct3 | 功能 | 状态 |
|------|--------|------|------|
| `PF_TMM` | 3 | 出向三角遮罩矩阵乘（Triangle Multiplication Outgoing） | ✅ RTL + SimX |
| `PF_TMM_INC` | 4 | 入向三角遮罩矩阵乘（Triangle Multiplication Incoming） | ✅ RTL + SimX |
| `PF_FLASH_ATTN` | 5 | Flash Attention（FA_MMA / FA_SOFTMAX / FA_UPDATE 子操作） | ✅ RTL + SimX |
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
| PF_FLASH_ATTN RTL | ✅ 验证通过 | 0/128 错误，FA_SOFTMAX online softmax 流水线正确 |
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
| [docs/isa-spec-v1.0.md](docs/isa-spec-v1.0.md) | **PF Extension ISA 规范 v1.0** — 指令编码、语义、寄存器映射、编程模型 |
| [ARCHITECTURE.md](ARCHITECTURE.md) | 架构规范（PF 扩展 ISA、寄存器映射、编程模型） |
| [CONTRIBUTING.md](CONTRIBUTING.md) | 贡献指南 |
| [docs/opensource-plan.md](docs/opensource-plan.md) | 开源计划 |
| [docs/phase2.4-fa-softmax-debug.md](docs/phase2.4-fa-softmax-debug.md) | FA_SOFTMAX 调试报告 |
| [docs/ref-wgmma-engine.md](docs/ref-wgmma-engine.md) | 参考：Vortex WGMMA 引擎设计 |
| [docs/ref-custom-accelerator-isa.md](docs/ref-custom-accelerator-isa.md) | 参考：自定义加速器 ISA 扩展指南 |

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

RVDon 基于 Vortex（Apache 2.0）开发。RVDon 新增代码版权归 DiVo Gen²AI 王掬琅（Peter Wang）· 王潇奕（Shawn Wang）所有。

© 2024-2026 DiVo Gen²AI — 王掬琅（Peter Wang）· 王潇奕（Shawn Wang）— [wangjueju.cn](https://wangjueju.cn) · [jueju.wang](https://jueju.wang)
