//===----------------------------------------------------------------------===//
//
// DiVo Gen²AI RVDon — PF_TMM Test (Host-side)
//
// Uses fp16→fp32 (same as sgemm_tcu_wg).  Host data is float, converted to
// fp16 for upload.  Output is fp32.
//
//===----------------------------------------------------------------------===//

#include "common.h"
#include <vortex2.h>
#include <rvfloats.h>
#include <tensor_cfg.h>
#include <util.h>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#define FLOAT_ULP 10
#define MAX_ERRORS 100

#define RT_CHECK(_expr)                                      \
  do {                                                       \
    vx_result_t _ret = _expr;                                \
    if (_ret == VX_SUCCESS)                                  \
      break;                                                 \
    printf("Error: '%s' returned %d!\n", #_expr, (int)_ret); \
    cleanup();                                               \
    exit(-1);                                                \
  } while (false)

///////////////////////////////////////////////////////////////////////////////

using namespace vortex;
namespace vt = tensor;

using wg_cfg = vt::wgmma_config_t<VX_CFG_NUM_THREADS, vt::fp16, vt::fp32, 8>;

static void compute_gemm_ref(const float* A, const float* B, float* C,
                              uint32_t M, uint32_t N, uint32_t K) {
    memset(C, 0, M * N * sizeof(float));
    for (uint32_t i = 0; i < M; ++i)
        for (uint32_t j = 0; j < N; ++j) {
            float sum = 0.0f;
            for (uint32_t k = 0; k < K; ++k)
                sum += A[i * K + k] * B[k * N + j];
            C[i * N + j] = sum;
        }
}

static void compute_pf_tmm_ref(const float* A, const float* B, float* C,
                                uint32_t M, uint32_t N, uint32_t K,
                                uint32_t /*cta_M*/, uint32_t xtileM, uint32_t xtileN) {
    // Phase 2.2: RTL PF_TMM mask uses warp-local coordinates:
    //   pf_global_i = step_m * TCU_TC_M + i   (range 0..xtileM-1)
    //   pf_global_j = step_n * TCU_TC_N + j   (range 0..xtileN-1)
    // Since pf_row_base=0 and pf_col_base=0 (block_idx not in pipeline),
    // the mask is per-warp, not global.
    //
    // Each warp independently applies the triangle mask within its own
    // xtileM × xtileN tile, regardless of which CTA it belongs to.
    // Outgoing mask: keep upper triangle (local_i < local_j)
    memset(C, 0, M * N * sizeof(float));
    for (uint32_t row = 0; row < M; ++row) {
        for (uint32_t col = 0; col < N; ++col) {
            // Compute warp-local coordinates
            uint32_t local_i = row % xtileM;
            uint32_t local_j = col % xtileN;
            // Outgoing: keep upper triangle (local_i < local_j)
            if (local_i >= local_j) continue;
            float sum = 0.0f;
            for (uint32_t k = 0; k < K; ++k)
                sum += A[row * K + k] * B[k * N + col];
            C[row * N + col] = sum;
        }
    }
}

///////////////////////////////////////////////////////////////////////////////

const char *kernel_file = "kernel.vxbin";

vx_device_h device = nullptr;
vx_buffer_h A_buffer = nullptr;
vx_buffer_h B_buffer = nullptr;
vx_buffer_h C_buffer = nullptr;
vx_queue_h  queue = nullptr;
vx_module_h module_ = nullptr;
vx_kernel_h kernel = nullptr;
kernel_arg_t kernel_arg = {};

void cleanup() {
    if (device) {
        if (A_buffer) vx_buffer_release(A_buffer);
        if (B_buffer) vx_buffer_release(B_buffer);
        if (C_buffer) vx_buffer_release(C_buffer);
        if (kernel)   vx_kernel_release(kernel);
        if (module_)  vx_module_release(module_);
        if (queue)    vx_queue_release(queue);
        vx_device_release(device);
    }
}

int main(int argc, char* argv[]) {
    int dev_id __attribute__((unused)) = 0;
    if (argc > 1) dev_id = atoi(argv[1]);

    uint32_t M = 16;
    uint32_t K = 16;

    // Open device
    RT_CHECK(vx_device_open(dev_id, &device));

    vx_queue_info_t qi = { sizeof(qi), nullptr, VX_QUEUE_PRIORITY_NORMAL, 0 };
    RT_CHECK(vx_queue_create(device, &qi, &queue));

    uint64_t NT;
    RT_CHECK(vx_device_query(device, VX_CAPS_NUM_THREADS, &NT));
    if (NT != VX_CFG_NUM_THREADS) {
        printf("Error: NT=%lu != VX_CFG_NUM_THREADS=%d\n", (unsigned long)NT, VX_CFG_NUM_THREADS);
        cleanup();
        return -1;
    }

    uint64_t num_warps;
    RT_CHECK(vx_device_query(device, VX_CAPS_NUM_WARPS, &num_warps));

    uint64_t issue_width;
    RT_CHECK(vx_device_query(device, VX_CAPS_ISSUE_WIDTH, &issue_width));
    uint32_t warps = (uint32_t)issue_width;
    if (warps > num_warps) {
        printf("Error: warps=%d > num_warps=%lu\n", warps, (unsigned long)num_warps);
        cleanup();
        return -1;
    }

    uint32_t cta_M = warps * wg_cfg::xtileM;
    uint32_t per_warp_N = wg_cfg::xtileN;

    // Use N=per_warp_N so that only 1 CTA covers the column dimension.
    // This avoids the col_base limitation (blockIdx not in pipeline).
    // M=16 with 4 warps → tests the row_base (warp_rank) upgrade.
    uint32_t N = per_warp_N;  // = xtileN = 8 for NRC=8

    printf("PF_TMM Test: M=%d, N=%d, K=%d (fp16→fp32)\n", M, N, K);

    // Check alignment
    if ((M % cta_M) != 0 || (N % per_warp_N) != 0 || (K % wg_cfg::tileK) != 0) {
        printf("Error: M=%d not multiple of cta_M=%d, or N=%d not multiple of per_warp_N=%d, or K=%d not multiple of tileK=%d\n",
               M, cta_M, N, per_warp_N, K, wg_cfg::tileK);
        cleanup();
        return -1;
    }

    // Allocate buffers
    size_t A_size = M * K * sizeof(uint16_t);  // fp16
    size_t B_size = K * N * sizeof(uint16_t);  // fp16
    size_t C_size = M * N * sizeof(float) * 3; // fp32, C + S + P combined

    RT_CHECK(vx_buffer_create(device, A_size, VX_MEM_READ, &A_buffer));
    RT_CHECK(vx_buffer_address(A_buffer, &kernel_arg.A_addr));

    RT_CHECK(vx_buffer_create(device, B_size, VX_MEM_READ, &B_buffer));
    RT_CHECK(vx_buffer_address(B_buffer, &kernel_arg.B_addr));

    RT_CHECK(vx_buffer_create(device, C_size, VX_MEM_WRITE, &C_buffer));
    RT_CHECK(vx_buffer_address(C_buffer, &kernel_arg.C_addr));

    kernel_arg.M = M;
    kernel_arg.N = N;
    kernel_arg.K = K;

    // Initialize host data (float, then convert to fp16)
    std::vector<float> h_A_f(M * K);
    std::vector<float> h_B_f(K * N);
    for (uint32_t i = 0; i < M * K; ++i) h_A_f[i] = (float)(i % 7 + 1) * 0.1f;
    for (uint32_t i = 0; i < K * N; ++i) h_B_f[i] = (float)(i % 5 + 1) * 0.2f;

    // Convert to fp16 using softfloat (same API as sgemm_tcu_wg)
    std::vector<uint16_t> h_A_fp16(M * K);
    std::vector<uint16_t> h_B_fp16(K * N);
    for (uint32_t i = 0; i < M * K; ++i)
        h_A_fp16[i] = rv_ftoh_s(bit_cast<uint32_t>(h_A_f[i]), 0, nullptr);
    for (uint32_t i = 0; i < K * N; ++i)
        h_B_fp16[i] = rv_ftoh_s(bit_cast<uint32_t>(h_B_f[i]), 0, nullptr);

    // Reference results (fp32 arithmetic)
    std::vector<float> h_C_ref(M * N);
    std::vector<float> h_S_ref(M * N);
    compute_gemm_ref(h_A_f.data(), h_B_f.data(), h_C_ref.data(), M, N, K);
    compute_pf_tmm_ref(h_A_f.data(), h_B_f.data(), h_S_ref.data(), M, N, K,
                        cta_M, wg_cfg::xtileM, wg_cfg::xtileN);

    // Account for fp16 rounding in reference
    for (uint32_t i = 0; i < M * N; ++i) {
        h_C_ref[i] = 0;
        h_S_ref[i] = 0;
    }
    // WGMMA reference: full matmul with fp16 inputs
    for (uint32_t row = 0; row < M; ++row) {
        for (uint32_t col = 0; col < N; ++col) {
            float ref_gemm = 0;
            for (uint32_t k = 0; k < K; ++k) {
                float a_ik = bit_cast<float>(rv_htof_s(h_A_fp16[row * K + k], 0, nullptr));
                float b_kj = bit_cast<float>(rv_htof_s(h_B_fp16[k * N + col], 0, nullptr));
                ref_gemm += a_ik * b_kj;
            }
            h_C_ref[row * N + col] = ref_gemm;
        }
    }
    // PF_TMM reference: warp-local triangle mask with fp16 inputs
    for (uint32_t row = 0; row < M; ++row) {
        for (uint32_t col = 0; col < N; ++col) {
            uint32_t local_i = row % wg_cfg::xtileM;
            uint32_t local_j = col % wg_cfg::xtileN;
            if (local_i >= local_j) continue;
            float ref_tmm = 0;
            for (uint32_t k = 0; k < K; ++k) {
                float a_ik = bit_cast<float>(rv_htof_s(h_A_fp16[row * K + k], 0, nullptr));
                float b_kj = bit_cast<float>(rv_htof_s(h_B_fp16[k * N + col], 0, nullptr));
                ref_tmm += a_ik * b_kj;
            }
            h_S_ref[row * N + col] = ref_tmm;
        }
    }

    // Upload fp16 data
    RT_CHECK(vx_enqueue_write(queue, A_buffer, 0, h_A_fp16.data(), A_size, 0, nullptr, nullptr));
    RT_CHECK(vx_enqueue_write(queue, B_buffer, 0, h_B_fp16.data(), B_size, 0, nullptr, nullptr));

    // Load kernel
    RT_CHECK(vx_module_load_file(device, kernel_file, &module_));
    RT_CHECK(vx_module_get_kernel(module_, "main", &kernel));

    // Launch
    uint32_t grid_dim[2]  = {N / per_warp_N, M / cta_M};
    uint32_t block_dim[2] = {warps * (uint32_t)NT, 1};
    printf("Grid: %dx%d, Block: %dx%d\n", grid_dim[0], grid_dim[1], block_dim[0], block_dim[1]);

    vx_launch_info_t li = {};
    li.struct_size  = sizeof(li);
    li.kernel       = kernel;
    li.args_host    = &kernel_arg;
    li.args_size    = sizeof(kernel_arg);
    li.ndim         = 2;
    li.grid_dim[0]  = grid_dim[0];
    li.grid_dim[1]  = grid_dim[1];
    li.block_dim[0] = block_dim[0];
    li.block_dim[1] = block_dim[1];
    li.lmem_size    = (cta_M * wg_cfg::tileK + wg_cfg::tileK * per_warp_N) * sizeof(uint16_t);
    vx_event_h launch_ev = nullptr;
    RT_CHECK(vx_enqueue_launch(queue, &li, 0, nullptr, &launch_ev));

    // Read results
    std::vector<float> h_C(M * N * 3);
    vx_event_h read_ev = nullptr;
    RT_CHECK(vx_enqueue_read(queue, h_C.data(), C_buffer, 0, C_size, 1, &launch_ev, &read_ev));
    RT_CHECK(vx_event_wait_value(read_ev, 1, VX_TIMEOUT_INFINITE));
    vx_event_release(read_ev);
    vx_event_release(launch_ev);

    // PF_TMM output starts at offset M*N
    float* p_S = h_C.data() + M * N;
    // FA_SOFTMAX output starts at offset 2*M*N
    float* p_P = h_C.data() + M * N * 2;

    // Verify WGMMA
    int wgmma_errors = 0;
    for (uint32_t i = 0; i < M * N; ++i) {
        float diff = fabsf(h_C[i] - h_C_ref[i]);
        float tol = fmaxf(fabsf(h_C_ref[i]) * 0.01f, 1e-2f);
        if (diff > tol) {
            if (wgmma_errors < MAX_ERRORS)
                printf("WGMMA [%d]: got=%f, ref=%f, diff=%f\n", i, h_C[i], h_C_ref[i], diff);
            ++wgmma_errors;
        }
    }

    // Verify PF_TMM
    int tmm_errors = 0;
    for (uint32_t i = 0; i < M * N; ++i) {
        float diff = fabsf(p_S[i] - h_S_ref[i]);
        float tol = fmaxf(fabsf(h_S_ref[i]) * 0.01f, 1e-2f);
        if (diff > tol) {
            if (tmm_errors < MAX_ERRORS)
                printf("PF_TMM [%d]: got=%f, ref=%f, diff=%f\n", i, p_S[i], h_S_ref[i], diff);
            ++tmm_errors;
        }
    }

    // Verify FA_SOFTMAX
    // Kernel sets per-thread values based on TCU row:
    //   Thread t → fa_i = t / TCU_TC_N
    //   Row fa_i=0: S=2.0, m_old=0.0 → P = exp(0) = 1.0
    //   Row fa_i=1: S=0.0, m_old=1.0 → P = exp(-1) ≈ 0.368
    //
    // In the output matrix, TCU row i cycles within micro-tiles:
    //   xtileM=4, m_steps=2, TCU_TC_M=2
    //   m_step=0 covers rows 0-1: i=0→row0, i=1→row1
    //   m_step=1 covers rows 2-3: i=0→row2, i=1→row3
    //   So fa_row = local_row % TCU_TC_M (not local_row / 2)
    int fa_errors = 0;
    const float exp_neg1 = 0.367879441f;  // exp(-1) from LUT[1]
    for (uint32_t i = 0; i < M * N; ++i) {
        uint32_t row = i / N;
        uint32_t local_row = row % wg_cfg::xtileM;
        uint32_t fa_row = local_row % 2;  // TCU_TC_M=2: i = local_row % TCU_TC_M
        float expected_p = (fa_row == 0) ? 1.0f : exp_neg1;
        float diff = fabsf(p_P[i] - expected_p);
        float tol = 0.1f;  // Tolerance for LUT approximation
        if (diff > tol) {
            if (fa_errors < MAX_ERRORS)
                printf("FA_SOFTMAX [%d]: got=%e, expected=%e, diff=%e\n", i, p_P[i], expected_p, diff);
            ++fa_errors;
        }
    }

    printf("WGMMA: %d errors / %d\n", wgmma_errors, M * N);
    printf("PF_TMM: %d errors / %d\n", tmm_errors, M * N);
    printf("FA_SOFTMAX: %d errors / %d\n", fa_errors, M * N);

    int result = (wgmma_errors == 0 && tmm_errors == 0 && fa_errors == 0) ? 0 : -1;
    printf("TEST %s\n", result == 0 ? "PASSED" : "FAILED");

    cleanup();
    return result;
}
