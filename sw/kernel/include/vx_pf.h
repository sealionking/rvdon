//===----------------------------------------------------------------------===//
//
// DiVo Gen²AI RVDon — Pairformer Extension Intrinsics
//
// vx_pf.h provides C-language intrinsics for PF_TMM, PF_TMM_INC, and
// PF_FLASH_ATTN TCU extension instructions.  These follow the same .insn r
// encoding pattern as Vortex's native WGMMA (RISCV_CUSTOM0, funct7=2) but
// with funct3=3/4/5 respectively.
//
// Encoding layout (EXT1, funct7=2):
//   funct3=0  WMMA         (Vortex native)
//   funct3=1  WGMMA        (Vortex native)
//   funct3=2  TCU_LD       (Vortex native)
//   funct3=3  PF_TMM       (RVDon extension — outgoing triangle mask)
//   funct3=4  PF_TMM_INC   (RVDon extension — incoming triangle mask)
//   funct3=5  PF_FLASH_ATTN(RVDon extension — Flash Attention)
//
// rs2 field encoding (same as WGMMA unless noted):
//   bit  0   : is_sparse (unused for PF, always 0)
//   bits[2:1]: cd_nregs — 0=NRC8, 1=NRC16, 2=NRC32
//              For PF_FLASH_ATTN, cd_nregs[1:0] doubles as fa_sub_op:
//                00 = FA_MMA, 01 = FA_SOFTMAX, 10 = FA_UPDATE
//   bit  3   : a_from_smem
//
// Copyright © 2026 DiVo Gen²AI
//
//===----------------------------------------------------------------------===//

#ifndef VX_PF_H
#define VX_PF_H

#include "vx_tensor.h"

namespace rvdon {
namespace pf {

// Import smem_matrix_desc into this namespace for convenience
using vortex::tensor::smem_matrix_desc;

//---------------------------------------------------------------------------//
// Flag helpers
//---------------------------------------------------------------------------//

// PF_TMM / PF_TMM_INC flags (rs2 encoding)
//   bits[2:1] = cd_nregs_code (0=8, 1=16, 2=32 accumulators)
//   bit 3     = a_from_smem
template <int cd_nregs_code, bool a_from_smem = false>
static constexpr int pf_tmm_flags() {
    return (cd_nregs_code << 1) | ((a_from_smem ? 1 : 0) << 3);
}

// Helper to compute cd_nregs_code from NRC value
static constexpr int pf_cd_nregs_code(int NRC) {
    return (NRC == 8) ? 0 : (NRC == 16) ? 1 : 2;
}

// PF_FLASH_ATTN flags (rs2 encoding)
//   bits[2:1] = fa_sub_op (0=FA_MMA, 1=FA_SOFTMAX, 2=FA_UPDATE)
//   bit 3     = a_from_smem
//
// NOTE: fa_sub_op overloads cd_nregs_code.  FA_MMA (sub_op=0) maps to
// NRC=8 which is correct.  FA_SOFTMAX (sub_op=1) and FA_UPDATE (sub_op=2)
// will cause the uop expander to assume NRC=16/32, which needs to be
// resolved in a future encoding update (Phase 2.1+).
template <int fa_sub_op, bool a_from_smem = false>
static constexpr int pf_fa_flags() {
    return (fa_sub_op << 1) | ((a_from_smem ? 1 : 0) << 3);
}

//---------------------------------------------------------------------------//
// PF_TMM — Outgoing triangle mask matrix multiply
//---------------------------------------------------------------------------//
// Computes: Z[i][j] += sum_k(A[i][k] * B[j][k]) for i < j (outgoing pair)
//           Elements where i >= j are masked to zero via a_row gating.
//
// Register layout (RS path, NRC=8):
//   f0-f7   : C/D accumulator (read+write)
//   f24-f27 : A fragment (read)
//   a1      : B smem descriptor (read)

template <typename Ctx>
__attribute__((always_inline))
static void pf_tmm_sync(typename Ctx::fragment_acc &frag_d,
                         const typename Ctx::fragment_a &op_a,
                         const smem_matrix_desc &op_b,
                         const typename Ctx::fragment_acc &frag_c)
{
    using Ot = typename Ctx::format_ot;
    using It = typename Ctx::format_it;

    constexpr int flags = pf_tmm_flags<pf_cd_nregs_code(Ctx::NRC), false>();

    // NRC=8 path (standard)
    if constexpr (Ctx::NRC == 8) {
        register float fd0 __asm__("f0") = frag_c.data[0];
        register float fd1 __asm__("f1") = frag_c.data[1];
        register float fd2 __asm__("f2") = frag_c.data[2];
        register float fd3 __asm__("f3") = frag_c.data[3];
        register float fd4 __asm__("f4") = frag_c.data[4];
        register float fd5 __asm__("f5") = frag_c.data[5];
        register float fd6 __asm__("f6") = frag_c.data[6];
        register float fd7 __asm__("f7") = frag_c.data[7];

        register float fa0 __asm__("f24") = op_a.data[0];
        register float fa1 __asm__("f25") = op_a.data[1];
        register float fa2 __asm__("f26") = op_a.data[2];
        register float fa3 __asm__("f27") = op_a.data[3];

        register uint32_t rb __asm__("a1") = op_b.value;

        __asm__ volatile (
            ".insn r %[insn], 3, 2, x%[fmd], x%[fms], x%[flags]"
            : "+f"(fd0), "+f"(fd1), "+f"(fd2), "+f"(fd3),
              "+f"(fd4), "+f"(fd5), "+f"(fd6), "+f"(fd7)
            : [insn]"i"(RISCV_CUSTOM0),
              [fmd]"i"(Ot::id),
              [fms]"i"(It::id),
              [flags]"i"(flags),
              "f"(fa0), "f"(fa1), "f"(fa2), "f"(fa3),
              "r"(rb)
        );

        frag_d.data[0] = fd0; frag_d.data[1] = fd1;
        frag_d.data[2] = fd2; frag_d.data[3] = fd3;
        frag_d.data[4] = fd4; frag_d.data[5] = fd5;
        frag_d.data[6] = fd6; frag_d.data[7] = fd7;
    }
    // NRC=16 path
    else if constexpr (Ctx::NRC == 16) {
        register float fd0  __asm__("f0")  = frag_c.data[0];
        register float fd1  __asm__("f1")  = frag_c.data[1];
        register float fd2  __asm__("f2")  = frag_c.data[2];
        register float fd3  __asm__("f3")  = frag_c.data[3];
        register float fd4  __asm__("f4")  = frag_c.data[4];
        register float fd5  __asm__("f5")  = frag_c.data[5];
        register float fd6  __asm__("f6")  = frag_c.data[6];
        register float fd7  __asm__("f7")  = frag_c.data[7];
        register float fd8  __asm__("f8")  = frag_c.data[8];
        register float fd9  __asm__("f9")  = frag_c.data[9];
        register float fd10 __asm__("f10") = frag_c.data[10];
        register float fd11 __asm__("f11") = frag_c.data[11];
        register float fd12 __asm__("f12") = frag_c.data[12];
        register float fd13 __asm__("f13") = frag_c.data[13];
        register float fd14 __asm__("f14") = frag_c.data[14];
        register float fd15 __asm__("f15") = frag_c.data[15];

        register float fa0 __asm__("f24") = op_a.data[0];
        register float fa1 __asm__("f25") = op_a.data[1];
        register float fa2 __asm__("f26") = op_a.data[2];
        register float fa3 __asm__("f27") = op_a.data[3];

        register uint32_t rb __asm__("a1") = op_b.value;

        __asm__ volatile (
            ".insn r %[insn], 3, 2, x%[fmd], x%[fms], x%[flags]"
            : "+f"(fd0), "+f"(fd1), "+f"(fd2), "+f"(fd3),
              "+f"(fd4), "+f"(fd5), "+f"(fd6), "+f"(fd7),
              "+f"(fd8), "+f"(fd9), "+f"(fd10), "+f"(fd11),
              "+f"(fd12), "+f"(fd13), "+f"(fd14), "+f"(fd15)
            : [insn]"i"(RISCV_CUSTOM0),
              [fmd]"i"(Ot::id),
              [fms]"i"(It::id),
              [flags]"i"(flags),
              "f"(fa0), "f"(fa1), "f"(fa2), "f"(fa3),
              "r"(rb)
        );

        frag_d.data[0]  = fd0;  frag_d.data[1]  = fd1;
        frag_d.data[2]  = fd2;  frag_d.data[3]  = fd3;
        frag_d.data[4]  = fd4;  frag_d.data[5]  = fd5;
        frag_d.data[6]  = fd6;  frag_d.data[7]  = fd7;
        frag_d.data[8]  = fd8;  frag_d.data[9]  = fd9;
        frag_d.data[10] = fd10; frag_d.data[11] = fd11;
        frag_d.data[12] = fd12; frag_d.data[13] = fd13;
        frag_d.data[14] = fd14; frag_d.data[15] = fd15;
    }
}

//---------------------------------------------------------------------------//
// PF_TMM_INC — Incoming triangle mask matrix multiply
//---------------------------------------------------------------------------//
// Computes: Z[i][j] += sum_k(A[k][i] * B[k][j]) for k < min(i, j)
//           Elements where k >= min(i,j) are masked to zero.
//
// Same register layout as PF_TMM, funct3=4.

template <typename Ctx>
__attribute__((always_inline))
static void pf_tmm_inc_sync(typename Ctx::fragment_acc &frag_d,
                              const typename Ctx::fragment_a &op_a,
                              const smem_matrix_desc &op_b,
                              const typename Ctx::fragment_acc &frag_c)
{
    using Ot = typename Ctx::format_ot;
    using It = typename Ctx::format_it;

    constexpr int flags = pf_tmm_flags<pf_cd_nregs_code(Ctx::NRC), false>();

    if constexpr (Ctx::NRC == 8) {
        register float fd0 __asm__("f0") = frag_c.data[0];
        register float fd1 __asm__("f1") = frag_c.data[1];
        register float fd2 __asm__("f2") = frag_c.data[2];
        register float fd3 __asm__("f3") = frag_c.data[3];
        register float fd4 __asm__("f4") = frag_c.data[4];
        register float fd5 __asm__("f5") = frag_c.data[5];
        register float fd6 __asm__("f6") = frag_c.data[6];
        register float fd7 __asm__("f7") = frag_c.data[7];

        register float fa0 __asm__("f24") = op_a.data[0];
        register float fa1 __asm__("f25") = op_a.data[1];
        register float fa2 __asm__("f26") = op_a.data[2];
        register float fa3 __asm__("f27") = op_a.data[3];

        register uint32_t rb __asm__("a1") = op_b.value;

        __asm__ volatile (
            ".insn r %[insn], 4, 2, x%[fmd], x%[fms], x%[flags]"
            : "+f"(fd0), "+f"(fd1), "+f"(fd2), "+f"(fd3),
              "+f"(fd4), "+f"(fd5), "+f"(fd6), "+f"(fd7)
            : [insn]"i"(RISCV_CUSTOM0),
              [fmd]"i"(Ot::id),
              [fms]"i"(It::id),
              [flags]"i"(flags),
              "f"(fa0), "f"(fa1), "f"(fa2), "f"(fa3),
              "r"(rb)
        );

        frag_d.data[0] = fd0; frag_d.data[1] = fd1;
        frag_d.data[2] = fd2; frag_d.data[3] = fd3;
        frag_d.data[4] = fd4; frag_d.data[5] = fd5;
        frag_d.data[6] = fd6; frag_d.data[7] = fd7;
    }
    else if constexpr (Ctx::NRC == 16) {
        register float fd0  __asm__("f0")  = frag_c.data[0];
        register float fd1  __asm__("f1")  = frag_c.data[1];
        register float fd2  __asm__("f2")  = frag_c.data[2];
        register float fd3  __asm__("f3")  = frag_c.data[3];
        register float fd4  __asm__("f4")  = frag_c.data[4];
        register float fd5  __asm__("f5")  = frag_c.data[5];
        register float fd6  __asm__("f6")  = frag_c.data[6];
        register float fd7  __asm__("f7")  = frag_c.data[7];
        register float fd8  __asm__("f8")  = frag_c.data[8];
        register float fd9  __asm__("f9")  = frag_c.data[9];
        register float fd10 __asm__("f10") = frag_c.data[10];
        register float fd11 __asm__("f11") = frag_c.data[11];
        register float fd12 __asm__("f12") = frag_c.data[12];
        register float fd13 __asm__("f13") = frag_c.data[13];
        register float fd14 __asm__("f14") = frag_c.data[14];
        register float fd15 __asm__("f15") = frag_c.data[15];

        register float fa0 __asm__("f24") = op_a.data[0];
        register float fa1 __asm__("f25") = op_a.data[1];
        register float fa2 __asm__("f26") = op_a.data[2];
        register float fa3 __asm__("f27") = op_a.data[3];

        register uint32_t rb __asm__("a1") = op_b.value;

        __asm__ volatile (
            ".insn r %[insn], 4, 2, x%[fmd], x%[fms], x%[flags]"
            : "+f"(fd0), "+f"(fd1), "+f"(fd2), "+f"(fd3),
              "+f"(fd4), "+f"(fd5), "+f"(fd6), "+f"(fd7),
              "+f"(fd8), "+f"(fd9), "+f"(fd10), "+f"(fd11),
              "+f"(fd12), "+f"(fd13), "+f"(fd14), "+f"(fd15)
            : [insn]"i"(RISCV_CUSTOM0),
              [fmd]"i"(Ot::id),
              [fms]"i"(It::id),
              [flags]"i"(flags),
              "f"(fa0), "f"(fa1), "f"(fa2), "f"(fa3),
              "r"(rb)
        );

        frag_d.data[0]  = fd0;  frag_d.data[1]  = fd1;
        frag_d.data[2]  = fd2;  frag_d.data[3]  = fd3;
        frag_d.data[4]  = fd4;  frag_d.data[5]  = fd5;
        frag_d.data[6]  = fd6;  frag_d.data[7]  = fd7;
        frag_d.data[8]  = fd8;  frag_d.data[9]  = fd9;
        frag_d.data[10] = fd10; frag_d.data[11] = fd11;
        frag_d.data[12] = fd12; frag_d.data[13] = fd13;
        frag_d.data[14] = fd14; frag_d.data[15] = fd15;
    }
}

//---------------------------------------------------------------------------//
// PF_FLASH_ATTN — Flash Attention sub-operations
//---------------------------------------------------------------------------//
// Three-instruction decomposition:
//   FA_MMA    (fa_sub_op=0): QK^T + causal mask (j <= i)
//   FA_SOFTMAX(fa_sub_op=1): Online softmax update (Phase 2.1+)
//   FA_UPDATE (fa_sub_op=2): P @ V computation    (Phase 2.1+)
//
// NOTE: fa_sub_op overloads cd_nregs[1:0] in the rs2 field.
//   FA_MMA (sub_op=0) → cd_nregs_code=0 → NRC=8 → correct.
//   FA_SOFTMAX/FA_UPDATE have encoding conflicts with cd_nregs
//   that will need resolution in Phase 2.1+.

// FA_MMA: Compute S = QK^T with causal mask (j <= i preserved, j > i → -inf)
// Register layout (RS path, NRC=8):
//   f0-f7   : C/D accumulator (read+write) — holds S tile
//   f24-f27 : A fragment (read) — Q matrix rows
//   a1      : B smem descriptor — K matrix columns
template <typename Ctx>
__attribute__((always_inline))
static void fa_mma_sync(typename Ctx::fragment_acc &frag_d,
                         const typename Ctx::fragment_a &op_a,
                         const smem_matrix_desc &op_b,
                         const typename Ctx::fragment_acc &frag_c)
{
    using Ot = typename Ctx::format_ot;
    using It = typename Ctx::format_it;

    // FA_MMA: fa_sub_op=0, a_from_smem=false
    constexpr int flags = pf_fa_flags<0, false>();

    // NRC=8 path (fa_sub_op=0 → cd_nregs_code=0 → NRC=8)
    if constexpr (Ctx::NRC == 8) {
        register float fd0 __asm__("f0") = frag_c.data[0];
        register float fd1 __asm__("f1") = frag_c.data[1];
        register float fd2 __asm__("f2") = frag_c.data[2];
        register float fd3 __asm__("f3") = frag_c.data[3];
        register float fd4 __asm__("f4") = frag_c.data[4];
        register float fd5 __asm__("f5") = frag_c.data[5];
        register float fd6 __asm__("f6") = frag_c.data[6];
        register float fd7 __asm__("f7") = frag_c.data[7];

        register float fa0 __asm__("f24") = op_a.data[0];
        register float fa1 __asm__("f25") = op_a.data[1];
        register float fa2 __asm__("f26") = op_a.data[2];
        register float fa3 __asm__("f27") = op_a.data[3];

        register uint32_t rb __asm__("a1") = op_b.value;

        __asm__ volatile (
            ".insn r %[insn], 5, 2, x%[fmd], x%[fms], x%[flags]"
            : "+f"(fd0), "+f"(fd1), "+f"(fd2), "+f"(fd3),
              "+f"(fd4), "+f"(fd5), "+f"(fd6), "+f"(fd7)
            : [insn]"i"(RISCV_CUSTOM0),
              [fmd]"i"(Ot::id),
              [fms]"i"(It::id),
              [flags]"i"(flags),
              "f"(fa0), "f"(fa1), "f"(fa2), "f"(fa3),
              "r"(rb)
        );

        frag_d.data[0] = fd0; frag_d.data[1] = fd1;
        frag_d.data[2] = fd2; frag_d.data[3] = fd3;
        frag_d.data[4] = fd4; frag_d.data[5] = fd5;
        frag_d.data[6] = fd6; frag_d.data[7] = fd7;
    }
}

//---------------------------------------------------------------------------//
// PF_TMM — SS path (A and B from smem)
//---------------------------------------------------------------------------//
// Same triangle mask semantics, but both A and B come from shared memory.
// Register layout (SS path, NRC=8):
//   f0-f7   : C/D accumulator (read+write)
//   a0      : A smem descriptor
//   a1      : B smem descriptor

template <typename Ctx>
__attribute__((always_inline))
static void pf_tmm_ss_sync(typename Ctx::fragment_acc &frag_d,
                             const smem_matrix_desc &op_a,
                             const smem_matrix_desc &op_b,
                             const typename Ctx::fragment_acc &frag_c)
{
    using Ot = typename Ctx::format_ot;
    using It = typename Ctx::format_it;

    constexpr int flags = pf_tmm_flags<pf_cd_nregs_code(Ctx::NRC), true>();

    if constexpr (Ctx::NRC == 8) {
        register float fd0 __asm__("f0") = frag_c.data[0];
        register float fd1 __asm__("f1") = frag_c.data[1];
        register float fd2 __asm__("f2") = frag_c.data[2];
        register float fd3 __asm__("f3") = frag_c.data[3];
        register float fd4 __asm__("f4") = frag_c.data[4];
        register float fd5 __asm__("f5") = frag_c.data[5];
        register float fd6 __asm__("f6") = frag_c.data[6];
        register float fd7 __asm__("f7") = frag_c.data[7];

        register uint32_t ra __asm__("a0") = op_a.value;
        register uint32_t rb __asm__("a1") = op_b.value;

        __asm__ volatile (
            ".insn r %[insn], 3, 2, x%[fmd], x%[fms], x%[flags]"
            : "+f"(fd0), "+f"(fd1), "+f"(fd2), "+f"(fd3),
              "+f"(fd4), "+f"(fd5), "+f"(fd6), "+f"(fd7)
            : [insn]"i"(RISCV_CUSTOM0),
              [fmd]"i"(Ot::id),
              [fms]"i"(It::id),
              [flags]"i"(flags),
              "r"(ra), "r"(rb)
        );

        frag_d.data[0] = fd0; frag_d.data[1] = fd1;
        frag_d.data[2] = fd2; frag_d.data[3] = fd3;
        frag_d.data[4] = fd4; frag_d.data[5] = fd5;
        frag_d.data[6] = fd6; frag_d.data[7] = fd7;
    }
}

//---------------------------------------------------------------------------//
// PF_TMM_INC — SS path (A and B from smem)
//---------------------------------------------------------------------------//

template <typename Ctx>
__attribute__((always_inline))
static void pf_tmm_inc_ss_sync(typename Ctx::fragment_acc &frag_d,
                                 const smem_matrix_desc &op_a,
                                 const smem_matrix_desc &op_b,
                                 const typename Ctx::fragment_acc &frag_c)
{
    using Ot = typename Ctx::format_ot;
    using It = typename Ctx::format_it;

    constexpr int flags = pf_tmm_flags<pf_cd_nregs_code(Ctx::NRC), true>();

    if constexpr (Ctx::NRC == 8) {
        register float fd0 __asm__("f0") = frag_c.data[0];
        register float fd1 __asm__("f1") = frag_c.data[1];
        register float fd2 __asm__("f2") = frag_c.data[2];
        register float fd3 __asm__("f3") = frag_c.data[3];
        register float fd4 __asm__("f4") = frag_c.data[4];
        register float fd5 __asm__("f5") = frag_c.data[5];
        register float fd6 __asm__("f6") = frag_c.data[6];
        register float fd7 __asm__("f7") = frag_c.data[7];

        register uint32_t ra __asm__("a0") = op_a.value;
        register uint32_t rb __asm__("a1") = op_b.value;

        __asm__ volatile (
            ".insn r %[insn], 4, 2, x%[fmd], x%[fms], x%[flags]"
            : "+f"(fd0), "+f"(fd1), "+f"(fd2), "+f"(fd3),
              "+f"(fd4), "+f"(fd5), "+f"(fd6), "+f"(fd7)
            : [insn]"i"(RISCV_CUSTOM0),
              [fmd]"i"(Ot::id),
              [fms]"i"(It::id),
              [flags]"i"(flags),
              "r"(ra), "r"(rb)
        );

        frag_d.data[0] = fd0; frag_d.data[1] = fd1;
        frag_d.data[2] = fd2; frag_d.data[3] = fd3;
        frag_d.data[4] = fd4; frag_d.data[5] = fd5;
        frag_d.data[6] = fd6; frag_d.data[7] = fd7;
    }
}

//---------------------------------------------------------------------------//
// FA_MMA — SS path (A and B from smem)
//---------------------------------------------------------------------------//

template <typename Ctx>
__attribute__((always_inline))
static void fa_mma_ss_sync(typename Ctx::fragment_acc &frag_d,
                             const smem_matrix_desc &op_a,
                             const smem_matrix_desc &op_b,
                             const typename Ctx::fragment_acc &frag_c)
{
    using Ot = typename Ctx::format_ot;
    using It = typename Ctx::format_it;

    constexpr int flags = pf_fa_flags<0, true>();

    if constexpr (Ctx::NRC == 8) {
        register float fd0 __asm__("f0") = frag_c.data[0];
        register float fd1 __asm__("f1") = frag_c.data[1];
        register float fd2 __asm__("f2") = frag_c.data[2];
        register float fd3 __asm__("f3") = frag_c.data[3];
        register float fd4 __asm__("f4") = frag_c.data[4];
        register float fd5 __asm__("f5") = frag_c.data[5];
        register float fd6 __asm__("f6") = frag_c.data[6];
        register float fd7 __asm__("f7") = frag_c.data[7];

        register uint32_t ra __asm__("a0") = op_a.value;
        register uint32_t rb __asm__("a1") = op_b.value;

        __asm__ volatile (
            ".insn r %[insn], 5, 2, x%[fmd], x%[fms], x%[flags]"
            : "+f"(fd0), "+f"(fd1), "+f"(fd2), "+f"(fd3),
              "+f"(fd4), "+f"(fd5), "+f"(fd6), "+f"(fd7)
            : [insn]"i"(RISCV_CUSTOM0),
              [fmd]"i"(Ot::id),
              [fms]"i"(It::id),
              [flags]"i"(flags),
              "r"(ra), "r"(rb)
        );

        frag_d.data[0] = fd0; frag_d.data[1] = fd1;
        frag_d.data[2] = fd2; frag_d.data[3] = fd3;
        frag_d.data[4] = fd4; frag_d.data[5] = fd5;
        frag_d.data[6] = fd6; frag_d.data[7] = fd7;
    }
}

} // namespace pf
} // namespace rvdon

//---------------------------------------------------------------------------//
// FA_SOFTMAX — Online softmax update (RS path, NRC=8)
//---------------------------------------------------------------------------//
// Computes: P[i][j] = exp(S[i] - m_new[i])
//   where m_new[i] = max(m_old[i][j], S[i])
//
// Register layout (RS path, NRC=8, TCU_TC_M=2, TCU_TC_N=4):
//   f0-f7   : C/D accumulator = m_old (input) / P (output)
//             f0..f3 = i=0 row, j=0..3
//             f4..f7 = i=1 row, j=0..3
//   f24-f27 : A fragment = S values (input)
//             f24 = S[0] (row 0 attention score)
//             f25 = S[1] (row 1 attention score)
//             f26,f27 unused but must be valid
//   a1      : B smem descriptor (unused but encoded in flags)

namespace rvdon {
namespace pf {

template <typename Ctx>
__attribute__((always_inline))
static void fa_softmax_sync(typename Ctx::fragment_acc &frag_d,
                              const typename Ctx::fragment_a &op_s,
                              const typename Ctx::fragment_acc &frag_m_old)
{
    using Ot = typename Ctx::format_ot;
    using It = typename Ctx::format_it;

    // FA_SOFTMAX: fa_sub_op=1, a_from_smem=false
    constexpr int flags = pf_fa_flags<1, false>();

    if constexpr (Ctx::NRC == 8) {
        register float fd0 __asm__("f0") = frag_m_old.data[0];
        register float fd1 __asm__("f1") = frag_m_old.data[1];
        register float fd2 __asm__("f2") = frag_m_old.data[2];
        register float fd3 __asm__("f3") = frag_m_old.data[3];
        register float fd4 __asm__("f4") = frag_m_old.data[4];
        register float fd5 __asm__("f5") = frag_m_old.data[5];
        register float fd6 __asm__("f6") = frag_m_old.data[6];
        register float fd7 __asm__("f7") = frag_m_old.data[7];

        register float fa0 __asm__("f24") = op_s.data[0];
        register float fa1 __asm__("f25") = op_s.data[1];
        register float fa2 __asm__("f26") = op_s.data[2];
        register float fa3 __asm__("f27") = op_s.data[3];

        register uint32_t rb __asm__("a1") = 0;

        __asm__ volatile (
            ".insn r %[insn], 5, 2, x%[fmd], x%[fms], x%[flags]"
            : "+f"(fd0), "+f"(fd1), "+f"(fd2), "+f"(fd3),
              "+f"(fd4), "+f"(fd5), "+f"(fd6), "+f"(fd7)
            : [insn]"i"(RISCV_CUSTOM0),
              [fmd]"i"(Ot::id),
              [fms]"i"(It::id),
              [flags]"i"(flags),
              "f"(fa0), "f"(fa1), "f"(fa2), "f"(fa3),
              "r"(rb)
        );

        frag_d.data[0] = fd0; frag_d.data[1] = fd1;
        frag_d.data[2] = fd2; frag_d.data[3] = fd3;
        frag_d.data[4] = fd4; frag_d.data[5] = fd5;
        frag_d.data[6] = fd6; frag_d.data[7] = fd7;
    }
}

} // namespace pf
} // namespace rvdon

#endif // VX_PF_H
