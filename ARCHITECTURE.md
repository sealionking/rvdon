# RVDon Architecture Specification

> PF Extension ISA v0.1 — Pairformer Extension for Vortex TCU
>
> Copyright © 2024-2026 DiVo Gen²AI — 王掬琅（Peter Wang）· 王潇奕（Shawn Wang）— wangjueju.cn · jueju.wang

---

## 1 概述

PF Extension（Pairformer Extension）是 RVDon 对 Vortex TCU（Tensor Compute Unit）的领域专用扩展，为 AlphaFold3 / Protenix 的 Pairformer 模块提供硬件原生支持。

### 1.1 设计目标

| 目标 | 实现方式 |
|------|----------|
| 消除三角对称冗余计算 | PF_TMM 硬件三角掩码，跳过下三角/上三角的无效乘加 |
| 消除因果掩码软件开销 | PF_FLASH_ATTN FA_MMA 硬件因果掩码 |
| 内联 Online Softmax | PF_FLASH_ATTN FA_SOFTMAX 在线 softmax 流水线，避免全局同步 |
| 零侵入 Vortex 架构 | 复用 WGMMA 数据通路，条件编译隔离 |

### 1.2 编码空间

PF 扩展指令占用 Vortex TCU EXT1 指令的 funct3=3/4/5 空间，funct7=2 不变。

| 指令 | funct7 | funct3 | op_type | 说明 |
|------|--------|--------|---------|------|
| WMMA | 2 | 0 | 0x4 | 上游：标准 WMMA |
| WGMMA | 2 | 1 | 0x5 | 上游：Warp-level GEMM |
| TCU_LD | 2 | 2 | 0x8 | 上游：Tile buffer 加载 |
| **PF_TMM** | **2** | **3** | **0x6** | **出向三角遮罩 MMA** |
| **PF_TMM_INC** | **2** | **4** | **0x7** | **入向三角遮罩 MMA** |
| **PF_FLASH_ATTN** | **2** | **5** | **0x9** | **Flash Attention（3 子操作）** |

---

## 2 PF_TMM — 三角遮罩矩阵乘

### 2.1 语义

对 WGMMA 结果施加三角形掩码：

```
C[i][j] = A[i][:] × B[:][j]   if mask(i, j) = 1
         = 0                    if mask(i, j) = 0
```

**Outgoing (PF_TMM)**：`mask(i,j) = (i < j)`，保留上三角（不含对角线）

**Incoming (PF_TMM_INC)**：`mask(k,i,j) = (k < min(i, j))`，入向三角掩码（k 维度截断，含对角线 i==j）

### 2.2 掩码实现

掩码在输入侧清零（将 A 行置零，FEDP 乘加结果为 0），基于全局坐标 `(global_i, global_j, global_k)` 判定：

```systemverilog
// Outgoing: i < j（不含对角线）
wire pf_tri_mask_out = (pf_global_i < pf_global_j);

// Incoming: k < min(i, j)（k 维度截断，含对角线 i==j）
wire pf_tri_mask_inc = (pf_global_k < pf_global_i) && (pf_global_k < pf_global_j);
```

### 2.3 编程接口

```cpp
// RS path (NRC=8)
rvdon::pf::pf_tmm_sync<8>(fragC, fragA, fragB, smem_base);
rvdon::pf::pf_tmm_inc_sync<8>(fragC, fragA, fragB, smem_base);

// SS path (smem A)
rvdon::pf::pf_tmm_sync<8, true>(fragC, fragA, fragB, smem_base);
```

### 2.4 寄存器布局

与 WGMMA 完全一致：

| 寄存器 | 内容 |
|--------|------|
| f0-f23 | C/D 累加器（输入 A×B 结果 + 掩码门控后的输出） |
| f24-f27 | A 片段（同 WGMMA RS 模式） |
| B 片段 | 来自 tbuf（SS 模式）或寄存器（RS 模式） |

---

## 3 PF_FLASH_ATTN — Flash Attention

### 3.1 子操作

PF_FLASH_ATTN 通过 `cd_nregs[1:0]`（重载为 `fa_sub_op`）区分 3 个子操作：

| fa_sub_op | 名称 | 功能 |
|-----------|------|------|
| 2'b00 | FA_MMA | 因果遮罩 MMA：S = QK^T，应用因果掩码 `mask(i,j) = (i >= j)` |
| 2'b01 | FA_SOFTMAX | 在线 Softmax：P = softmax(S)，更新 m、l、P |
| 2'b10 | FA_UPDATE | 标准 WGMMA 直通：O += P × V |

### 3.2 FA_SOFTMAX 流水线

VX_tcu_fa.sv 实现 3 级流水线：

```
S0: 输入解包 + max 比较
    s_val → 比较 m_old, s_val → m_new
    s_val - m_new → exp_input

S1: LUT exp 近似
    16 项查找表 + 线性插值
    fp32_sub + fp32_floor_int 计算段索引
    exp_approx(s - m_new) → exp_val

S2: 乘加 + 输出
    P = exp_val * l_old
    l_new = l_old * exp_val + P
    输出 P_val
```

**延迟**：3 个 TCU 周期，通过 `fa_p_delay_pipe`（DEPTH=2）与 FEDP 数据通路对齐。

### 3.3 FA_MMA 因果掩码

```systemverilog
// Causal mask: j <= i（列号 <= 行号，含对角线）
wire fa_causal_mask = (fa_global_j <= fa_global_i);
```

因果掩码与 PF_TMM 三角掩码共享全局坐标信号，通过 `a_row_mask_enable` MUX 选择输入侧 A 行清零。

### 3.4 编程接口

```cpp
// FA_MMA: S = QK^T with causal mask
rvdon::pf::fa_mma_sync<8>(fragC, fragA, fragB, smem_base);

// FA_SOFTMAX: P = softmax(S)
rvdon::pf::fa_softmax_sync<8>(fragC, fragS, smem_base);

// FA_UPDATE: O += P × V (standard WGMMA passthrough)
// Use regular WGMMA instruction with cd_nregs=2
```

### 3.5 FA_SOFTMAX 寄存器布局

| 寄存器 | 内容 | 说明 |
|--------|------|------|
| f0-f7 | C/D 累加器 = m_old (输入) / P (输出) | n-major 布局：f0=(m=0,n=0), f1=(m=1,n=0), ... |
| f24-f27 | A 片段 = S 值 | f24=S[0], f25=S[1]（per-thread 按 TCU 行分配） |

**Per-thread 数据分布**：线程 t 对应 TCU 位置 (i=t/TCU_TC_N, j=t%TCU_TC_N)。RTL 从 `rs1_data[i * TCU_TC_K]` 读取 S 值，因此线程 0 和线程 TCU_TC_N 需持有不同的 S 值。

### 3.6 Uop 展开规则

FA_SOFTMAX 无 K 维度迭代，使用 `WG_MN_NR8`（8 个 uop，仅 m/n 步进），不使用 `WG_UOPS_NR8`（16 个 uop，含 k 步进）。

---

## 4 全局坐标系统

### 4.1 坐标信号

PF 扩展掩码依赖 warp 级全局坐标：

| 信号 | 位宽 | 来源 | 说明 |
|------|------|------|------|
| `pf_global_i` | 可配 | AGU/block_idx | 当前列块的行坐标 |
| `pf_global_j` | 可配 | AGU/block_idx | 当前列块的列坐标 |
| `pf_global_k` | 可配 | AGU/block_idx | 当前列块的 K 坐标 |

### 4.2 当前实现

Phase 1-2 使用 warp-local 坐标（基于 uop 的 step_m/step_n 推导），仅支持单 warp Pairformer tile。Phase 2.2 计划引入 block_idx 流水线扩展，支持多 warp 全局坐标。

---

## 5 配置系统

PF 扩展通过条件编译宏隔离：

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `VX_CFG_TCU_PF_TMM_ENABLE` | true | 启用 PF_TMM / PF_TMM_INC |
| `VX_CFG_TCU_PF_FA_ENABLE` | true | 启用 PF_FLASH_ATTN |
| `VX_CFG_TCU_PF_SLOAD_ENABLE` | false | 预留：Strided Load |

禁用所有 PF 宏后，RTL 回退到原版 Vortex，无任何功能或面积影响。

---

## 6 TCU 参数（NT=8 配置）

RVDon 默认配置为 NT=8（8 线程/warp），TCU 微分块参数：

| 参数 | 值 | 说明 |
|------|-----|------|
| TCU_TC_M | 2 | 微分块行数 |
| TCU_TC_N | 4 | 微分块列数 |
| TCU_TC_K | 4 | 微分块 K 维 |
| TCU_WG_TILE_M | 4 | Warp 级 tile 行 (2×TC_M) |
| TCU_WG_TILE_K | 8 | Warp 级 tile K (2×TC_K) |
| TCU_WG_M_STEPS | 2 | M 方向步进数 |
| TCU_WG_K_STEPS | 2 | K 方向步进数 |
| WG_MN_NR8 | 8 | NRC=8 时 m×n uop 数 |
| WG_UOPS_NR8 | 16 | NRC=8 时总 uop 数（含 k 步进） |

---

## 7 驱动架构（规划）

```
┌──────────────────────────────────┐
│         User Application         │
│  (Protenix / AlphaFold3 kernel)  │
├──────────────────────────────────┤
│       librvdon.so (SDK)          │
│  vx_pf.h intrinsics → 指令发射   │
├──────────────────────────────────┤
│       rvdon.ko (内核模块)         │
│  PCIe MMIO → 寄存器空间映射      │
├──────────────────────────────────┤
│       RVDon Hardware             │
│  Vortex GPU + PF Extension       │
└──────────────────────────────────┘
```

类 CUDA 编程模型：用户态 SDK 直接通过指令填充发射 PF 扩展指令，内核模块负责 PCIe 地址映射和中断处理。

---

## 8 修订历史

| 版本 | 日期 | 说明 |
|------|------|------|
| v0.1 | 2026-07-02 | 初始版本：PF_TMM + PF_FLASH_ATTN 规范 |
