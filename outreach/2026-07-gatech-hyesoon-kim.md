Subject: Third-Party Verification of Vortex TCU Extension for Protein Structure Prediction

Dear Prof. Kim,

I am writing from DiVo Gen²AI regarding a domain-specific TCU extension we have developed on top of Vortex 3.0, targeting AlphaFold3/Protenix Pairformer workloads. We would like to propose an independent verification collaboration with your group.

## What We Built

Our PF (Pairformer) Extension adds three custom instructions to Vortex's WGMMA framework:

| Instruction | Description | Purpose |
|-------------|-------------|---------|
| `PF_TMM` | Triangle Matrix Multiplication (Outgoing) | Pairformer triangle multiplication (Z[i][j] += Σ_k A[i][k]·B[j][k], i < j only) |
| `PF_TMM_INC` | Triangle Matrix Multiplication (Incoming) | Reverse triangle (A[k][i]·B[k][j], i > j only) |
| `PF_FLASH_ATTN` | Flash Attention (FA_MMA + FA_SOFTMAX + FA_UPDATE) | Causal online softmax with LUT-based exp approximation |

The extension is designed to be **architecturally orthogonal** to Vortex baseline:
- Same R-type encoding (CUSTOM0, funct7=2) as WGMMA, differing only in funct3
- Reuses WGMMA register window, memory access path, and uop expansion pipeline
- Adds PF-specific datapath elements (triangle mask gating, online softmax pipeline) as TCU sub-operation codes
- Conditionally compiled via `VX_CFG_TCU_PF_TMM_ENABLE` / `VX_CFG_TCU_PF_FA_ENABLE`
- When disabled, TCU reverts to stock WGMMA with zero area overhead

## Key Results (Our Internal Verification)

| Metric | Value |
|--------|-------|
| PF extension area overhead | **0.6%** of full chip (8,672 / 1,415,080 Nangate units @ 45nm) |
| VX_tcu_fa Fmax | 141.6 MHz @ 45nm Nangate (critical path: l_new accumulator chain, 7.06 ns) |
| rtlsim functional test | **7/7 sub-tests PASSED**, 0 errors / 128 elements |
| exp(-x) max relative error | 3.17% (16×32 coarse×fine LUT decomposition) |
| E2E Flash Attention cosine similarity | **0.99989** vs FP64 reference |
| Protenix Pairformer cosine similarity | **0.99989** vs FP64 reference |
| 28nm projected Fmax (PnR) | ~240 MHz |

## Why This Matters for Vortex

We believe this work validates an important architectural thesis: **Vortex's WGMMA framework can be extended with domain-specific operations at near-zero cost** to cover high-value scientific computing workloads. Specifically:

1. **Protenix/AlphaFold3 Pairformer** runs three compute patterns (triangle outgoing multiply, triangle incoming multiply, causal attention) that map poorly to general WGMMA. PF extension gates the ~50% wasted computation in triangle operations and integrates online softmax as TCU micro-ops.

2. **These patterns are not biology-specific** — symmetric matrix operations appear in GNNs, covariance estimation, molecular dynamics; causal attention is universal in autoregressive LLMs. The PF extension's applicability extends well beyond its origin.

3. **0.6% area overhead for 80%+ hotspot coverage** demonstrates that Vortex's extensible TCU architecture can achieve domain-specific acceleration without sacrificing generality — a key differentiator vs. fixed-function accelerators.

## Proposed Collaboration

We propose a **black-box independent verification**:

1. **We provide**: Verilator simulation binary, ISA specification, test vectors, and a self-contained Python verification script (all publicly available at https://github.com/sealionking/rvdon)
2. **Your team independently verifies**: ISA compliance, numerical accuracy, and architectural orthogonality with Vortex baseline
3. **No RTL source code disclosure required** — verification is performed entirely against the published ISA specification and reference numerical results

The verification kit is already public and can be run in under 2 minutes:

```bash
git clone https://github.com/sealionking/rvdon.git
cd rvdon/verification/scripts/
python3 verify_pf_accuracy.py
```

## Potential Outcomes

- **Joint publication**: "Domain-Specific TCU Extensions for Scientific Computing on Open-Source RISC-V GPUs" — suitable for ISCA/MICRO/DATE, demonstrating Vortex's extensibility with a real-world workload
- **Vortex ecosystem milestone**: PF extension is, to our knowledge, the first major third-party TCU extension built on Vortex, proving the platform's extensibility story
- **Independent verification report**: Your lab's assessment would carry significant weight with potential IP licensees evaluating the design

## About DiVo Gen²AI

DiVo Gen²AI is a computational biology AI company based in Shenzhen, China. We develop domain-specific computing solutions for protein structure prediction and drug discovery. Our approach follows an ARM-like IP licensing model — we design and verify RTL, then license to partners who manufacture chips.

I hold a B.S. in Biological Science from Sun Yat-sen University and have been self-taught in all IT/engineering capabilities. Vortex has been an exceptional platform for our work — its clean WGMMA interface made the PF extension architecturally natural.

## Next Steps

Would you be available for a brief video call to discuss this opportunity? I am happy to work around your schedule and can present our design in more detail.

Thank you for creating Vortex and for considering this collaboration.

Best regards,

Wang Jueju (王觉菊)
Founder, DiVo Gen²AI
wangjueju+divobot@gmail.com

---

**Attachments**: None (all materials are publicly available on GitHub)

**References**:
- ISA Specification: https://github.com/sealionking/rvdon/blob/main/docs/isa-spec-v1.0.md
- Precision White Paper (RVDon-TN-011 v2.0): https://github.com/sealionking/rvdon/blob/main/docs/precision-verification-whitepaper.md
- 28nm Synthesis Evaluation (RVDon-TN-012): https://github.com/sealionking/rvdon/blob/main/docs/28nm-synthesis-pnr-evaluation.md
- Verification Kit: https://github.com/sealionking/rvdon/tree/main/verification
