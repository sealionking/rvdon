# RVDon PF Extension Verification Kit

This directory contains everything needed to **independently verify** the correctness and numerical accuracy of the RVDon PF (Pairformer) Extension for Vortex RISC-V GPGPU.

**No RTL source code is required.** All verification is performed against the published ISA specification and reference numerical results.

---

## What's Being Verified

The RVDon PF Extension adds three custom TCU instructions to Vortex:

| Instruction | Description | Verification Focus |
|-------------|-------------|-------------------|
| `PF_TMM` | Triangle Matrix Multiplication (Outgoing) | Triangle mask correctness, accumulator gating |
| `PF_TMM_INC` | Triangle Matrix Multiplication (Incoming) | Reverse mask, transposed A indexing |
| `PF_FLASH_ATTN` | Flash Attention (FA_MMA + FA_SOFTMAX + FA_UPDATE) | Online softmax numerical accuracy, LUT exp precision |

---

## Quick Start

### Prerequisites

- Python 3.8+ with NumPy
- No special hardware or commercial EDA tools required

### Step 1: Verify LUT exp Precision

```bash
cd scripts/
python3 verify_pf_accuracy.py
```

This reproduces the VX_tcu_fa.sv LUT-based exp approximation in Python and reports:

- Component-level max/mean relative error
- End-to-end Flash Attention cosine similarity vs FP64 reference
- Protenix Pairformer scenario accuracy
- Error source decomposition (LUT quantization vs approximate multiply)

### Step 2: Check Test Vectors

```bash
# Compare your own implementation against reference vectors
python3 -c "
import csv
with open('../test-vectors/flash_attention_vectors.csv') as f:
    reader = csv.DictReader(f)
    for row in reader:
        # Your verification logic here
        pass
"
```

### Step 3: Review ISA Compliance

Read the ISA specification: [`../docs/isa-spec-v1.0.md`](../docs/isa-spec-v1.0.md)

Verify that your implementation matches the defined behavior for:
- Instruction encoding (R-type, CUSTOM0, funct7=2)
- PF_TMM coordinate masking (row >= col → zero)
- PF_TMM_INC reverse masking (row <= col → zero)
- FA_SOFTMAX 3-stage pipeline semantics
- Configuration guards (`VX_CFG_TCU_PF_TMM_ENABLE`, `VX_CFG_TCU_PF_FA_ENABLE`)

---

## Directory Structure

```
verification/
├── README.md                          ← This file
├── test-vectors/
│   ├── flash_attention_vectors.csv    ← Q/K/V inputs + expected attention output
│   ├── exp_lut_accuracy.csv          ← exp(-x) LUT approximation vs math.exp
│   └── protenix_pairformer.csv        ← Protenix scenario test vectors
├── scripts/
│   └── verify_pf_accuracy.py          ← Self-contained numerical accuracy verifier
└── results/
    └── rvdon-verification-results.md   ← DiVo's internal verification results (for comparison)
```

---

## Verification Tiers

| Tier | What You Verify | Tools Needed | Time |
|------|----------------|:---:|:---:|
| **Tier 1: Numerical** | LUT exp precision, E2E attention accuracy | Python + NumPy | 2 min |
| **Tier 2: Functional** | ISA compliance, test vector matching | Any RTL simulator | 1-2 hours |
| **Tier 3: Silicon** | Area, timing, power at target process | Synopsys DC + PnR | Days |

This kit covers **Tier 1** completely and provides reference data for **Tier 2**.

---

## Expected Results (DiVo Internal Verification)

| Metric | Value | Source |
|--------|:---:|:---:|
| Component-level max relative error (exp) | 3.17% | 32-entry fine LUT |
| Component-level mean relative error (exp) | 1.44% | 32-entry fine LUT |
| Approx multiply additional error | 0.07% | 12-bit truncated mantissa |
| Protenix Pairformer cosine similarity | 0.99989 | Python simulation |
| Flash Attention E2E cosine similarity | 0.99989 | Python simulation |
| Effective bits | ~5 | -log2(max_rel_err) |
| PF extension area overhead | 0.6% of chip | Yosys synthesis |
| rtlsim test result | 0/128 errors | Verilator simulation |

If your independent verification produces significantly different results, please contact us at wangjueju+divobot@gmail.com.

---

## Citation

If you use this verification kit in academic work, please cite:

```bibtex
@techreport{rvdon-tn-012,
  title={RVDon 28nm/GF 12LP+ Synthesis + PnR Evaluation Report},
  author={DiVo Gen\textsuperscript{2}AI},
  number={RVDon-TN-012},
  year={2026}
}
```

---

## License

This verification kit is released under the **Apache License 2.0**, consistent with the RVDon public documentation.

The RVDon PF Extension RTL implementation is **not** open-source and is available under a commercial EULA for authorized licensees only.
