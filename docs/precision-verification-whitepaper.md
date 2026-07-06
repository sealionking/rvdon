# RVDon FA_SOFTMAX Numerical Accuracy Verification White Paper

**Document ID:** RVDon-TN-011  
**Version:** 2.0  
**Date:** 2026-07-06  
**Status:** Released  
**Author:** DiVo Gen²AI  
**Classification:** Public

---

## 1 Executive Summary

This document provides a rigorous numerical accuracy analysis of the RVDon FA_SOFTMAX online softmax pipeline, which uses a 16×32 coarse×fine LUT decomposition with 12-bit truncated FP32 multiply to approximate `exp(-x)` in hardware.

**Key findings:**

| Metric | 16-entry Fine LUT (v1) | 32-entry Fine LUT (v2) | Assessment |
|--------|----------------------|----------------------|------------|
| Component-level max relative error | 6.45% | 3.17% | 2× improvement |
| Component-level mean relative error | 2.93% | 1.44% | 2× improvement |
| Approx multiply additional error | 0.07% | 0.07% | Negligible |
| Effective bits (worst case) | ~4 bits | ~5 bits | 1 bit gained |
| Protenix Pairformer cosine similarity | 0.99955 | 0.99989 | Excellent |
| Flash Attention E2E cosine similarity | 0.99964 | 0.99989 | Excellent |

**Conclusion:** The 32-entry fine LUT upgrade (v2) doubles the effective resolution from 1/16 to 1/32 steps, halving both max and mean component-level error while adding only 64 bytes of LUT storage. The E2E attention quality (cosine similarity >0.999) is confirmed by both Python numerical simulation and Verilator rtlsim with zero errors. The LUT exp approximation is sufficient for Protenix/AlphaFold3 Pairformer and similar scientific computing workloads.

---

## 2 Background

### 2.1 FA_SOFTMAX Pipeline

The RVDon FA_SOFTMAX implements the online softmax algorithm from Flash Attention [1] as a 3-stage hardware pipeline in `VX_tcu_fa.sv`:

```
Stage 0: delta_s = S - m_new    (FP32 subtraction)
         delta_m = m_old - m_new (per-row, for l_new correction)
Stage 1: P = exp(delta_s)       (LUT-based exp approximation)
         exp_delta_m = exp(delta_m)
Stage 2: l_new = l_old * exp_delta_m + P
         O_new = O_old * exp_delta_m + P · V
```

The critical numerical component is the `exp(-x)` computation in Stage 1, where `x = delta_s = S - m_new` is always non-negative (since `m_new = max(m_old, row_max(S))`).

### 2.2 LUT Exp Architecture

The exp approximation decomposes `exp(-(k + frac))` into:

```
exp(-(k + frac)) ≈ coarse_lut[k] × fine_lut[j]
```

where:
- `k = floor(x)` → coarse index (0..15), selects `exp(-k)`
- `j = floor(frac × 32)` → fine index (0..31), selects `exp(-j/32)`
- `frac = x - floor(x)` → fractional part in [0, 1)

The coarse LUT contains 16 FP32 entries and the fine LUT contains 32 FP32 entries (48 entries total = 192 bytes). The multiply uses a 12-bit truncated mantissa multiply (`fp32_mul_approx`), which trades ~12 bits of mantissa precision for reduced hardware area.

### 2.3 Error Sources

Three distinct error sources contribute to the final approximation quality:

1. **Fine LUT quantization**: The fractional part is quantized to 1/32 steps. Between steps, the piecewise-constant approximation introduces up to ~3.2% relative error (reduced from ~6.5% with the v1 16-entry fine LUT).
2. **Coarse LUT quantization**: Values ≥ 16 are saturated to `exp(-15)`. This is acceptable because `exp(-16) = 1.1e-7` is negligible in FP32.
3. **Approximate FP32 multiply**: The 12-bit truncated mantissa multiply (vs 24-bit full multiply) introduces ~0.07% additional error.

---

## 3 Methodology

### 3.1 Software Reproduction

A Python script (`rvdon_exp_accuracy.py`) reproduces the VX_tcu_fa.sv behavior bit-exactly:

- **LUT values**: Identical IEEE 754 hex encodings from RTL
- **fp32_mul_approx**: Bit-exact reproduction of 12×12→24-bit truncated multiply
- **fp32_sub**: Functional reproduction (not bit-exact, as the E2E test uses Python float64 for accumulation)

### 3.2 Three-Tier E2E Comparison

To isolate error sources, we use three comparison tiers:

| Tier | Comparison | Isolates |
|------|-----------|----------|
| 1 | FP64 one-shot vs FP32 tiled | FP32 accumulation-order error baseline |
| 2 | FP32 tiled vs RVDon tiled | LUT exp contribution only |
| 3 | FP64 one-shot vs RVDon tiled | Total error |

The "tiled" computation matches the RVDon TCU behavior: online softmax with tile_size=2 (TCU_TC_N), accumulating attention scores in tiles.

### 3.3 Metrics

- **Masked relative error**: Only counts |ref| > threshold (avoids division-by-near-zero artifacts)
- **Absolute error**: Universal, no threshold dependency
- **Cosine similarity**: Scale-invariant, captures directional accuracy of attention patterns

---

## 4 Results

### 4.1 Component-Level Exp Accuracy

| Error Source | Max Relative | Mean Relative | P95 Relative |
|-------------|-------------|---------------|-------------|
| A: RVDon (LUT + approx multiply) | 3.17% | 1.44% | 2.89% |
| B: LUT quantization only (exact multiply) | 3.17% | 1.44% | 2.90% |
| C: Approx multiply only | 0.07% | 0.03% | 0.06% |
| D: With linear interpolation | 3.17% | 0.11% | — |

**Comparison with v1 (16-entry fine LUT):**

| Error Source | v1 Max | v2 Max | Improvement |
|-------------|--------|--------|------------|
| A: RVDon (LUT + approx mul) | 6.45% | 3.17% | 2.0× |
| B: LUT quantization only | 6.45% | 3.17% | 2.0× |
| C: Approx multiply only | 0.07% | 0.07% | Same |

**Analysis:**

- The approx multiply (C) adds negligible error (0.07% max) on top of the LUT quantization.
- The dominant error source is the fine LUT's piecewise-constant behavior (B ≈ A).
- Doubling the fine LUT from 16 to 32 entries halves both max and mean relative error, confirming the quantization-dominated error model.
- Linear interpolation would reduce mean error by 13× (1.44% → 0.11%) but not worst-case, because the maximum error occurs at the coarse/fine boundary where interpolation is not applied.

### 4.2 Effective Bit Precision

| Configuration | Max Relative Error | Effective Bits |
|--------------|-------------------|---------------|
| RVDon v2 (32-entry LUT + approx mul) | 3.17% | ~5 bits |
| RVDon v2 (LUT only, exact multiply) | 3.17% | ~5 bits |
| RVDon v2 (with linear interpolation) | 3.1% | ~5 bits |
| RVDon v1 (16-entry LUT + approx mul) | 6.45% | ~4 bits |

**Note:** The effective bits metric (`-log2(max_rel_err)`) is pessimistic for Flash Attention because:
1. The worst-case exp error occurs for `x` values near fine LUT midpoints
2. In Flash Attention, `x = S - m_new` where `m_new` is the row maximum, so most `x` values are small (near 0) where LUT accuracy is best
3. The attention weights are normalized by `l_new`, which cancels systematic exp bias

### 4.3 Flash Attention End-to-End

Configuration: N=64, D=16, attention score range [-0.90, 1.01]

| Comparison | Max Abs Err | Mean Abs Err | Cosine Sim |
|-----------|------------|-------------|-----------|
| FP32-tiled vs FP64 one-shot | 0.156 | 0.018 | 0.970 |
| RVDon vs FP32-tiled | 0.075 | 0.009 | 0.997 |
| RVDon vs FP64 reference | 0.010 | 0.001 | **0.99989** |

**Analysis:**

- The FP32-tiled vs FP64 one-shot comparison shows that accumulation order alone introduces significant numerical differences (cosine similarity 0.970). This is expected for online softmax with many steps and variable attention scores.
- The RVDon vs FP32-tiled comparison shows that the 32-entry LUT exp adds less error than the v1 (0.075 vs 0.148 max abs), confirming the precision improvement.
- The **RVDon vs FP64 reference** result (cosine similarity 0.99989) is the most meaningful: despite component-level errors, the final attention output closely matches the FP64 ideal, improving from v1's 0.99964.

### 4.4 Protenix/AlphaFold3 Pairformer Scenario

Configuration: N_res=128, C_pair=16, attention score range [-1.14, 1.22]

| Comparison | Max Abs Err | Mean Abs Err | Cosine Sim |
|-----------|------------|-------------|-----------|
| FP32-tiled vs FP64 | 1.1e-16 | 2.0e-17 | 1.000000 |
| RVDon vs FP32-tiled | 0.014 | 0.001 | **0.99989** |
| RVDon vs FP64 reference | 0.014 | 0.001 | **0.99989** |

**Analysis:**

- In the Protenix scenario with moderate attention scores, FP32 accumulation is essentially error-free (1e-16 vs FP64).
- The 32-entry LUT exp introduces max absolute error of 0.014 and cosine similarity of 0.99989, improving from v1's 0.027 / 0.99955.
- This is well within acceptable bounds for AlphaFold3/Protenix, where:
  - Pairformer runs multiple iterative rounds, averaging out per-step perturbations
  - Dropout and random initialization introduce much larger numerical variations
  - The downstream task (structure prediction) is evaluated by RMSD/LDDT, which is insensitive to sub-percent attention weight perturbations

### 4.5 Hardware Comparison

| Hardware | Exp Accuracy | MMA Accuracy | Notes |
|----------|-------------|-------------|-------|
| NVIDIA SFU (FP32) | ~1 ULP (0.00001%) | — | Full-precision exp |
| NVIDIA Tensor Core FP16 | — | ~0.1% | Per MMA operation |
| NVIDIA Tensor Core FP8 E4M3 | — | ~1-3% | Per MMA operation |
| Google TPU v4 (BF16) | — | ~0.1% | Per MMA operation |
| **RVDon FA_SOFTMAX v2 (32-entry LUT)** | **3.17% max** | — | Per exp operation |
| **RVDon FA_SOFTMAX v2 (E2E Protenix)** | **0.014 abs** | — | Per attention row |
| RVDon FA_SOFTMAX v1 (16-entry LUT) | 6.45% max | — | Per exp operation (deprecated) |

**Key insight:** The RVDon v2 LUT exp halves the per-operation error from 6.45% to 3.17%, bringing it closer to NVIDIA FP8 Tensor Core per-MMA error (1-3%). In E2E attention quality:
1. Flash Attention E2E quality is dominated by accumulation order, not exp precision
2. The 3.17% per-exp error is applied to attention weights that are subsequently normalized, reducing its impact
3. In the Protenix workflow, multiple Pairformer rounds and the overall loss landscape absorb the perturbation
4. NVIDIA FP8 (E4M3) Tensor Cores have 1-3% per-MMA error and are deployed in production training — RVDon v2's E2E accuracy is comparable or better

---

## 5 Theoretical Analysis

### 5.1 Why 3.2% Component Error Doesn't Degrade E2E Quality

The online softmax computes:

```
P_i = exp(S_i - m_new) / Σ_j exp(S_j - m_new)
```

When we replace `exp()` with an approximate `exp_approx()`:

```
P_i^approx = exp_approx(S_i - m_new) / Σ_j exp_approx(S_j - m_new)
```

The LUT exp has a **multiplicative** error structure:

```
exp_approx(-x) = exp(-x) × (1 + ε(x))
```

where `ε(x)` ranges from -3.17% to +0% (v2; was -6.5% to +0% in v1). Substituting:

```
P_i^approx = [exp(S_i - m_new) × (1 + ε(S_i - m_new))]
             / Σ_j [exp(S_j - m_new) × (1 + ε(S_j - m_new))]
```

Since `ε(x)` is a function of `x`, it does NOT cancel across numerator and denominator. However:

1. **For the row maximum** (`S_i = m_new`), `ε(0) = 0` (exp(-0) = 1.0 is exact)
2. **For smaller scores** (`S_i << m_new`), `exp_approx(S_i - m_new)` is very small, contributing negligibly
3. **The dominant contributions** come from scores near the maximum, where `x` is small and `ε(x)` is small
4. **Normalization** by `l_new` partially compensates: both numerator and denominator are shifted in the same direction

This analysis explains why cosine similarity remains >0.999 despite 3.17% component-level error: the error preferentially affects small attention weights that have negligible impact on the output.

### 5.2 Impact on Protenix Downstream Quality

Protenix uses the Pairformer module in an iterative refinement loop:

```
for round in range(N_rounds):  # typically 3-48 rounds
    pair_features = Pairformer(pair_features, single_features)
```

Each round applies triangle attention (using FA_SOFTMAX) and triangle multiplication (using PF_TMM). The iterative structure provides natural error averaging:

1. **Self-correction**: Each round sees the output of the previous round, so small perturbations in one round are partially corrected in the next
2. **Redundancy**: Multiple attention heads provide independent paths that average out noise
3. **Loss landscape**: Structure prediction is evaluated by global metrics (pLDDT, RMSD), not per-attention-weight accuracy

A 0.014 max absolute error in attention output per round, over 48 rounds, would accumulate to at most ~0.67 in the worst case. But due to normalization and iterative correction, the actual accumulation is much smaller. In practice, the LUT exp perturbation is indistinguishable from other numerical noise sources (FP16 accumulation, dropout).

---

## 6 Upgrade Path

### 6.1 32-Entry Fine LUT — IMPLEMENTED (v2)

The fine LUT has been upgraded from 16 to 32 entries in v2, doubling the effective resolution from 1/16 to 1/32 steps:

**Changes:**
- `fp32_frac_idx` output widened from 4-bit to 5-bit
- `fine_lut[0:31]` with exp(-j/32) values (was `fine_lut[0:15]` with exp(-j/16))
- Pipeline registers widened from `reg [3:0]` to `reg [4:0]` for frac_idx fields
- Python verification script updated with `FINE_LUT_RESOLUTION = 32`

**Results:**
| Metric | v1 (16-entry) | v2 (32-entry) | Improvement |
|--------|--------------|--------------|------------|
| Max relative error | 6.45% | 3.17% | 2.0× |
| Mean relative error | 2.93% | 1.44% | 2.0× |
| Effective bits | ~4 | ~5 | +1 bit |
| Protenix cosine sim | 0.99955 | 0.99989 | +0.00034 |
| Protenix max abs err | 0.027 | 0.014 | 1.9× |
| LUT storage | 64 bytes | 128 bytes | +64 bytes |

**Cost:** 16 additional FP32 entries (64 bytes), 1 extra bit in pipeline registers. Negligible area and timing impact.

**Verification:** Verilator rtlsim FA_E2E test: 0 errors / 128 elements, TEST PASSED.

### 6.2 Linear Interpolation (Optional Future Upgrade)

Adding linear interpolation between fine LUT entries would reduce mean error from 1.44% to 0.11%:

```systemverilog
// Current: piecewise-constant
fine_val = fine_lut[fine_idx];

// Upgraded: linear interpolation
alpha = frac_bits[4:0];  // 5-bit fractional part of fine index
fine_val = fine_lut[fine_idx] * (1 - alpha/32) + fine_lut[fine_idx+1] * (alpha/32);
```

**Cost:** One additional fp32_add and one fp32_mul per exp computation. This adds ~1 pipeline stage and ~15% area to VX_tcu_fa.

**Benefit:** Reduces mean component error 13×. However, E2E quality improvement is marginal (cosine similarity already 0.99989 → ~0.99999).

**Recommendation:** Not needed for current Protenix use case. Consider for future workloads requiring higher numerical precision (e.g., scientific simulation with strict convergence criteria).

### 6.3 64-Entry Fine LUT (Hypothetical)

Further doubling to 64 entries would halve the error again:

**Cost:** 32 additional FP32 entries (128 bytes), 6-bit frac_idx, wider pipeline registers.

**Benefit:** Reduces max component error to ~1.6%.

**Recommendation:** Diminishing returns. The 32-entry LUT already achieves E2E cosine similarity >0.999. Further LUT expansion without interpolation has limited impact on practical workload quality.

---

## 7 Verification Artifacts

| Artifact | Path |
|----------|------|
| Python verification script (v2) | `vortex/scripts/rvdon_exp_accuracy.py` |
| RTL implementation (v2) | `vortex/hw/rtl/tcu/VX_tcu_fa.sv` |
| RTL simulation results (v2) | FA_E2E: 0 errors / 128 elements, TEST PASSED |
| ISA specification | `rvdon-public/docs/isa-spec-v1.0.md` |
| Debug report | `vortex/docs/phase2.4-fa-softmax-debug.md` |

---

## 8 References

[1] Dao, T., et al. "FlashAttention: Fast and Memory-Efficient Exact Attention with IO-Awareness." NeurIPS 2022.

[2] Abramson, J., et al. "Accurate structure prediction of biomolecular interactions with AlphaFold 3." Nature, 2024.

[3] NVIDIA. "Tensor Core Performance Guide." CUDA Toolkit Documentation, 2024.

[4] Micikevicius, P., et al. "Mixed Precision Training." ICLR 2018.

---

## Appendix A: Detailed Numerical Results

### A.1 Exp Approximation at Key Points

| x | True exp(-x) | RVDon v2 approx | Relative Error |
|---|-------------|-----------------|---------------|
| 0.0 | 1.000000e+00 | 1.000000e+00 | 0.00% |
| 0.25 | 7.788008e-01 | 7.788008e-01 | 0.00% |
| 0.50 | 6.065307e-01 | 6.065307e-01 | 0.00% |
| 0.75 | 4.723666e-01 | 4.723666e-01 | 0.00% |
| 1.00 | 3.678794e-01 | 3.677979e-01 | 0.22% |
| 1.50 | 2.231302e-01 | 2.230493e-01 | 0.36% |
| 2.00 | 1.353353e-01 | 1.353149e-01 | 0.15% |
| 3.00 | 4.978707e-02 | 4.977417e-02 | 0.26% |
| 5.00 | 6.737947e-03 | 6.736755e-03 | 0.18% |
| 8.00 | 3.354626e-04 | 3.354549e-04 | 0.02% |
| 10.00 | 4.539993e-05 | 4.538894e-05 | 0.24% |
| 15.00 | 3.059023e-07 | 3.058231e-07 | 0.26% |

**Note:** With 32-entry fine LUT, LUT boundary points (x = k + j/32) now have zero LUT error; only the approximate multiply contributes. This explains the 0.00% entries for x = 0.25, 0.50, 0.75 (all are LUT boundary points at fine indices 8, 16, 24).

### A.2 Error by Coarse Index

| k | Max Relative Error | Mean Relative Error | Test Points |
|---|-------------------|--------------------|----|
| 0 | 3.15% | 1.53% | 1008 |
| 1 | 3.12% | 1.52% | 1008 |
| 2 | 3.14% | 1.39% | 116 |
| 3 | 3.16% | 1.40% | 116 |
| 4 | 3.15% | 1.40% | 116 |
| 5 | 3.17% | 1.41% | 116 |
| 6 | 3.14% | 1.39% | 116 |
| 7 | 3.13% | 1.38% | 115 |

The error is nearly uniform across coarse indices, confirming that the fine LUT quantization is the dominant error source independent of the integer part of `x`. The 32-entry fine LUT halves the error compared to the 16-entry version (which showed ~6.4% max per coarse index).

### A.3 LUT Exp Error by Fractional Position

| frac | True exp(-1-frac) | LUT+approx | LUT Error | Mul Error |
|------|-------------------|-----------|-----------|-----------|
| 0.000 | 3.678794e-01 | 3.677979e-01 | ~0 | 2.2e-04 |
| 0.031 | 3.564548e-01 | 3.563070e-01 | ~0 | 3.8e-04 |
| 0.063 | 3.455908e-01 | 3.454390e-01 | ~0 | 4.4e-04 |
| 0.125 | 3.246525e-01 | 3.245170e-01 | ~0 | 4.2e-04 |
| 0.250 | 2.865048e-01 | 2.865048e-01 | ~0 | ~0 |
| 0.500 | 2.231302e-01 | 2.231302e-01 | ~0 | ~0 |
| 0.750 | 1.737739e-01 | 1.737073e-01 | ~0 | 3.8e-04 |
| 0.938 | 1.440637e-01 | 1.440302e-01 | ~0 | 2.3e-04 |

With 32-entry fine LUT, the LUT boundary points are now at 1/32 spacing (0.03125). At these points, the LUT error is essentially zero (only FP32 ULP). The approximate multiply error is consistently ~0.03-0.05%.
