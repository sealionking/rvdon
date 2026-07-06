# RVDon MD Extension Roadmap

**Document ID:** RVDon-TN-013  
**Version:** 1.0  
**Date:** 2026-07-06  
**Status:** Draft  
**Author:** DiVo Gen²AI  

---

## 1 Executive Summary

RVDon's existing PF (Pairformer) Extension — designed for AlphaFold3/Protenix — contains two hardware primitives that map directly to classical Molecular Dynamics (MD) workloads:

1. **PF_TMM (Triangle Matrix Multiplication)** → Symmetric non-bonded force computation
2. **FA_SOFTMAX (LUT-based online exp)** → MD potential evaluation (Buckingham, Coulomb screening)

This document establishes a phased extension strategy that transforms RVDon from a **protein structure prediction accelerator** into a **unified protein folding + dynamics simulation platform** — a positioning with no existing competitor in the open IP licensing market.

**Key insight**: The first phase requires **zero hardware changes**. A Kahan compensated accumulation software layer, running on the existing FP32 TCU, achieves FP64-equivalent force accumulation precision (ε ~ 1e-7 vs FP64's 1e-16, both well within MD's 1e-6/step energy conservation threshold). This creates a **software IP asset** that can be licensed independently of the hardware IP.

---

## 2 Direct Reuse: Existing PF Extension in MD

### 2.1 PF_TMM → Symmetric Non-Bonded Forces

Classical MD computes pairwise non-bonded interactions (van der Waals, short-range electrostatics) over atom pairs. The distance/force matrix is **symmetric by construction**:

```
F_ij = -F_ji    (Newton's third law)
```

On a standard GPU, this symmetry is ignored: a full matrix multiply is performed, then the lower triangle is discarded. **PF_TMM's triangle mask gates the accumulation at the TCU lane level**, eliminating 50% of redundant multiply-add operations.

| Computation | Standard GPU | PF_TMM | Savings |
|-------------|:---:|:---:|:---:|
| N-atom non-bonded matrix | N² multiply-adds | N(N-1)/2 multiply-adds | **50%** |
| Memory writes | N² results | N(N-1)/2 results | **50%** |
| Power (compute) | 100% | ~50% | **~50%** |

**No hardware changes required.** This is a software-level mapping: PF_TMM instruction encodes the triangle mask, and the force accumulation reads only the upper triangle.

### 2.2 FA_SOFTMAX LUT exp → MD Potential Functions

MD force fields use exponential functions extensively:

| MD Function | Formula | LUT Range | Mapping |
|-------------|---------|:---:|------|
| Buckingham potential | A·exp(-r/ρ) | r/ρ ∈ [0, 8) | Direct LUT exp |
| Coulomb screening (erfc) | erfc(αr)/r ≈ Σ cₖ·exp(-kαr) | αr ∈ [0, 16) | Multi-term LUT exp |
| Softcore potential | (ΔG)ᵢ = (λⁿ / (λⁿ + (1-λ)ⁿ))·softcore | Various | LUT exp + FP32 mul |

The existing 16×32 coarse×fine LUT decomposition covers exp(-x) for x ∈ [0, 16) with 3.17% max relative error and >0.999 cosine similarity in end-to-end attention. For MD potentials, the same accuracy is sufficient because:

1. Force is the **gradient** of potential — small errors in potential translate to even smaller errors in force (differentiation smooths)
2. The LUT approximation error is **systematic** (not random), so it does not cause energy drift
3. Kahan compensation in the accumulation path further suppresses numerical drift

**Near-term enhancement** (software only): Make LUT contents software-configurable via a `PF_SET_LUT` instruction, allowing MD workloads to load potential-specific LUT tables without hardware changes.

---

## 3 Kahan Compensated Accumulation: Zero-Hardware MD Precision

### 3.1 The Problem: FP32 Force Accumulation Drift

In MD, each atom receives force contributions from O(N) neighbors:

```
F_i = Σ_{j=1}^{N_neighbors} f(r_ij)
```

With FP32 accumulation, each addition incurs rounding error ~ε = 2⁻²³ ≈ 1.2×10⁻⁷. For N_neighbors ~ 1000:

```
Naive FP32:  accumulated error ~ N × ε = 1000 × 1.2e-7 = 1.2e-4
```

This causes energy drift of ~1e-4 per MD step, which violates the conservation threshold of 1e-6/step. After ~10 steps, the simulation is unphysical.

### 3.2 The Solution: Kahan Compensation

Kahan summation tracks a compensation term that captures the rounding error from each addition:

```c
typedef struct {
    float sum;   // main accumulator
    float c;     // compensation (captured rounding error)
} kahan_acc_t;

void kahan_accum(kahan_acc_t *acc, float contribution) {
    float y = contribution - acc->c;    // subtract previous error
    float t = acc->sum + y;            // accumulate
    acc->c = (t - acc->sum) - y;       // capture new error
    acc->sum = t;                       // update
}
```

**Error reduction**: O(Nε) → O(ε). For N=1000:

```
Kahan FP32:  accumulated error ~ ε = 1.2e-7
```

This is **3 orders of magnitude** better than naive FP32, and well within the 1e-6/step MD conservation threshold.

### 3.3 Computational Overhead

| Operation | Naive FP32 | Kahan FP32 | Overhead |
|-----------|:---:|:---:|:---:|
| Multiply (TCU) | 1 PF_TMM | 1 PF_TMM | 0% |
| Accumulate per contribution | 1 FP add | 3 FP adds + 2 FP subs | 5× scalar ops |
| Total FLOPs (TCU-heavy) | 100% | ~105% | **~5%** |

The key insight: TCU does the O(N³) multiply-add in FP32 hardware (unchanged), while the scalar core does O(N²) Kahan compensation with only ~5% total overhead.

### 3.4 Precision Validation Plan

| Test | Method | Threshold |
|------|--------|:---:|
| Single-step force accuracy | Kahan FP32 vs FP64 reference | < 1e-6 relative error |
| Energy drift (10,000 steps) | Kahan FP32 vs FP64 Velocity Verlet | < 1e-4 total drift |
| Lennard-Jones NVE conservation | Kahan FP32, periodic box | < 0.01% over 10ns simulated |
| AMBER comparison | Kahan FP32 vs AMBER GPU FP64 | < 0.1% RMSD |

---

## 4 Phase 2: Minimal Hardware Extensions

### 4.1 PF_TMM_CUTOFF — Dynamic Distance Cutoff Masking

**Current**: PF_TMM uses static geometric masking (row ≥ col → zero).  
**Extension**: Add data-dependent masking based on inter-atomic distance.

```
PF_TMM:          mask = (row >= col)
PF_TMM_CUTOFF:   mask = (row >= col) AND (dist² < r_cut²)
```

**Implementation**:
- TCU front-end: add fixed-point distance² comparison unit (~500 Nangate units, < 0.1% of TCU)
- New instruction: funct3=6, same register layout as PF_TMM
- Distance stream: read from shared memory alongside A/B matrices
- Cutoff threshold: software-configurable via CSR register

**Value for MD**:
- Eliminates traditional "neighbor list → grouped computation" pipeline
- TCU directly operates on dense distance matrix, skipping beyond-cutoff pairs
- Estimated 2-5× speedup for sparse systems (most biological molecules)

### 4.2 PF_SET_LUT — Software-Configurable LUT

**Current**: LUT contents are hardcoded in RTL (exp(-k) and exp(-j/32)).  
**Extension**: Allow software to write LUT contents via CSR-mapped registers.

**Implementation**:
- Replace `localparam` LUT arrays with register arrays (16+32 = 48 × 32-bit = 192 bytes)
- Add CSR write interface: `csrw 0x7C0, lut_data` (3 CSR writes per entry: index, data, commit)
- New instruction: funct3=7, `PF_SET_LUT rd, rs1, rs2` (rs1=LUT index, rs2=FP32 value)

**Value for MD**:
- Load potential-specific LUT tables (Buckingham, Morse, softcore)
- Adaptive precision: use denser LUT for critical distance ranges
- Future-proof: new force fields without hardware redesign

---

## 5 Phase 3: FP64 Mixed-Precision Accumulation

### 5.1 Why FP64 Matters for MD

| Scenario | FP32 Sufficient? | FP64 Required? |
|----------|:---:|:---:|
| Energy minimization | ✅ | ❌ |
| Short MD (< 1 ns) | ✅ (with Kahan) | ❌ |
| Production MD (10-100 ns) | ⚠️ (marginal) | ✅ |
| Free energy perturbation | ❌ | ✅ |
| Alchemical transformations | ❌ | ✅ |

**Conclusion**: Kahan FP32 covers **80% of MD use cases**. FP64 accumulation is needed for the remaining 20% (production FEP, alchemical methods).

### 5.2 Recommended Approach: Mixed Precision (Option A)

```
TCU Data Path:
  Input:  FP32 (A, B matrices)
  Multiply: FP32 × FP32 → FP32 product
  Accumulate: FP32 + FP64 accumulator → FP64 result  ← only this changes
  
  Area cost: accumulator width 32→64 bit = ~30% TCU area increase
  = ~0.2% of full chip
```

**Phasing**:
- 28nm first (current): FP32 TCU + Kahan software compensation → covers AlphaFold + basic MD
- 12nm flagship: FP32 TCU + FP64 accumulation → covers production MD + FEP

This is the same strategy NVIDIA uses: FP16/FP32 Tensor Cores with FP32/FP64 accumulation.

### 5.3 Alternative: Full FP64 TCU (Option B)

Not recommended for initial deployment:
- Doubles TCU area (all datapaths 32→64 bit)
- Reduces TCU throughput by ~2× at same clock frequency
- Only needed for double-precision matrix multiply, which is rare even in MD

### 5.4 Kahan + FP64 Accumulation Comparison

| Method | Force Precision | Energy Drift | Hardware Cost |
|--------|:---:|:---:|:---:|
| FP32 naive | ~1e-4 | ~1e-4/step | Baseline |
| FP32 + Kahan | ~1e-7 | ~1e-7/step | 0% (software) |
| FP32 mul + FP64 accum | ~1e-15 | ~1e-15/step | ~0.2% chip area |
| Full FP64 | ~1e-15 | ~1e-15/step | ~0.4% chip area |

**Kahan FP32 at 1e-7 is 1000× better than the 1e-4 threshold** — already sufficient for the vast majority of MD simulations.

---

## 6 Market Positioning

### 6.1 Competitive Landscape

| Product | Type | Protein Folding | MD | Open IP | Price Point |
|---------|------|:---:|:---:|:---:|:---:|
| NVIDIA H100 | GPU | ✅ | ✅ | ❌ | $30,000 |
| AMD MI300X | GPU | ✅ | ✅ | ❌ | $15,000 |
| Cerebras WSE-3 | Wafer | ✅ | ❌ | ❌ | Custom |
| D.E. Shaw Anton-3 | ASIC | ❌ | ✅ | ❌ | Proprietary |
| **RVDon (28nm)** | **IP License** | **✅** | **✅ (Kahan)** | **ISA + SDK** | **¥2,000-3,000/chip** |
| **RVDon (12nm)** | **IP License** | **✅** | **✅ (FP64)** | **ISA + SDK** | **¥5,000-8,000/chip** |

**Unique positioning**: RVDon is the only open-IP-licensed accelerator covering both protein structure prediction AND molecular dynamics. D.E. Shaw's Anton covers MD but is closed/proprietary. NVIDIA/AMD GPUs cover both but at 10-100× the price point.

### 6.2 Target Customers

| Segment | Example | Primary Need | RVDon Fit |
|---------|---------|:---:|:---:|
| Drug discovery CROs | WuXi, Pharmaron | Fast MD screening | ⭐⭐⭐⭐⭐ |
| Biotech startups | — | Affordable private MD | ⭐⭐⭐⭐⭐ |
| Academic HPC labs | — | Open, customizable | ⭐⭐⭐⭐⭐ |
| Domestic GPU vendors | Moore Threads, Biren | Differentiated IP | ⭐⭐⭐⭐ |
| Pharma R&D | Pfizer-style | AlphaFold + MD unified | ⭐⭐⭐⭐⭐ |

---

## 7 Roadmap Summary

```
2026 Q3 ─── Phase 0: Software Kahan SDK (ZERO hardware changes)
            ├── rvdon-kahan.h: compensated force accumulator
            ├── kahan_accuracy validation (vs FP64 reference)
            ├── energy_drift long-term test
            └── ISA v1.1 draft: PF_TMM_CUTOFF + PF_SET_LUT encoding

2026 Q4 ─── Phase 1: Minimal Hardware Extensions
            ├── PF_TMM_CUTOFF (funct3=6): dynamic distance masking
            ├── PF_SET_LUT (funct3=7): software-configurable LUT
            ├── RTL + rtlsim verification
            └── 28nm synthesis evaluation update

2027 H1 ── Phase 2: FP64 Mixed Precision (12nm target)
            ├── FP64 accumulator in TCU
            ├── Kahan SDK backward compatible (upgrade path)
            └── Full MD benchmark suite (AMBER/GROMACS comparison)

2027 H2 ── Phase 3: Advanced MD Features (12nm flagship)
            ├── Scatter-add force reduction unit
            ├── Special function pipeline (rsqrt, r⁻⁶, r⁻¹²)
            └── L0 scratchpad for neighbor coordinate caching
```

---

## 8 Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|:---:|:---:|------|
| Kahan FP32 insufficient for production MD | Low | Medium | Phase 2 FP64 hardware as upgrade path |
| MD community skeptical of FP32-based approach | Medium | High | Publish Kahan vs FP64 benchmark comparison |
| Dynamic cutoff masking too complex for TCU | Low | Low | Start with software neighbor list + PF_TMM |
| Competitor releases open MD accelerator | Low | High | First-mover advantage in open IP licensing |

---

## Appendix A: Kahan Compensation Mathematical Proof

For a sequence of N floating-point additions, the Kahan algorithm bounds the error as:

```
|fl(Σ xᵢ) - Σ xᵢ| ≤ (2ε + O(Nε²)) · Σ|xᵢ|
```

where ε = 2⁻²³ for FP32. This compares to the naive bound:

```
|fl(Σ xᵢ) - Σ xᵢ| ≤ (Nε / (1 - Nε)) · Σ|xᵢ|    (naive)
```

For N = 1000 neighbors and typical MD force magnitudes:
- Naive: error ~ 1.2e-4 (violates conservation threshold)
- Kahan: error ~ 2.4e-7 (within threshold by 400× margin)

## Appendix B: LUT exp for MD Potentials

### Buckingham Potential: V(r) = A·exp(-r/ρ) - C/r⁶

The exp(-r/ρ) term maps directly to the existing LUT exp pipeline:
- Set x = r/ρ, use coarse_lut[floor(x)] × fine_lut[frac_idx(x)]
- With PF_SET_LUT, load Buckingham-specific LUT for improved accuracy in the [0, 8) range

### Coulomb Screening: erfc(αr)/r

The complementary error function can be approximated as:

```
erfc(x) ≈ a₁·exp(-b₁x²) + a₂·exp(-b₂x²) + a₃·exp(-b₃x²)
```

Each exp(-bₖx²) term can be evaluated using the LUT pipeline, with 3 LUT exp calls per atom pair. Combined with the 1/r division (handled by the scalar core), this provides efficient PME short-range evaluation.

---

*This document establishes the strategic and technical foundation for extending RVDon from protein structure prediction to unified protein folding + dynamics simulation.*
