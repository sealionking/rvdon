#!/usr/bin/env python3
"""
RVDon PF Extension — Test Vector Generator

Generates reference test vectors for independent verification of the
RVDon FA_SOFTMAX numerical accuracy. Uses pure Python + NumPy (no RTL needed).

Output files:
  - flash_attention_vectors.csv: Q/K/V inputs + FP64 reference attention output
  - exp_lut_accuracy.csv: exp(-x) at key points: true vs LUT approximation
  - protenix_pairformer.csv: Protenix Pairformer scenario vectors
"""

import struct
import math
import csv
import os
import numpy as np

# ==============================================================================
# LUT tables (from VX_tcu_fa.sv — 32-entry fine LUT v2)
# ==============================================================================

COARSE_LUT_HEX = [
    0x3F800000, 0x3EBC5AB2, 0x3E0A9555, 0x3D4BED86,
    0x3C960AAE, 0x3BDCC9FF, 0x3B227290, 0x3A6F0B5D,
    0x39AFE108, 0x39016791, 0x383E6BCE, 0x378C1AA1,
    0x36CE2A62, 0x3617B02A, 0x355F3638, 0x34A43AE5,
]

FINE_LUT_HEX = [
    0x3F800000, 0x3F781FAB, 0x3F707D60, 0x3F691735,
    0x3F61EB51, 0x3F5AF7E9, 0x3F543B41, 0x3F4DB3A8,
    0x3F475F7D, 0x3F413D2B, 0x3F3B4B29, 0x3F3587FC,
    0x3F2FF231, 0x3F2A8863, 0x3F254939, 0x3F203361,
    0x3F1B4598, 0x3F167EA0, 0x3F11DD4A, 0x3F0D606B,
    0x3F0906E5, 0x3F04CFA1, 0x3F00B992, 0x3EF98764,
    0x3EF1DA07, 0x3EEA6922, 0x3EE332D9, 0x3EDC355D,
    0x3ED56EF0, 0x3ECEDDE0, 0x3EC88088, 0x3EC25552,
]

FINE_LUT_RESOLUTION = 32


def hex_to_fp32(h):
    return struct.unpack('<f', struct.pack('<I', h))[0]


COARSE_LUT = [hex_to_fp32(h) for h in COARSE_LUT_HEX]
FINE_LUT = [hex_to_fp32(h) for h in FINE_LUT_HEX]


def fp32_mul_approx(a, b):
    """Reproduce 12-bit truncated mantissa multiply from VX_tcu_fa.sv."""
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
    """RVDon exp(-x) with 32-entry fine LUT + approximate multiply."""
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
    """FP64 one-shot reference (no tiling, exact exp)."""
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
    """Flash Attention with RVDon LUT exp, tiled accumulation."""
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


# ==============================================================================
# Generate test vectors
# ==============================================================================

def generate_exp_vectors():
    """Generate exp(-x) accuracy test vectors."""
    test_xs = []
    # Dense grid in [0, 2)
    for x_10 in range(0, 200, 1):
        test_xs.append(x_10 / 100.0)
    # Integer boundaries
    for k in range(16):
        test_xs.append(float(k))
    # LUT boundary points (32-entry fine)
    for k in range(16):
        for j in range(32):
            test_xs.append(float(k) + float(j) / 32.0)
    # Midpoints between LUT entries
    for k in range(16):
        for j in range(31):
            test_xs.append(float(k) + (float(j) + 0.5) / 32.0)

    test_xs = sorted(set(test_xs))

    vec_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'test-vectors')
    os.makedirs(vec_dir, exist_ok=True)

    with open(os.path.join(vec_dir, 'exp_lut_accuracy.csv'), 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(['x', 'true_exp_neg_x', 'rvdon_approx', 'relative_error_pct',
                         'coarse_idx', 'fine_idx'])
        for x in test_xs:
            true_val = math.exp(-x)
            approx = rvdon_exp_approx(x)
            if true_val > 1e-30:
                rel_err = abs(approx - true_val) / true_val * 100.0
            else:
                rel_err = 0.0
            k = min(int(math.floor(x)), 15)
            frac = x - int(math.floor(x))
            j = min(int(math.floor(frac * FINE_LUT_RESOLUTION)), FINE_LUT_RESOLUTION - 1)
            writer.writerow([f'{x:.6f}', f'{true_val:.10e}', f'{approx:.10e}',
                             f'{rel_err:.4f}', k, j])

    print(f"Generated exp_lut_accuracy.csv: {len(test_xs)} test points")


def generate_flash_attention_vectors():
    """Generate Flash Attention test vectors with FP64 reference."""
    vec_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'test-vectors')
    np.random.seed(42)  # Reproducible

    N, D = 16, 8  # Small but representative
    Q = np.random.randn(N, D).astype(np.float32) * 0.5
    K = np.random.randn(N, D).astype(np.float32) * 0.5
    V = np.random.randn(N, D).astype(np.float32) * 0.5

    O_ref = flash_attention_ref(Q, K, V)
    O_rvdon = flash_attention_rvdon(Q, K, V)

    # Cosine similarity
    dots = np.sum(O_ref * O_rvdon, axis=1)
    norms_r = np.sqrt(np.sum(O_ref**2, axis=1))
    norms_a = np.sqrt(np.sum(O_rvdon**2, axis=1))
    valid = (norms_r > 1e-10) & (norms_a > 1e-10)
    cos_sims = dots[valid] / (norms_r[valid] * norms_a[valid])

    with open(os.path.join(vec_dir, 'flash_attention_vectors.csv'), 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(['row', 'col', 'Q_value', 'K_value', 'V_value',
                         'FP64_reference_O', 'RVDon_approx_O', 'abs_error'])
        for i in range(N):
            for d in range(D):
                writer.writerow([i, d, f'{Q[i,d]:.8f}', f'{K[i,d]:.8f}',
                                 f'{V[i,d]:.8f}', f'{O_ref[i,d]:.10e}',
                                 f'{O_rvdon[i,d]:.10e}',
                                 f'{abs(O_ref[i,d] - O_rvdon[i,d]):.6e}'])

    # Write Q/K/V matrices separately for easy loading
    with open(os.path.join(vec_dir, 'flash_attention_qkv.csv'), 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(['matrix', 'row', 'col', 'value'])
        for i in range(N):
            for d in range(D):
                writer.writerow(['Q', i, d, f'{Q[i,d]:.8f}'])
                writer.writerow(['K', i, d, f'{K[i,d]:.8f}'])
                writer.writerow(['V', i, d, f'{V[i,d]:.8f}'])

    print(f"Generated flash_attention_vectors.csv: N={N}, D={D}")
    print(f"  Mean cosine similarity: {np.mean(cos_sims):.8f}")
    print(f"  Max absolute error: {np.max(np.abs(O_ref - O_rvdon)):.6e}")


def generate_protenix_vectors():
    """Generate Protenix Pairformer scenario test vectors."""
    vec_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'test-vectors')
    np.random.seed(2024)

    N_res = 64   # Reduced for vector file size
    C_pair = 16
    Q = np.random.randn(N_res, C_pair).astype(np.float32) * 0.3
    K = np.random.randn(N_res, C_pair).astype(np.float32) * 0.3
    V = np.random.randn(N_res, C_pair).astype(np.float32) * 0.3

    O_ref = flash_attention_ref(Q, K, V)
    O_rvdon = flash_attention_rvdon(Q, K, V)

    # Compute metrics
    abs_err = np.abs(O_ref - O_rvdon)
    dots = np.sum(O_ref * O_rvdon, axis=1)
    norms_r = np.sqrt(np.sum(O_ref**2, axis=1))
    norms_a = np.sqrt(np.sum(O_rvdon**2, axis=1))
    valid = (norms_r > 1e-10) & (norms_a > 1e-10)
    cos_sims = dots[valid] / (norms_r[valid] * norms_a[valid])

    # Only save summary + first few rows (full vectors would be too large)
    with open(os.path.join(vec_dir, 'protenix_pairformer.csv'), 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(['row', 'col', 'FP64_reference_O', 'RVDon_approx_O', 'abs_error'])
        for i in range(min(8, N_res)):  # First 8 rows
            for d in range(C_pair):
                writer.writerow([i, d, f'{O_ref[i,d]:.10e}', f'{O_rvdon[i,d]:.10e}',
                                 f'{abs_err[i,d]:.6e}'])

    print(f"Generated protenix_pairformer.csv: N_res={N_res}, C_pair={C_pair}")
    print(f"  Mean cosine similarity: {np.mean(cos_sims):.8f}")
    print(f"  Max absolute error: {np.max(abs_err):.6e}")


if __name__ == '__main__':
    print("=" * 60)
    print("RVDon PF Extension — Test Vector Generator")
    print("=" * 60)

    generate_exp_vectors()
    generate_flash_attention_vectors()
    generate_protenix_vectors()

    print("\n✅ All test vectors generated in test-vectors/")
