# RVDon PF Extension ISA Specification v1.0

**Document ID:** RVDon-ISA-PF-001  
**Version:** 1.0  
**Date:** 2026-07-06  
**Status:** Released  
**Author:** DiVo Gen²AI  

---

## 1 Overview

The RVDon PF (Pairformer) Extension adds three custom instructions to the Vortex RISC-V GPGPU Tensor Compute Unit (TCU), targeting two classes of computation patterns that are pervasive across scientific computing and AI:

| Instruction | funct3 | Description |
|-------------|--------|-------------|
| `PF_TMM` | 3 | Triangle Matrix Multiplication (Outgoing) |
| `PF_TMM_INC` | 4 | Triangle Matrix Multiplication (Incoming) |
| `PF_FLASH_ATTN` | 5 | Flash Attention (FA_MMA / FA_SOFTMAX / FA_UPDATE) |

All PF instructions share the same R-type encoding as Vortex's native WGMMA (opcode `CUSTOM0`, funct7=2), differing only in funct3. They reuse the WGMMA register window, memory access path, and uop expansion pipeline, adding PF-specific datapath elements (triangle mask gating, online softmax pipeline) as TCU sub-operation codes.

### 1.1 Motivation

Two classes of computation patterns map poorly to general-purpose GPU matrix units:

1. **Symmetric/Triangle Matrix Operations** — computations where only the upper or lower triangle of the result matrix is meaningful. This includes:
   - **Pairformer Triangle Multiplication** (`Z[i][j] += Σ_k A[i][k]·B[j][k]` for `i < j` only)
   - **Graph Neural Networks** (adjacency/degree matrices are symmetric; half the multiply is redundant)
   - **Covariance/Correlation matrices** (symmetric by definition)
   - **Molecular interaction matrices** (pairwise distances are symmetric)
   
   On standard WGMMA, half the multiply results are masked to zero in software, wasting ~50% of compute throughput. PF_TMM gates the accumulation at the TCU lane level, eliminating wasted operations.

2. **Causal Attention** — attention with lower-triangular (causal) masking plus online softmax. This includes:
   - **Pairformer Triangle Attention** (causal mask + triangle symmetry)
   - **Autoregressive language models** (GPT, LLaMA, DeepSeek — every decoder layer)
   - **Time-series forecasting / Reinforcement learning** (causal sequence modeling)
   - **Video understanding** (temporal causal attention)
   
   Standard Flash Attention requires separate MMA → Softmax → Update passes with global synchronization. PF_FLASH_ATTN integrates these three sub-operations as TCU micro-ops, enabling single-pass execution within the warp's TCU occupancy window.

**Origin:** RVDon was initially designed for AlphaFold3/Protenix Pairformer, but the underlying patterns — symmetric masked matrix multiply and causal online softmax — are far more broadly applicable.

### 1.2 Configuration Guards

All PF functionality is conditionally compiled:

| Define | Default | Controls |
|--------|---------|----------|
| `VX_CFG_TCU_PF_TMM_ENABLE` | 1 | PF_TMM + PF_TMM_INC |
| `VX_CFG_TCU_PF_FA_ENABLE` | 1 | PF_FLASH_ATTN (FA_MMA, FA_SOFTMAX, FA_UPDATE) |
| `VX_CFG_TCU_PF_GLOBAL_COORD_ENABLE` | 1 | 16-bit grid_cta_id propagation for PF coordinate masking |

When disabled, the TCU reverts to stock Vortex WGMMA behavior with zero area overhead.

---

## 2 Instruction Encoding

### 2.1 Base Encoding (R-type, CUSTOM0)

```
  31       25 24   20 19   15 14  12 11    7 6      0
 ┌───────────┬───────┬───────┬──────┬───────┬────────┐
 │  funct7=2 │  rs2  │  rs1  │funct3│   rd  │ opcode │
 └───────────┴───────┴───────┴──────┴───────┴────────┘
                │       │       │      │        │
                │       │       │      │        └─ 0101011 (CUSTOM0)
                │       │       │      └─ output format (Ot)
                │       │       └─ 3=PF_TMM, 4=PF_TMM_INC, 5=PF_FLASH_ATTN
                │       └─ input format (It)
                └─ flags (see §2.2)
```

| Field | Bits | Description |
|-------|------|-------------|
| funct7 | [31:25] | = 2 (shared with WGMMA) |
| rs2 | [24:20] | Flags encoding (see §2.2) |
| rs1 | [19:15] | Input format (It) — same as WGMMA |
| funct3 | [14:12] | 3=PF_TMM, 4=PF_TMM_INC, 5=PF_FLASH_ATTN |
| rd | [11:7] | Output format (Ot) — same as WGMMA |
| opcode | [6:0] | = 0b0101011 (CUSTOM0) |

### 2.2 rs2 Flags Encoding

#### 2.2.1 PF_TMM / PF_TMM_INC

```
  rs2[4:0]
  ┌───┬───┬───┬───┬───┐
  │ 4 │ 3 │ 2 │ 1 │ 0 │
  └───┴───┴───┴───┴───┘
        │   └───┘   │
        │     │     └─ is_sparse (unused, =0)
        │     └─ cd_nregs_code
        └─ a_from_smem
```

| Bit | Name | Values |
|-----|------|--------|
| 0 | is_sparse | 0 (unused for PF) |
| [2:1] | cd_nregs_code | 0=NRC8, 1=NRC16, 2=NRC32 |
| 3 | a_from_smem | 0=A from registers, 1=A from shared memory |
| 4 | reserved | 0 |

#### 2.2.2 PF_FLASH_ATTN

```
  rs2[4:0]
  ┌───┬───┬───┬───┬───┐
  │ 4 │ 3 │ 2 │ 1 │ 0 │
  └───┴───┴───┴───┴───┘
        │   └───┘   │
        │     │     └─ is_sparse (unused, =0)
        │     └─ fa_sub_op
        └─ a_from_smem
```

| Bit | Name | Values |
|-----|------|--------|
| 0 | is_sparse | 0 |
| [2:1] | fa_sub_op | 0=FA_MMA, 1=FA_SOFTMAX, 2=FA_UPDATE |
| 3 | a_from_smem | 0=A from registers, 1=A from shared memory |
| 4 | reserved | 0 |

**Note:** `fa_sub_op` overloads the `cd_nregs_code` field. FA_MMA (sub_op=0) maps to NRC=8 which is correct for the uop expander. FA_SOFTMAX (sub_op=1) and FA_UPDATE (sub_op=2) are handled by PF-specific uop logic that ignores the NRC interpretation.

---

## 3 PF_TMM — Triangle Matrix Multiplication (Outgoing)

### 3.1 Semantics

```
Z[i][j] += Σ_k A[i][k] · B[j][k]    for i < j   (outgoing pair)
Z[i][j] = 0                           for i >= j  (masked)
```

The triangle mask is applied at the TCU lane level: when the PF global coordinate mask indicates the current (row, col) position satisfies `row >= col`, the accumulator write is gated to zero. This eliminates the ~50% wasted computation of a naive WGMMA + software mask approach.

### 3.2 Register Layout (RS path, NRC=8)

| Register | Content | Direction |
|----------|---------|-----------|
| f0–f7 | C/D accumulator | Read + Write |
| f24–f27 | A fragment (4 elements) | Read |
| a1 | B shared memory descriptor | Read |

### 3.3 Coordinate Masking

PF_TMM uses the `grid_cta_id` (16-bit linearized CTA rank from the Kernel Management Unit) combined with the warp's `warp_rank` within the CTA to compute the TCU tile's (row, col) position:

```
pf_row = grid_cta_id * ISSUE_WIDTH + warp_rank_in_cta
pf_col = (uop_index) * N
```

When `pf_row >= pf_col`, the TCU accumulator lanes are masked, producing zero for non-triangle elements.

### 3.4 C Intrinsic

```c
template <typename Ctx>
void pf_tmm_sync(fragment_acc &frag_d,
                  const fragment_a &op_a,
                  const smem_matrix_desc &op_b,
                  const fragment_acc &frag_c);
```

---

## 4 PF_TMM_INC — Triangle Matrix Multiplication (Incoming)

### 4.1 Semantics

```
Z[i][j] += Σ_k A[k][i] · B[k][j]    for i > j   (incoming pair)
Z[i][j] = 0                           for i <= j  (masked)
```

Identical to PF_TMM except:
- The mask condition is `row <= col` (incoming triangle)
- The A matrix is transposed (indexed as A[k][i] instead of A[i][k])

### 4.2 Register Layout

Same as PF_TMM (§3.2).

### 4.3 C Intrinsic

```c
template <typename Ctx>
void pf_tmm_inc_sync(fragment_acc &frag_d,
                      const fragment_a &op_a,
                      const smem_matrix_desc &op_b,
                      const fragment_acc &frag_c);
```

---

## 5 PF_FLASH_ATTN — Flash Attention

PF_FLASH_ATTN is a composite operation with three sub-ops that together implement the online softmax attention pattern. The three sub-ops must be called in sequence: FA_MMA → FA_SOFTMAX → FA_UPDATE.

### 5.1 FA_MMA (fa_sub_op=0)

Computes the unnormalized attention scores:

```
S = QK^T / √d_k       (matrix multiply, RS path)
```

This is functionally identical to WGMMA but marks the result as attention scores for the subsequent FA_SOFTMAX step.

**Register layout (NRC=8):**

| Register | Content | Direction |
|----------|---------|-----------|
| f0–f7 | S accumulator (attention scores) | Read + Write |
| f24–f27 | Q fragment | Read |
| a1 | K^T smem descriptor | Read |

### 5.2 FA_SOFTMAX (fa_sub_op=1)

Computes the online softmax normalization incrementally:

```
m_new = max(m_old, row_max(S))          // per-row maximum update
P     = exp(S - m_new)                   // element-wise exp
l_new = l_old * exp(m_old - m_new) + ΣP // normalization constant update
O     = O * exp(m_old - m_new) + P · V  // output update (correction + new contribution)
```

The online softmax is implemented as a 3-stage pipeline in `VX_tcu_fa.sv`:
1. **Stage 1:** FP32 subtraction `S - m_new` (custom fp32_sub with LZD-based exponent subtraction)
2. **Stage 2:** Exponential via 16-entry LUT + linear interpolation
3. **Stage 3:** FP32 multiply-accumulate for `l_new` and `O` update

**Causal masking** is applied within FA_SOFTMAX: for attention position (row, col) where `col > row`, the exp output is forced to zero, implementing the causal (lower-triangular) mask.

**Register layout:**

| Register | Content | Direction |
|----------|---------|-----------|
| f0–f7 | O accumulator (output) | Read + Write |
| f24 | m_old (per-row max, scalar broadcast) | Read |
| f25 | l_old (per-row sum, scalar broadcast) | Read |
| f26 | m_new (per-row max, scalar broadcast) | Read |
| f27 | V current row value | Read |

### 5.3 FA_UPDATE (fa_sub_op=2)

Final normalization of the output:

```
O_final = O / l_new
```

Applied once after all K-steps of FA_MMA → FA_SOFTMAX are complete.

**Register layout:**

| Register | Content | Direction |
|----------|---------|-----------|
| f0–f7 | O accumulator | Read + Write |
| f24 | l_new (final normalization constant) | Read |

### 5.4 C Intrinsics

```c
// FA_MMA: compute attention scores
template <typename Ctx>
void fa_mma_sync(fragment_acc &frag_s,
                  const fragment_a &frag_q,
                  const smem_matrix_desc &frag_kt,
                  const fragment_acc &frag_c);

// FA_SOFTMAX: online softmax step
template <typename Ctx>
void fa_softmax_sync(fragment_acc &frag_o,
                      const fragment_a &frag_s,
                      const fragment_acc &frag_c);

// FA_UPDATE: final normalization
template <typename Ctx>
void fa_update_sync(fragment_acc &frag_o,
                     float l_new);
```

---

## 6 Global Coordinate System

### 6.1 grid_cta_id

RVDon adds a 16-bit `grid_cta_id` field to the Vortex pipeline that provides a linearized CTA rank (0, 1, ..., N-1) from the Kernel Management Unit (KMU), distinct from Vortex's original `cta_id` which is a round-robin slot index.

`grid_cta_id` propagates through all pipeline stages:
- Fetch → Decode → IBUFFER → Scoreboard → Operands → Dispatch → Scheduler → Execute

It is **not** carried into commit/writeback (those stages don't need CTA coordinates).

### 6.2 PF Coordinate Computation

Within the TCU, the PF coordinate is computed as:

```
pf_row_base = grid_cta_id * ISSUE_WIDTH * 2 * TCU_TC_M + pf_warp_rank * 2 * TCU_TC_M
pf_col_base = (uop_step) * TCU_TC_N
```

Where:
- `grid_cta_id` is the 16-bit linearized CTA rank
- `ISSUE_WIDTH` is the pipeline issue width (typically 4)
- `pf_warp_rank` is the warp's position within the CTA
- `TCU_TC_M`, `TCU_TC_N` are the TCU tile dimensions

---

## 7 Programming Model

### 7.1 Triangle Multiplication Kernel Pattern

```c
#include "vx_pf.h"

using namespace rvdon::pf;

// Outgoing triangle multiplication
kernel void pf_tmm_outgoing(/* ... */) {
    // Load A, B fragments into registers
    fragment_a frag_a = load_A(...);
    smem_matrix_desc desc_b = load_B_desc(...);
    fragment_acc frag_c = zeros();

    // One PF_TMM call replaces WGMMA + software mask
    pf_tmm_sync<PFCtx<8>>(frag_c, frag_a, desc_b, frag_c);

    // frag_c now contains only the upper-triangle results
    store(frag_c, ...);
}

// Incoming triangle multiplication
kernel void pf_tmm_incoming(/* ... */) {
    fragment_a frag_a = load_A(...);
    smem_matrix_desc desc_b = load_B_desc(...);
    fragment_acc frag_c = zeros();

    pf_tmm_inc_sync<PFCtx<8>>(frag_c, frag_a, desc_b, frag_c);
    store(frag_c, ...);
}
```

### 7.2 Flash Attention Kernel Pattern

```c
#include "vx_pf.h"

using namespace rvdon::pf;

kernel void pf_flash_attn(/* ... */) {
    fragment_acc frag_o = zeros();
    float m_old = -INFINITY;
    float l_old = 0.0f;

    for (int k = 0; k < K_steps; k++) {
        // Step 1: Compute QK^T attention scores
        fragment_acc frag_s;
        fa_mma_sync<PFCtx<8>>(frag_s, frag_q, desc_kt[k], frag_c_zero);

        // Step 2: Online softmax (updates m, l, O incrementally)
        float m_new = max(m_old, row_max(frag_s));
        fa_softmax_sync<PFCtx<8>>(frag_o, frag_s, frag_c_zero,
                                    m_old, l_old, m_new, frag_v[k]);

        m_old = m_new;
        l_old = l_new;  // l_new computed by FA_SOFTMAX
    }

    // Step 3: Final normalization
    fa_update_sync<PFCtx<8>>(frag_o, l_old);

    store(frag_o, ...);
}
```

---

## 8 Microarchitecture Notes

### 8.1 PF_TMM Implementation

PF_TMM is implemented as a TCU sub-operation code (not a separately encoded instruction). It reuses the WGMMA datapath with:

- **Triangle mask gate:** Added to the WGMMA accumulation path. When `pf_row >= pf_col` (outgoing) or `pf_row <= pf_col` (incoming), the accumulator write is gated to zero.
- **Zero area overhead:** The mask gate is a single AND gate per accumulator lane, negligible compared to the multiplier array.

### 8.2 PF_FLASH_ATTN Implementation

FA_FLASH_ATTN adds a dedicated functional unit `VX_tcu_fa.sv` attached to the TCU pipeline:

- **3-stage pipeline:** fp32_sub → exp_LUT → mac
- **16-entry exp LUT:** Covers the range [0, 8) with linear interpolation; sufficient for fp32 attention values after max-subtraction.
- **Per-row m_new:** The row-wise maximum reduction is performed externally (in software or via a reduction network) and passed as a broadcast value via the register window.
- **Causal mask:** Integrated into the exp stage — when `col > row`, the exp output is forced to zero before accumulation.

### 8.3 Area and Timing

| Module | Area (Nangate 45nm) | Fmax (45nm) | Fmax (28nm proj.) |
|--------|---------------------|-------------|---------------------|
| VX_tcu_fa | 9,948 µm² | ~135 MHz | ~200–270 MHz |
| PF_TMM mask logic | ~0 µm² (1 AND/lane) | N/A | N/A |
| PF extension total | ~2.9% of chip area | — | — |

### 8.4 Parameterization and Configuration Dependencies

The PF extension is designed to be parameterized through Vortex's `VX_CFG_*` configuration system. Key dependencies:

| Parameter | Source | Derivation |
|-----------|--------|------------|
| TCU_TC_M, TCU_TC_N, TCU_TC_K | `VX_CFG_NUM_THREADS` | NT → block geometry (see VX_tcu_pkg.sv) |
| ISSUE_WIDTH | `VX_CFG_ISSUE_WIDTH` | Must match between RTL (-D flag) and software (kernel compilation) |
| grid_cta_id width | Fixed 16-bit | Sufficient for up to 65536 CTAs |
| FA max reduction | TCU_TC_N | Currently only supports TC_N=2 or TC_N=4; TC_N=8 (NT=64) requires parameterized reduction tree |

**Hardcoding audit (v1.0):** 84 instances scanned. All PF RTL derives tile dimensions from `VX_tcu_pkg` localparams. Test code uses `static_assert(VX_CFG_NUM_THREADS == 4)` to prevent silent misconfiguration. PF intrinsics in `vx_pf.h` use `static_assert` for unsupported NRC values.

---

## 9 Known Limitations (v1.0)

| ID | Limitation | Impact | Planned Fix |
|----|-----------|--------|-------------|
| P3-1 | Single-CTA only — grid_cta_id not validated for multi-CTA dispatch | Multi-CTA PF kernels may compute incorrect coordinates | CTA continuity enforcement |
| P3-2 | WID continuity — warp IDs must be contiguous within a CTA | Gaps in wid assignment cause coordinate errors | Wid remapping |
| P3-3 | Pipeline backpressure — FA_SOFTMAX stalls are not gracefully handled under heavy load | Potential deadlock under contention | Credit-based flow control |
| P3-4 | fa_sub_op overloads cd_nregs_code — FA_SOFTMAX/FA_UPDATE set NRC=16/32 in uop expander | Uop expander may generate incorrect uop counts for non-MMA sub-ops | Dedicated PF uop encoding |
| P3-5 | exp LUT precision — 16-entry linear interpolation has ~0.5% relative error | Sufficient for attention, may need improvement for other use cases | Quadratic interpolation or larger LUT |

---

## 10 Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-07-06 | Initial release. PF_TMM, PF_TMM_INC, PF_FLASH_ATTN (FA_MMA/FA_SOFTMAX/FA_UPDATE). grid_cta_id coordinate system. |
| 1.0+1 | 2026-07-06 | Added §8.4 Parameterization and Configuration Dependencies. Hardcoding audit: test code now uses derived TCU dimensions, PF intrinsics have static_assert guards. |

---

© 2024-2026 DiVo Gen²AI — 王掬琅（Peter Wang）· 王潇奕（Shawn Wang）
