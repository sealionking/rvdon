//===----------------------------------------------------------------------===//
//
// DiVo Gen²AI RVDon — PF_TMM Kernel Test
//
// Uses fp16→fp32 (same as sgemm_tcu_wg) because TFR FEDP does not support
// fp32→fp32 natively.  PF masking is format-agnostic — it gates a_row in
// VX_tcu_core.sv before the FEDP, so testing with fp16 is sufficient.
//
//===----------------------------------------------------------------------===//

#include "common.h"
#include <vx_spawn2.h>
#include <vx_tensor.h>
#include <vx_pf.h>
#include <string.h>

namespace vt = vortex::tensor;

// Match sgemm_tcu_wg format: fp16 input, fp32 output
using It = vt::fp16;
using Ot = vt::fp32;
using Ctx = vt::wgmma_context<VX_CFG_NUM_THREADS, It, Ot, false, 8>;

__kernel void kernel_main(kernel_arg_t* __UNIFORM__ arg) {
    auto pA = reinterpret_cast<uint16_t*>(arg->A_addr);
    auto pB = reinterpret_cast<uint16_t*>(arg->B_addr);
    auto pC = reinterpret_cast<float*>(arg->C_addr);

    uint32_t M = arg->M;
    uint32_t N = arg->N;
    uint32_t K = arg->K;

    uint32_t tid = threadIdx.x;  // CTA-local thread ID (not vx_thread_id which is core-local)
    uint32_t num_threads = blockDim.x;
    uint32_t warp_rank = tid / VX_CFG_NUM_THREADS;
    uint32_t num_warps = num_threads / VX_CFG_NUM_THREADS;

    uint32_t cta_M = num_warps * Ctx::xtileM;
    uint32_t tile_row = blockIdx.y * cta_M;
    uint32_t tile_col = blockIdx.x * Ctx::xtileN;

    auto smem   = reinterpret_cast<uint16_t*>(__local_mem());
    auto A_smem = smem;
    auto B_smem = smem + cta_M * Ctx::tileK;

    // ---- Test 1: Plain WGMMA (no mask) — baseline ----
    {
        Ctx::fragment_acc fragC;
        Ctx::fill_fragment(fragC, 0.0f);

        for (uint32_t k = 0; k < K; k += Ctx::tileK) {
            uint32_t a_size = cta_M * Ctx::tileK;
            for (uint32_t i = 0; i < a_size; i += num_threads) {
                uint32_t idx = i + tid;
                if (idx < a_size) {
                    uint32_t r = idx / Ctx::tileK;
                    uint32_t c = idx % Ctx::tileK;
                    A_smem[Ctx::a_blockmajor_idx(r, c)] = pA[(tile_row + r) * K + (k + c)];
                }
            }

            uint32_t b_size = Ctx::tileK * Ctx::xtileN;
            for (uint32_t i = 0; i < b_size; i += num_threads) {
                uint32_t idx = i + tid;
                if (idx < b_size) {
                    uint32_t r = idx / Ctx::xtileN;
                    uint32_t c = idx % Ctx::xtileN;
                    B_smem[Ctx::b_blockmajor_idx(r, c)] = pB[(k + r) * N + (tile_col + c)];
                }
            }

            __syncthreads();

            auto A_warp = A_smem + warp_rank * Ctx::a_warp_elems;
            auto descB = vt::vx_make_smem_desc(B_smem, 0);

            // RS path: A from registers, B from smem
            Ctx::fragment_a fragA;
            Ctx::load_matrix_sync(fragA, A_warp, 0);
            Ctx::wgmma_sync(fragC, fragA, descB, fragC);

            __syncthreads();
        }

        auto out = pC + (tile_row + warp_rank * Ctx::xtileM) * N + tile_col;
        Ctx::store_matrix_sync(out, fragC, N);
    }

    // ---- Test 2: PF_TMM (outgoing triangle mask) ----
    {
        float* pS = pC + M * N;
        Ctx::fragment_acc fragS;
        Ctx::fill_fragment(fragS, 0.0f);

        for (uint32_t k = 0; k < K; k += Ctx::tileK) {
            uint32_t a_size = cta_M * Ctx::tileK;
            for (uint32_t i = 0; i < a_size; i += num_threads) {
                uint32_t idx = i + tid;
                if (idx < a_size) {
                    uint32_t r = idx / Ctx::tileK;
                    uint32_t c = idx % Ctx::tileK;
                    A_smem[Ctx::a_blockmajor_idx(r, c)] = pA[(tile_row + r) * K + (k + c)];
                }
            }

            uint32_t b_size = Ctx::tileK * Ctx::xtileN;
            for (uint32_t i = 0; i < b_size; i += num_threads) {
                uint32_t idx = i + tid;
                if (idx < b_size) {
                    uint32_t r = idx / Ctx::xtileN;
                    uint32_t c = idx % Ctx::xtileN;
                    B_smem[Ctx::b_blockmajor_idx(r, c)] = pB[(k + r) * N + (tile_col + c)];
                }
            }

            __syncthreads();

            auto A_warp = A_smem + warp_rank * Ctx::a_warp_elems;
            auto descB = vt::vx_make_smem_desc(B_smem, 0);

            Ctx::fragment_a fragA;
            Ctx::load_matrix_sync(fragA, A_warp, 0);
            rvdon::pf::pf_tmm_sync<Ctx>(fragS, fragA, descB, fragS);

            __syncthreads();
        }

        auto out = pS + (tile_row + warp_rank * Ctx::xtileM) * N + tile_col;
        Ctx::store_matrix_sync(out, fragS, N);
    }

    // ---- Test 3: FA_SOFTMAX (online softmax P = exp(S - m_new)) ----
    // Tests the VX_tcu_fa hardware pipeline.
    // Uses integer deltas for exact LUT matches:
    //   S[0] = 2.0, m_old = 0.0 → m_new = 2.0, P = exp(0) = 1.0
    //   S[1] = 0.0, m_old = 1.0 → m_new = 1.0, P = exp(-1) ≈ 0.368
    //
    // Per-thread data distribution:
    //   Thread t corresponds to TCU grid position (i=t/TCU_TC_N, j=t%TCU_TC_N)
    //   RTL reads S from rs1_data[i * TCU_TC_K], so thread 0 and thread 4
    //   (TCU_TC_N=4) must hold different S values for their respective rows.
    {
        float* pP = pC + M * N * 2;

        // Determine TCU row index for this thread
        // Thread t → TCU grid (i = t / TCU_TC_N, j = t % TCU_TC_N)
        // NT=4: TC_N=2, NT=8: TC_N=4
        // fa_i = tid / TC_N = tid / (NT / TC_M)
        // TC_M = 1 << (log2(NT)/2) = 2 for both NT=4 and NT=8
        constexpr uint32_t TCU_TC_M_VAL = 2;
        constexpr uint32_t TCU_TC_N_VAL = VX_CFG_NUM_THREADS / TCU_TC_M_VAL;
        uint32_t fa_i = tid % VX_CFG_NUM_THREADS / TCU_TC_N_VAL;

        // Set m_old values per TCU row
        // Row i=0: m_old = 0.0, Row i=1: m_old = 1.0
        Ctx::fragment_acc fragM;
        float m_val = (fa_i == 0) ? 0.0f : 1.0f;
        for (int k = 0; k < 8; ++k) fragM.data[k] = m_val;

        // Set S values per TCU row
        // Row i=0: S = 2.0, Row i=1: S = 0.0
        Ctx::fragment_a fragS;
        float s_val = (fa_i == 0) ? 2.0f : 0.0f;
        for (int k = 0; k < 4; ++k) fragS.data[k] = s_val;

        rvdon::pf::fa_softmax_sync<Ctx>(fragM, fragS, fragM);

        auto out = pP + (tile_row + warp_rank * Ctx::xtileM) * N + tile_col;
        Ctx::store_matrix_sync(out, fragM, N);
    }
}
