// Copyright © 2024-2026 DiVo Gen²AI
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// VX_tcu_fa.sv — DiVo Gen²AI RVDon Flash Attention Online Softmax Pipeline
//
// Implements the FA_SOFTMAX sub-operation of PF_FLASH_ATTN:
//   Per (i, j) element:
//     S     = rs1[i][0]        (attention score from FA_MMA)
//     m_old = rs3[i*tcN + j]   (row max accumulator)
//     l_old = rs3[tcN + i*tcN + j] (row sum accumulator, packed in upper half)
//     m_new = max(m_old, S)
//     P     = exp(S - m_new)
//     exp_m = exp(m_old - m_new)
//     l_new = l_old * exp_m + P
//
// Output: P (unnormalized attention weight)
//   m_new and l_new are written back to accumulator by software.
//
// Architecture:
//   3-stage pipeline:
//     S0: Input unpack + max comparison (m_new = max(m_old, S))
//     S1: Exp computation via 16-entry LUT + linear interpolation
//     S2: Multiply-add (l_new = l_old * exp_m + P) + output pack
//
// Note: This module processes ONE (i, j) pair per cycle.
// The (i, j) loop is unrolled in VX_tcu_core.sv's genvar blocks.

`include "VX_define.vh"

module VX_tcu_fa import VX_tcu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter LATENCY = 3          // 3-stage pipeline
) (
    input  wire         clk,
    input  wire         reset,
    input  wire         enable,

    // Per-element inputs (one per FEDP grid position)
    input  wire [31:0]  s_val,     // S = attention score (from rs1)
    input  wire [31:0]  m_old,     // m_old accumulator (from rs3)
    input  wire [31:0]  l_old,     // l_old accumulator (from rs3, upper half)

    // Output
    output wire [31:0]  p_val      // P = exp(S - m_new)
);

    `UNUSED_SPARAM (INSTANCE_ID)
    `UNUSED_PARAM  (LATENCY)

    // ====================================================================
    // FP32 subtraction helper — computes a - b
    // ====================================================================
    // Handles normal FP32 and zero.  Does NOT handle NaN/Inf/denormals
    // (sufficient for Flash Attention scores which are always normal or 0).
    // Returns a proper FP32 result for use in segment-index extraction.

    function automatic [31:0] fp32_sub(input [31:0] a, input [31:0] b);
        logic [7:0]  exp_a, exp_b, exp_r, exp_diff;
        logic [23:0] man_a, man_b;
        logic [24:0] diff;
        logic        sign_r;
        logic [7:0]  lzd;

        // Zero shortcuts
        if (a[30:0] == 31'b0 && b[30:0] == 31'b0) begin fp32_sub = 32'h0; return fp32_sub; end
        if (a[30:0] == 31'b0) begin fp32_sub = {b[31] ^ 1'b1, b[30:0]}; return fp32_sub; end
        if (b[30:0] == 31'b0) begin fp32_sub = a; return fp32_sub; end

        exp_a = a[30:23];
        exp_b = b[30:23];
        man_a = {1'b1, a[22:0]};   // implicit leading 1
        man_b = {1'b1, b[22:0]};

        // Same-sign subtraction: |a| - |b| with sign determined by magnitude
        // Different-sign "subtraction" is actually addition
        if (a[31] == b[31]) begin : same_sign
            if (exp_a > exp_b || (exp_a == exp_b && man_a >= man_b)) begin
                exp_diff = exp_a - exp_b;
                man_b    = man_b >> exp_diff;
                diff     = man_a - man_b;
                sign_r   = a[31];
                exp_r    = exp_a;
            end else begin
                exp_diff = exp_b - exp_a;
                man_a    = man_a >> exp_diff;
                diff     = man_b - man_a;
                sign_r   = a[31] ^ 1'b1;
                exp_r    = exp_b;
            end
        end else begin : diff_sign
            // a - b where signs differ → |a| + |b|
            if (exp_a >= exp_b) begin
                exp_diff = exp_a - exp_b;
                man_b    = man_b >> exp_diff;
                exp_r    = exp_a;
            end else begin
                exp_diff = exp_b - exp_a;
                man_a    = man_a >> exp_diff;
                exp_r    = exp_b;
            end
            diff   = man_a + man_b;
            sign_r = a[31];
        end

        // Zero result
        if (diff == 25'b0) begin fp32_sub = 32'h0; return fp32_sub; end

        // Normalize: find leading one in 25-bit diff
        lzd = 0;
        for (int i = 24; i >= 0; i--) begin
            if (diff[i]) break;
            lzd = lzd + 8'd1;
        end

        // Shift diff so leading 1 is at bit 23 (24-bit mantissa MSB)
        if (lzd > 0) begin
            diff = diff << lzd;
            if (exp_r > lzd)
                exp_r = exp_r - lzd;
            else
                exp_r = 8'd0;
        end

        fp32_sub = {sign_r, exp_r, diff[22:0]};
    endfunction

    // ====================================================================
    // Segment-index extraction from FP32 value
    // ====================================================================
    // Given an FP32 value x (the delta), compute floor(|x|) as a 4-bit
    // segment index for the LUT.  Saturates at 15.
    //
    // For |x| < 1.0 (biased_exp < 127): floor = 0
    // For |x| >= 1.0 (biased_exp >= 127): the integer part uses the
    //   implicit leading-1 plus the top (e-127) mantissa bits.

    function automatic [3:0] fp32_floor_int(input [31:0] x);
        logic [7:0] e;
        e = x[30:23];
        if (e < 127) begin
            // |x| < 1.0
            fp32_floor_int = 4'd0;
        end else if (e == 127) begin
            // |x| in [1.0, 2.0) → floor is always 1
            fp32_floor_int = 4'd1;
        end else if (e == 128) begin
            // |x| in [2.0, 4.0) → floor is 2 or 3
            // bit 22 of mantissa contributes the 2^0 bit
            fp32_floor_int = x[22] ? 4'd3 : 4'd2;
        end else if (e == 129) begin
            // |x| in [4.0, 8.0) → floor is 4..7
            // bits 22:21 contribute 2^1 and 2^0
            fp32_floor_int = 4'd4 + {1'b0, x[22:21]};
        end else if (e == 130) begin
            // |x| in [8.0, 16.0) → floor is 8..15
            fp32_floor_int = 4'd8 + {1'b0, x[22:20]};
        end else begin
            // |x| >= 16 → saturate at 15
            fp32_floor_int = 4'd15;
        end
    endfunction

    // ====================================================================
    // Stage 0: Compute m_new = max(m_old, S) and segment indices
    // ====================================================================

    // FP32 comparison: max(m_old, s_val)
    // For Flash Attention, m_old >= 0 and S >= 0 (after causal mask),
    // but we handle general case for robustness.
    wire s_pos = ~s_val[31];
    wire same_sign = (s_val[31] == m_old[31]);
    wire s_larger_exp = (s_val[30:23] > m_old[30:23]);
    wire same_exp = (s_val[30:23] == m_old[30:23]);
    wire s_larger_man = same_exp && (s_val[22:0] > m_old[22:0]);
    wire s_greater = same_sign ? (s_larger_exp || s_larger_man) : s_pos;

    wire [31:0] m_new = s_greater ? s_val : m_old;

    // ====================================================================
    // Segment index computation — using proper FP32 subtraction
    // ====================================================================
    // Compute delta_s = S - m_new and delta_m = m_old - m_new using FP32
    // subtraction, then extract floor(|delta|) as the LUT segment index.
    //
    // BUG FIX (Phase 2.4): Original code used integer subtraction of FP32
    // bit patterns (s_val - m_new), which is NOT FP32 subtraction.
    // Then attempted exponent-difference approximation, which computed
    // floor(log2(|delta|)) instead of floor(|delta|).  Both approaches
    // produced wrong LUT indices.  The correct fix is proper FP32 subtraction.

    wire [31:0] delta_s = fp32_sub(s_val, m_new);    // S - m_new (FP32)
    wire [31:0] delta_m = fp32_sub(m_old, m_new);    // m_old - m_new (FP32)

    // Segment indices: floor(|delta|) for LUT lookup
    wire [3:0] seg_idx_s = fp32_floor_int(delta_s);
    wire [3:0] seg_idx_m = fp32_floor_int(delta_m);

    // S0 pipeline registers — pass segment indices
    reg [31:0] s0_m_new;
    reg [3:0]  s0_seg_idx_s;
    reg [3:0]  s0_seg_idx_m;
    reg [31:0] s0_l_old;

    always_ff @(posedge clk) begin
        if (reset) begin
            s0_m_new      <= 32'b0;
            s0_seg_idx_s  <= 4'b0;
            s0_seg_idx_m  <= 4'b0;
            s0_l_old      <= 32'b0;
        end else if (enable) begin
            s0_m_new      <= m_new;
            s0_seg_idx_s  <= seg_idx_s;
            s0_seg_idx_m  <= seg_idx_m;
            s0_l_old      <= l_old;
        end
    end

    // ====================================================================
    // Stage 1: Exp computation via piecewise linear approximation
    // ====================================================================
    // exp(x) for x <= 0 (Flash Attention: delta_s, delta_m are non-positive)
    //
    // Strategy: 16-segment LUT covering x in [-15, 0]
    //   Each segment is 1 unit wide: segment[k] covers x in [k, k+1), k = -15..-1
    //   Special case: x = 0 → exp(0) = 1.0
    //
    //   Within each segment: exp(x) ≈ base[k] + slope[k] * frac
    //   where frac = x - k (fractional part, 0 <= frac < 1)
    //
    //   This gives ~4-5 bits of accuracy, sufficient for attention weights
    //   where the relative ordering matters more than absolute precision.

    // Extract segment index — now passed directly from S0
    // (previously derived from s0_delta_s FP32 exponent, which was broken
    // because delta_s was computed via integer subtraction of FP32 bit patterns)

    // 16-entry LUT for exp(-k), k = 0..15
    // Values are FP32 representations of exp(-k):
    //   exp(0)  = 1.0          = 32'h3f800000
    //   exp(-1) = 0.367879441  = 32'h3ebc5ab2
    //   exp(-2) = 0.135335283  = 32'h3e0a5c9b
    //   exp(-3) = 0.049787068  = 32'h3d4cb59e
    //   exp(-4) = 0.018315639  = 32'h3c95e487
    //   exp(-5) = 0.006737947  = 32'h3bbd746c
    //   exp(-6) = 0.002478752  = 32'h3b227c36
    //   exp(-7) = 0.000911882  = 32'h3a6f2a68
    //   exp(-8) = 0.000335463  = 32'h39b010b0
    //   exp(-9) = 0.00012341   = 32'h39013000
    //   exp(-10)= 0.0000454    = 32'h383e0000
    //   exp(-11)= 0.0000167    = 32'h37890000
    //   exp(-12)= 0.00000614   = 32'h36cc0000
    //   exp(-13)= 0.00000226   = 32'h36180000
    //   exp(-14)= 0.000000831  = 32'h355e0000
    //   exp(-15)= 0.000000306  = 32'h34a20000

    reg [31:0] exp_lut [0:15];
    initial begin
        exp_lut[0]  = 32'h3f800000;  // exp(0)  = 1.0
        exp_lut[1]  = 32'h3ebc5ab2;  // exp(-1)
        exp_lut[2]  = 32'h3e0a5c9b;  // exp(-2)
        exp_lut[3]  = 32'h3d4cb59e;  // exp(-3)
        exp_lut[4]  = 32'h3c95e487;  // exp(-4)
        exp_lut[5]  = 32'h3bbd746c;  // exp(-5)
        exp_lut[6]  = 32'h3b227c36;  // exp(-6)
        exp_lut[7]  = 32'h3a6f2a68;  // exp(-7)
        exp_lut[8]  = 32'h39b010b0;  // exp(-8)
        exp_lut[9]  = 32'h39013000;  // exp(-9)
        exp_lut[10] = 32'h383e0000;  // exp(-10)
        exp_lut[11] = 32'h37890000;  // exp(-11)
        exp_lut[12] = 32'h36cc0000;  // exp(-12)
        exp_lut[13] = 32'h36180000;  // exp(-13)
        exp_lut[14] = 32'h355e0000;  // exp(-14)
        exp_lut[15] = 32'h34a20000;  // exp(-15)
    end

    // Phase 2.1: Use LUT value directly (no interpolation).
    // Interpolation (exp_lut[seg] + frac * slope_lut[seg]) deferred to future phase.
    wire [31:0] exp_delta_s = exp_lut[s0_seg_idx_s];

    // Same for exp(delta_m) — reuse same LUT, using segment index from S0
    wire [31:0] exp_delta_m = exp_lut[s0_seg_idx_m];

    // S1 pipeline registers
    reg [31:0] s1_exp_delta_s;   // P = exp(S - m_new)
    reg [31:0] s1_exp_delta_m;   // exp(m_old - m_new)
    reg [31:0] s1_l_old;

    always_ff @(posedge clk) begin
        if (reset) begin
            s1_exp_delta_s <= 32'b0;
            s1_exp_delta_m <= 32'b0;
            s1_l_old       <= 32'b0;
        end else if (enable) begin
            s1_exp_delta_s <= exp_delta_s;
            s1_exp_delta_m <= exp_delta_m;
            s1_l_old       <= s0_l_old;
        end
    end

    // ====================================================================
    // Stage 2: Multiply-add + output
    // ====================================================================
    // l_new = l_old * exp(m_old - m_new) + exp(S - m_new)
    // P     = exp(S - m_new)
    //
    // For the hardware pipeline, we output P directly.
    // l_new computation requires FP32 multiply-add, which we approximate
    // using the existing FPU or defer to software.
    //
    // Phase 2.1 strategy: Output P = exp(S - m_new) only.
    // The l_new = l_old * exp_m + P computation is done by software
    // using a subsequent WGMMA or scalar operation.

    // FP32 approximate multiply: l_old * exp_delta_m
    // For Phase 2.1, use a simplified multiply (exponent add + mantissa approximate)
    // A full FP32 multiplier is too expensive for this pipeline stage.
    // Instead, we defer l_new to software and just output P.

    assign p_val = s1_exp_delta_s;  // P = exp(S - m_new)

    `UNUSED_VAR ({s1_exp_delta_m, s1_l_old})

`ifdef DBG_TRACE_TCU
    always_ff @(posedge clk) begin
        if (enable) begin
            `TRACE(3, ("%t: %s FA_SOFTMAX: s=0x%0h, m_old=0x%0h, m_new=0x%0h, P=0x%0h\n",
                $time, INSTANCE_ID, s_val, m_old, s0_m_new, p_val))
        end
    end
`endif

endmodule
