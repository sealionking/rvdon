#ifndef _COMMON_H_
#define _COMMON_H_

#include <stdint.h>

#ifndef VX_CFG_NUM_THREADS
#define VX_CFG_NUM_THREADS 4
#endif

// PF_TMM test: small matrix dimensions
// M=N=8, K=8 for fp32 (tcM=tcN=tcK=4, 2 steps each)
#define PF_MAT_M 8
#define PF_MAT_N 8
#define PF_MAT_K 8

typedef struct {
  uint32_t M, N, K;
  uint64_t A_addr;    // A matrix (row-major, M x K)
  uint64_t B_addr;    // B matrix (row-major, K x N)
  uint64_t C_addr;    // C matrix output (row-major, M x N × 2: WGMMA then PF_TMM)
} kernel_arg_t;

#endif
