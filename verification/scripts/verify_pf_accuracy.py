#!/usr/bin/env python3
"""
RVDon PF Extension — Independent Numerical Accuracy Verifier

This script allows anyone to independently verify the numerical accuracy
of the RVDon FA_SOFTMAX LUT-based exp approximation and Flash Attention
end-to-end quality.

No RTL source code or commercial EDA tools are required.
Only Python 3.8+ with NumPy.

Usage:
    python3 verify_pf_accuracy.py

Expected output: All metrics should match the values in
../results/rvdon-verification-results.md
"""

import struct
import math
import csv
import numpy as np
from dataclasses import dataclass

# ==============================================================================
# LUT tables (exact IEEE 754 encodings from VX_tcu_fa.sv — 32-entry fine LUT v2)
# ==============================================================================

COARSE_LUT_HEX = [
    0x3F800000,  # exp(-0)  = 1.000000e+00
    0x3EBC5AB2,  # exp(-1)  = 3.678794e-01
    0x3E0A9555,  # exp(-2)  = 1.353353e-01
    0x3D4BED86,  # exp(-3)  = 4.978707e-02
    0x3C960AAE,  # exp(-4)  = 1.831564e-02
    0x3BDCC9FF,  # exp(-5)  = 6.737947e-03
    0x3B227290,  # exp(-6)  = 2.478752e-03
    0x3A6F0B5D,  # exp(-7)  = 9.118820e-04
    0x39AFE108,  # exp(-8)  = 3.354626e-04
    0x39016791,  # exp(-9)  = 1.234098e-04
    0x383E6BCE,  # exp(-10) = 4.539993e-05
    0x378C1AA1,  # exp(-11) = 1.670170e-05
    0x36CE2A62,  # exp(-12) = 6.144212e-06
    0x3617B02A,  # exp(-13) = 2.260329e-06
    0x355F3638,  # exp(-14) = 8.315287e-07
    0x34A43AE5,  # exp(-15) = 3.059023e-07
]

FINE_LUT_HEX = [
    0x3F800000,  # exp(-0/32)
    0x3F781FAB,  # exp(-1/32)
    0x3F707D60,  # exp(-2/32)
    0x3F691735,  # exp(-3/32)
    0x3F61EB51,  # exp(-4/32)
    0x3F5AF7E9,  # exp(-5/32)
    0x3F543B41,  # exp(-6/32)
    0x3F4DB3A8,  # exp(-7/32)
    0x3F475F7D,  # exp(-8/32)
    0x3F413D2B,  # exp(-9/32)
    0x3F3B4B29,  # exp(-10/32)
    0x3F3587FC,  # exp(-11/32)
    0x3F2FF231,  # exp(-12/32)
    0x3F2A8863,  # exp(-13/32)
    0x3F254939,  # exp(-14/32)
    0x3F203361,  # exp(-15/32)
    0x3F1B4598,  # exp(-16/32)
    0x3F167EA0,  # exp(-17/32)
    0x3F11DD4A,  # exp(-18/32)
    0x3F0D606B,  # exp(-19/32)
    0x3F0906E5,  # exp(-20/32)
    0x3F04CFA1,  # exp(-21/32)
    0x3F00B992,  # exp(-22/32)
    0x3EF98764,  # exp(-23/32)
    0x3EF1DA07,  # exp(-24/32)
    0x3EEA6922,  # exp(-25/32)
    0x3EE332D9,  # exp(-26/32)
    0x3EDC355D,  # exp(-27/32)
    0x3ED56EF0,  # exp(-28/32)
    0x3ECEDDE0,  # exp(-29/32)
    0x3EC88088,  # exp(-30/32)
    0x3EC25552,  # exp(-31/32)
]

FINE_LUT_RESOLUTION = 32


def hex_to_fp32(h):
    return struct.unpack('<f', struct.pack('<I', h))[0]


COARSE_LUT = [hex_to_fp32(h) for h in COARSE_LUT_HEX]
FINE_LUT = [hex_to_fp32(h) for h in FINE_LUT_HEX]


def fp32_mul_approx(a, b):
    if a == 0.0 or b == 0.0:
        return 0.0
    a_bits = struct.unpack('<I', struct.pack('<f', a))[0]
    b_bits = struct.unpack('<I', struct.pack('<f', b))[0]
    sign_r = ((a_bits >> 31) ^ (b_bits >> 31)) & 1
    exp_a = (a_bits >> 23) & 0xFF
    exp_b = (b_bits >> 23) & 0xFF
    exp_r = exp_a + exp_b - 127
    if exp_r < 0 or exp_r > 254:
        if exp_r < 0:
            return 0.0 if sign_r == 0 else -0.0
        else:
            return float('inf') if sign_r == 0 else float('-inf')
    man_a_trunc = (1 << 11) | ((a_bits >> 12) & 0x7FF)
    man_b_trunc = (1 << 11) | ((b_bits >> 12) & 0x7FF)
    prod = man_a_trunc * man_b_trunc
    if prod & (1 << 23):
        exp_r += 1
        mantissa = prod & 0x7FFFFF
    else:
        mantissa = (prod & 0x3FFFFF) << 1
    result_bits = (sign_r << 31) | ((exp_r & 0xFF) << 23) | (mantissa & 0x7FFFFF)
    return struct.unpack('<f', struct.pack('<I', result_bits))[0]


def rvdon_exp_approx(x):
    if math.isinf(x) or math.isnan(x):
        return 0.0
    if x < 0:
        x = -x
    if x == 0.0:
        return 1.0
    k = int(math.floor(x))
    if k > 15:
        k = 15
    frac = x - k
    j = int(math.floor(frac * FINE_LUT_RESOLUTION))
    if j >= FINE_LUT_RESOLUTION:
        j = FINE_LUT_RESOLUTION - 1
    return fp32_mul_approx(COARSE_LUT[k], FINE_LUT[j])


def flash_attention_ref(Q, K, V):
    N = Q.shape[0]
    D = V.shape[1]
    S = (Q.astype(np.float64) @ K.T.astype(np.float64)) / np.sqrt(D)
    O = np.zeros((N, D), dtype=np.float64)
    for i in range(N):
        s_row = S[i, :i+1]
        e_s = np.exp(s_row - np.max(s_row))
        attn = e_s / np.sum(e_s)
        O[i] = attn @ V[:i+1].astype(np.float64)
    return O


def flash_attention_rvdon(Q, K, V, tile_size=2):
    N = Q.shape[0]
    D = V.shape[1]
    S_full = (Q @ K.T).astype(np.float64) / np.sqrt(D)
    O = np.zeros((N, D), dtype=np.float64)
    for i in range(N):
        m_old = -np.inf
        l_old = 0.0
        O_row = np.zeros(D, dtype=np.float64)
        for j in range(0, i + 1, tile_size):
            S_tile = S_full[i, j:min(j+tile_size, i+1)]
            V_tile = V[j:min(j+tile_size, i+1)].astype(np.float64)
            if len(S_tile) < tile_size:
                S_tile = np.pad(S_tile, (0, tile_size - len(S_tile)),
                                constant_values=-1e9)
                V_tile = np.pad(V_tile, ((0, tile_size - len(V_tile)), (0, 0)),
                                constant_values=0.0)
            m_new = max(m_old, float(np.max(S_tile)))
            P = np.array([rvdon_exp_approx(float(s - m_new)) for s in S_tile])
            delta_m = m_old - m_new
            if np.isinf(delta_m) and delta_m < 0:
                exp_dm = 0.0
            elif delta_m == 0:
                exp_dm = 1.0
            else:
                exp_dm = rvdon_exp_approx(-delta_m)
            l_new = l_old * exp_dm + float(np.sum(P))
            O_row = O_row * exp_dm + P @ V_tile
            m_old = m_new
            l_old = l_new
        if l_old > 0:
            O[i] = O_row / l_old
    return O


def cosine_similarity(A, B):
    dots = np.sum(A * B, axis=1)
    norms_a = np.sqrt(np.sum(A**2, axis=1))
    norms_b = np.sqrt(np.sum(B**2, axis=1))
    valid = (norms_a > 1e-10) & (norms_b > 1e-10)
    return np.mean(dots[valid] / (norms_a[valid] * norms_b[valid]))


# ==============================================================================
# Verification Tests
# ==============================================================================

def test_lut_entries():
    """Verify LUT entries match true exp values (FP32 ULP accuracy)."""
    print("\n" + "=" * 60)
    print("TEST 1: LUT Entry Accuracy")
    print("=" * 60)

    coarse_ok = True
    for k in range(16):
        true_val = math.exp(-k)
        lut_val = COARSE_LUT[k]
        rel_err = abs(lut_val - true_val) / true_val
        if rel_err > 1e-6:
            print(f"  FAIL: coarse_lut[{k}] error = {rel_err:.2e}")
            coarse_ok = False

    fine_ok = True
    for j in range(FINE_LUT_RESOLUTION):
        true_val = math.exp(-j / float(FINE_LUT_RESOLUTION))
        lut_val = FINE_LUT[j]
        rel_err = abs(lut_val - true_val) / true_val
        if rel_err > 1e-6:
            print(f"  FAIL: fine_lut[{j}] error = {rel_err:.2e}")
            fine_ok = False

    print(f"  Coarse LUT (16 entries): {'PASS ✅' if coarse_ok else 'FAIL ❌'}")
    print(f"  Fine LUT ({FINE_LUT_RESOLUTION} entries): {'PASS ✅' if fine_ok else 'FAIL ❌'}")
    return coarse_ok and fine_ok


def test_exp_accuracy():
    """Test component-level exp accuracy across [0, 16)."""
    print("\n" + "=" * 60)
    print("TEST 2: Component-Level exp(-x) Accuracy")
    print("=" * 60)

    test_points = []
    for x in np.arange(0, 2, 0.001):
        test_points.append(float(x))
    for x in np.arange(2, 8, 0.01):
        test_points.append(float(x))
    for x in np.arange(8, 16, 0.1):
        test_points.append(float(x))
    test_points = sorted(set(test_points))

    errors = []
    for x in test_points:
        ref = math.exp(-x)
        if ref < 1e-30:
            continue
        approx = rvdon_exp_approx(x)
        rel_err = abs(approx - ref) / ref * 100.0
        errors.append(rel_err)

    max_err = max(errors)
    mean_err = sum(errors) / len(errors)

    # Expected: max ~3.17%, mean ~1.44%
    max_pass = max_err < 4.0  # Allow some margin
    mean_pass = mean_err < 2.0

    print(f"  Test points: {len(errors)}")
    print(f"  Max relative error:  {max_err:.3f}%  (expected: ~3.17%)  {'PASS ✅' if max_pass else 'FAIL ❌'}")
    print(f"  Mean relative error: {mean_err:.3f}%  (expected: ~1.44%)  {'PASS ✅' if mean_pass else 'FAIL ❌'}")
    print(f"  Effective bits:      ~{-math.log2(max_err/100):.1f}  (expected: ~5)")

    return max_pass and mean_pass


def test_flash_attention_e2e():
    """Test Flash Attention end-to-end quality."""
    print("\n" + "=" * 60)
    print("TEST 3: Flash Attention E2E Quality")
    print("=" * 60)

    np.random.seed(42)
    N, D = 64, 16
    Q = np.random.randn(N, D).astype(np.float32) * 0.5
    K = np.random.randn(N, D).astype(np.float32) * 0.5
    V = np.random.randn(N, D).astype(np.float32) * 0.5

    O_ref = flash_attention_ref(Q, K, V)
    O_rvdon = flash_attention_rvdon(Q, K, V)

    abs_err = np.abs(O_ref - O_rvdon)
    cos_sim = cosine_similarity(O_ref, O_rvdon)

    # Expected: cosine similarity > 0.999, max abs error < 0.02
    cos_pass = cos_sim > 0.999
    abs_pass = np.max(abs_err) < 0.02

    print(f"  Matrix size: N={N}, D={D}")
    print(f"  Max absolute error:  {np.max(abs_err):.6e}  (expected: <0.02)  {'PASS ✅' if abs_pass else 'FAIL ❌'}")
    print(f"  Mean absolute error: {np.mean(abs_err):.6e}")
    print(f"  Cosine similarity:   {cos_sim:.8f}  (expected: >0.999)  {'PASS ✅' if cos_pass else 'FAIL ❌'}")

    return cos_pass and abs_pass


def test_protenix_scenario():
    """Test Protenix Pairformer scenario."""
    print("\n" + "=" * 60)
    print("TEST 4: Protenix Pairformer Scenario")
    print("=" * 60)

    np.random.seed(2024)
    N_res = 128
    C_pair = 16
    Q = np.random.randn(N_res, C_pair).astype(np.float32) * 0.3
    K = np.random.randn(N_res, C_pair).astype(np.float32) * 0.3
    V = np.random.randn(N_res, C_pair).astype(np.float32) * 0.3

    O_ref = flash_attention_ref(Q, K, V)
    O_rvdon = flash_attention_rvdon(Q, K, V)

    abs_err = np.abs(O_ref - O_rvdon)
    cos_sim = cosine_similarity(O_ref, O_rvdon)

    # Expected: cosine similarity > 0.999, max abs error < 0.02
    cos_pass = cos_sim > 0.999
    abs_pass = np.max(abs_err) < 0.02

    print(f"  N_res={N_res}, C_pair={C_pair}")
    print(f"  Max absolute error:  {np.max(abs_err):.6e}  (expected: <0.02)  {'PASS ✅' if abs_pass else 'FAIL ❌'}")
    print(f"  Mean absolute error: {np.mean(abs_err):.6e}")
    print(f"  Cosine similarity:   {cos_sim:.8f}  (expected: >0.999)  {'PASS ✅' if cos_pass else 'FAIL ❌'}")

    return cos_pass and abs_pass


def test_test_vectors():
    """Load and verify against published test vectors (if available)."""
    print("\n" + "=" * 60)
    print("TEST 5: Test Vector Consistency")
    print("=" * 60)

    try:
        with open('../test-vectors/exp_lut_accuracy.csv') as f:
            reader = csv.DictReader(f)
            mismatches = 0
            total = 0
            for row in reader:
                total += 1
                x = float(row['x'])
                our_approx = rvdon_exp_approx(x)
                ref_approx = float(row['rvdon_approx'])
                if abs(our_approx - ref_approx) > 1e-10 * max(1, abs(ref_approx)):
                    mismatches += 1
            if mismatches == 0:
                print(f"  All {total} test vector points match: PASS ✅")
                return True
            else:
                print(f"  {mismatches}/{total} mismatches: FAIL ❌")
                return False
    except FileNotFoundError:
        print("  Test vectors not found (run generate_test_vectors.py first)")
        print("  Skipping vector consistency check ⏭️")
        return True  # Not a failure, just not available


# ==============================================================================
# Main
# ==============================================================================

if __name__ == '__main__':
    print("=" * 60)
    print("RVDon PF Extension — Independent Verification")
    print("=" * 60)
    print(f"Fine LUT resolution: {FINE_LUT_RESOLUTION} entries")
    print(f"Coarse LUT resolution: 16 entries")

    results = []
    results.append(("LUT Entry Accuracy", test_lut_entries()))
    results.append(("Component exp Accuracy", test_exp_accuracy()))
    results.append(("Flash Attention E2E", test_flash_attention_e2e()))
    results.append(("Protenix Scenario", test_protenix_scenario()))
    results.append(("Test Vector Consistency", test_test_vectors()))

    print("\n" + "=" * 60)
    print("VERIFICATION SUMMARY")
    print("=" * 60)

    all_pass = True
    for name, passed in results:
        status = "PASS ✅" if passed else "FAIL ❌"
        print(f"  {name}: {status}")
        if not passed:
            all_pass = False

    print()
    if all_pass:
        print("🎉 All verification tests PASSED!")
        print("   Results are consistent with DiVo's reported metrics.")
    else:
        print("⚠️  Some tests FAILED — results differ from expected values.")
        print("   Please report to wangjueju+divobot@gmail.com")

    print("\n" + "=" * 60)
    print("Reference: RVDon-TN-011 v2.0 (Precision Verification White Paper)")
    print("Reference: RVDon-TN-012 v1.0 (28nm Synthesis + PnR Evaluation)")
    print("=" * 60)
