# RVDon PF Extension — Verification Results

**Date**: 2026-07-06  
**Verifier**: DiVo Gen²AI (internal verification)  
**RTL revision**: e2815d8a3 (vortex, rvdon branch)  
**Verification tool**: Verilator rtlsim + Python numerical simulation

---

## 1. RTL Simulation (Verilator rtlsim)

| Test | Result | Details |
|------|:---:|------|
| PF_TMM (M=16) | ✅ PASS | 0 errors / 128 elements |
| PF_TMM_INC (M=16) | ✅ PASS | 0 errors / 128 elements |
| FA_MMA (M=16) | ✅ PASS | 0 errors / 128 elements |
| FA_SOFTMAX (M=16) | ✅ PASS | 0 errors / 128 elements |
| FA_UPDATE (M=16) | ✅ PASS | 0 errors / 128 elements |
| FA_E2E (M=16) | ✅ PASS | 0 errors / 128 elements |
| vecadd (n64, n256) | ✅ PASS | Functional sanity check |

**Total: 7/7 sub-tests PASSED, 0 errors / 128 elements**

---

## 2. Numerical Accuracy (Python Simulation)

### 2.1 Component-Level exp(-x) Accuracy

| Metric | Value |
|--------|:---:|
| Max relative error | 3.17% |
| Mean relative error | 1.44% |
| Effective bits | ~5 |
| Approx multiply additional error | 0.07% |

### 2.2 Flash Attention E2E

| Metric | Value |
|--------|:---:|
| Cosine similarity (vs FP64) | 0.99989 |
| Max absolute error | 0.010 |
| Mean absolute error | 0.001 |

### 2.3 Protenix Pairformer Scenario

| Metric | Value |
|--------|:---:|
| Cosine similarity (vs FP64) | 0.99989 |
| Max absolute error | 0.014 |
| Mean absolute error | 0.001 |

---

## 3. Synthesis Results

| Metric | Value |
|--------|:---:|
| PF extension area | 8,672 Nangate units (0.6% of chip) |
| VX_tcu_fa area | 8,322 Nangate units (2.8% of chip) |
| VX_tcu_fa Fmax (45nm) | 141.6 MHz (critical path: 7.06 ns) |
| 28nm projected Fmax (PnR) | ~240 MHz |
| 12nm projected Fmax (PnR) | ~420 MHz |

---

## 4. Independent Reproduction

To independently reproduce these results:

```bash
cd scripts/
python3 verify_pf_accuracy.py
```

All five verification tests should pass with metrics matching the values above.

---

## 5. Bug History (All P0-P2 Fixed)

| Bug | Severity | Description | Status |
|-----|:---:|------|:---:|
| BUG-1 | P0 | fp32_sub LZD off-by-one | ✅ Fixed |
| BUG-2 | P0 | FA_SOFTMAX per-element S value | ✅ Fixed |
| BUG-3 | P0 | fp32_sub same-sign overflow | ✅ Fixed |
| BUG-5 | P1 | Coarse/Fine LUT precision | ✅ Fixed (32-entry upgrade) |
| BUG-7 | P2 | fa_softmax_lnew_sync earlyclobber | ✅ Fixed |
| BUG-8 | P2 | fp32_mul underflow flush-to-zero | ✅ Fixed |
| BUG-10 | P2 | grid_cta_id pipeline propagation | ✅ Fixed |

---

*This document serves as the reference baseline for independent third-party verification.*
