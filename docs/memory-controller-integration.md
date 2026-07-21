# Vortex 外部 DDR 控制器集成指南

> **贡献者**: DiVo Gen²AI RVDon 团队  
> **许可**: Apache 2.0 (VX_mem_axi_bridge.sv), 本文档  
> **目标读者**: 想给 Vortex GPGPU 接入真实 DDR4/5 控制器的 SoC 开发者

---

## 1. 背景

Vortex GPGPU 默认使用 DPI-C 行为级 DRAM 模型（DramSim），只能用于仿真，无法流片。真实芯片需要物理 DDR 控制器（DDR4/5 Memory Controller + PHY），但没有开源文档解释如何连接。

本指南填补此空白。基于我们在[白杨 DDR4 控制器](https://github.com/OpenXiangShan/YuQuan)上的成功集成经验，提供通用连接方法，适用于任何 AXI4 接口的 DDR 控制器。

---

## 2. 架构概览

```
┌──────────────────────────────────────────────────────┐
│                    Vortex GPGPU                       │
│                                                      │
│  Core0 ... CoreN  →  L1$  →  L2$  →  L3$            │
│                                           │          │
│                                    mem_req/rsp arrays │
│                                    (VX_MEM_PORTS 组)  │
└──────────────────────────────────────┬───────────────┘
                                       │
┌──────────────────────────────────────▼───────────────┐
│              VX_mem_data_adapter                      │
│              数据宽度适配 (L3_LINE → MEM_DATA)         │
└──────────────────────────────────────┬───────────────┘
                                       │
┌──────────────────────────────────────▼───────────────┐
│              VX_mem_bank_adapter                      │
│              Bank 映射 (PORTS → BANKS)                │
└──────────────────────────────────────┬───────────────┘
                                       │
                  ┌────────────────────┼────────────────────┐
                  │                    │                    │
         ┌────────▼────────┐  ┌───────▼────────┐  ┌───────▼────────┐
         │ DPI-C DramSim   │  │ 本指南的桥接层 │  │  未来的控制器   │
         │ (行为级, 默认)  │  │                │  │                │
         └─────────────────┘  └───────┬────────┘  └────────────────┘
                                      │
                         ┌────────────▼────────────┐
                         │   VX_mem_axi_bridge.sv  │
                         │   mem_req/rsp → AXI4     │
                         │   (Apache 2.0, 通用IP)   │
                         └────────────┬────────────┘
                                      │ 标准 AXI4 Master
                         ┌────────────▼────────────┐
                         │   用户的 DDR 控制器       │
                         │   wrapper (宽度适配 +     │
                         │   初始化 + PHY 连接)     │
                         └────────────┬────────────┘
                                      │
                         ┌────────────▼────────────┐
                         │  DDR4/5 Memory Controller │
                         │  (白杨 / Cadence /       │
                         │   Synopsys / 自研)       │
                         └────────────┬────────────┘
                                      │ DFI
                         ┌────────────▼────────────┐
                         │       DDR4/5 PHY         │
                         │  (TinyPHY / 商业 PHY)   │
                         └──────────────────────────┘
```

**核心桥接层只有 2 步**：

1. `mem_req/rsp 信号数组` → **VX_mem_axi_bridge** → `标准 AXI4`
2. 用户自己写的 `DDR 控制器 wrapper` 处理宽度适配和初始化

---

## 3. VX_mem_axi_bridge — 协议转换

### 3.1 Vortex 内存总线协议 (`mem_req/rsp`)

Vortex 内部使用简单的请求/响应握手协议：

| 信号 | 方向 | 描述 |
|------|------|------|
| `mem_req_valid[N]` | Input | 通道 N 有有效请求 |
| `mem_req_rw[N]` | Input | 0=读, 1=写 |
| `mem_req_addr[N]` | Input | 字地址 (word-addressable) |
| `mem_req_byteen[N]` | Input | 字节使能 (data_width/8 位) |
| `mem_req_data[N]` | Input | 写数据 |
| `mem_req_tag[N]` | Input | 事务标签 (uuid + 序列号) |
| `mem_req_ready[N]` | Output | 通道 N 可以接受请求 |
| `mem_rsp_valid[N]` | Output | 通道 N 有响应 |
| `mem_rsp_data[N]` | Output | 读数据 |
| `mem_rsp_tag[N]` | Output | 事务标签 (回传) |
| `mem_rsp_ready[N]` | Input | 通道 N 可以接受响应 |

**关键特性**：
- 独立的读写通道（请求和响应可以流水线执行）
- 地址是 word-addressable（1 word = DATA_WIDTH/8 bytes）
- TAG 包含 UUID (用于追踪事务来源) + 序列号

### 3.2 AXI4 接口

VX_mem_axi_bridge 输出标准 AXI4 Master 接口，5 个通道：
- AW (写地址) + W (写数据) + B (写响应)
- AR (读地址) + R (读数据)

### 3.3 参数说明

| 参数 | 默认值 | 描述 |
|------|--------|------|
| `NUM_PORTS` | 1 | Vortex 内存端口数 (通常 = VX_MEM_PORTS) |
| `DATA_WIDTH` | 512 | 总线数据宽度 (位) |
| `ADDR_WIDTH` | 26 | 字地址宽度 (2^26 × DATA_SIZE 字节地址空间) |
| `TAG_WIDTH` | UUID_WIDTH+1 | 事务标签宽度 |
| `NUM_BANKS` | 1 | AXI4 输出 bank 数 (支持多 bank 并行) |
| `INTERLEAVE` | 0 | Bank 交错: 0=顺序, 1=交错 |

### 3.4 使用示例

```systemverilog
// 在 rtlsim_shim.sv 或你的平台模块中:

VX_mem_axi_bridge #(
    .NUM_PORTS  (VX_MEM_PORTS),
    .DATA_WIDTH (`VX_CFG_L3_LINE_SIZE * 8),
    .ADDR_WIDTH (VX_MEM_ADDR_WIDTH)
) bridge (
    .clk   (clk),
    .reset (reset),

    // Vortex 侧 — 来自 VX_mem_bank_adapter 的输出
    .mem_req_valid (yq_mem_req_valid),
    .mem_req_rw    (yq_mem_req_rw),
    .mem_req_byteen(yq_mem_req_byteen),
    .mem_req_addr  (yq_mem_req_addr),
    .mem_req_data  (yq_mem_req_data),
    .mem_req_tag   (yq_mem_req_tag),
    .mem_req_ready (yq_mem_req_ready),

    .mem_rsp_valid (yq_mem_rsp_valid),
    .mem_rsp_data  (yq_mem_rsp_data),
    .mem_rsp_tag   (yq_mem_rsp_tag),
    .mem_rsp_ready (yq_mem_rsp_ready),

    // AXI4 侧 — 连接你的 DDR 控制器 wrapper
    .m_axi_awvalid (axi_awvalid),
    .m_axi_awready (axi_awready),
    .m_axi_awaddr  (axi_awaddr),
    // ... 其他 AXI4 信号
);
```

---

## 4. DDR 控制器连接模式

### 4.1 模式 A: 同宽度直连 (最简单)

如果 DDR 控制器的 AXI4 数据宽度 = Vortex 的数据宽度（常见于 512-bit DDR4 控制器），无需宽度适配：

```
VX_mem_axi_bridge (512-bit AXI4)
  → 你的 DDR 控制器 (512-bit AXI4 Slave)
  → DDR4/5 PHY
```

**示例**：
```systemverilog
// 假设 mc_top 是 512-bit AXI4 Slave
mc_top u_mc (
    .io_awio_awvalid (axi_awvalid[0]),
    .io_awio_awready (axi_awready[0]),
    .io_awio_awaddr  (axi_awaddr[0]),
    // ... 其余 AXI4 连接
);
```

### 4.2 模式 B: 宽度适配 (白杨场景)

如果 DDR 控制器的数据宽度 < Vortex 的数据宽度（如白杨 256-bit），需要 wrapper 拆分/拼合：

```
VX_mem_axi_bridge (512-bit AXI4)
  → 宽度适配 wrapper (512→256: 写拆分, 读拼合)
  → DDR 控制器 (256-bit AXI4 Slave)
  → DDR4/5 PHY
```

**宽度适配要点**：
- **写**：1×512-bit 拆分为 2×256-bit burst (awlen: N → 2N+1)
- **读**：2×256-bit burst 拼合为 1×512-bit (先收低半部, 后收高半部)

### 4.3 模式 C: 多 Bank 并行

如果 Vortex 有多个内存端口 (NUM_PORTS > 1) 且你想保留并行性：

```systemverilog
VX_mem_axi_bridge #(
    .NUM_PORTS  (VX_MEM_PORTS),
    .NUM_BANKS  (VX_MEM_PORTS),  // 1:1 不共享
    .INTERLEAVE (0)
) bridge (
    // 每个 bank 独立连接到对应的 DDR 控制器
);
```

---

## 5. 集成到 Vortex 构建系统

### 5.1 条件编译控制

在 `sim/rtlsim/Makefile` 中添加：

```makefile
# 启用外部 DDR 控制器
VL_TOP ?= rtlsim
ifeq ($(EXT_MC),1)
  CONFIGS += -DVX_CFG_EXT_MC_ENABLE
  $(info Building with external memory controller support)
endif
```

### 5.2 在 rtlsim_shim.sv 中集成

```systemverilog
`ifdef VX_CFG_EXT_MC_ENABLE
    // 使用外部 DDR 控制器
    VX_mem_axi_bridge #(...) bridge (...);
    // 连接你的 DDR 控制器 wrapper
    my_ddr_wrapper #(...) ddr (...);
`else
    // 默认 DPI-C 行为级 DRAM
    // ... (不做修改)
`endif
```

---

## 6. 风险评估与常见陷阱

### 6.1 风险分层

VX_mem_axi_bridge 本身出错概率极低（~5%，仅限于参数配置错误）。真正的风险在下游：

| 层级 | 出错概率 | 常见问题 |
|------|:---:|------|
| VX_mem_axi_bridge | 🟢 5% | ADDR_WIDTH 配错、TAG_WIDTH 不匹配 |
| DDR 控制器 wrapper | 🟡 70% | 宽度适配的 beat 顺序、初始化序列、复位时序 |
| DDR 控制器 + PHY | 🟡 25% | DFI 时序、training 序列、时钟域交叉 |

### 6.2 仿真 vs FPGA vs ASIC 风险对比

| 场景 | Bridge 风险 | Wrapper 风险 | 说明 |
|------|:---:|:---:|------|
| **Verilator rtlsim** | 几乎为零 | 中 | 仿真无时序约束，主要验证功能正确性 |
| **FPGA 原型** | 低 | 高 | 需处理复位序列、CDC、PHY 硬核对接 |
| **ASIC 流片** | 低 | 极高 | DFI 时序收敛、training 算法、PVT 变异 |

### 6.3 常见陷阱

#### 陷阱 1：地址宽度不匹配
```
Vortex 内部: word-addressable (1 word = 64B, ADDR_WIDTH=26 → 4GB)
AXI4 外部:   byte-addressable (ADDR_WIDTH=32 → 4GB)
```
**症状**: 读写地址偏移错误，高地址访问失败
**检查**: 确认 `ADDR_WIDTH_OUT = ADDR_WIDTH + $clog2(DATA_WIDTH/8)`

#### 陷阱 2：TAG 宽度不足
```
Vortex tag: UUID_WIDTH + 1 (控制事务追踪)
AXI4 ID:    必须 >= TAG_WIDTH_IN + log2(NUM_PORTS)
```
**症状**: 多个并发事务的响应匹配错乱
**检查**: TAG_WIDTH_OUT >= TAG_WIDTH_IN + $clog2(NUM_PORTS_IN)

#### 陷阱 3：宽度适配的 beat 顺序
```
写: 512-bit → 2×256-bit: 低半部先发, 高半部后发
读: 2×256-bit → 512-bit: 低半部先收, 高半部后收
```
**症状**: 高32字节和低32字节数据错位
**检查**: 验证 64B 对齐的跨边界写入

#### 陷阱 4：AXI4 响应错误处理
VX_axi_adapter 默认对 AXI BRESP/RRESP（非 OKAY）响应只有 assertion，不处理错误恢复。
**症状**: AXI 错误时仿真 crash（rtlsim）或无响应挂死（FPGA）
**建议**: 在 wrapper 层添加错误计数器和超时机制

#### 陷阱 5：Verilator 版本兼容性
Verilator 5.032+ 的 LATCH 警告更严格。低版本（5.020）编译通过的代码在高版本可能报错。
**建议**: 固定 Verilator 版本（推荐 5.020），或在 Makefile 中添加 `-Wno-LATCH`

---

## 7. Wrapper 开发规范

### 7.1 最小验证流程

每个新 wrapper 必须通过以下验证：

```
Phase 1: 冒烟测试
  ├── 基本读写: 写 64B → 读 64B，验证数据完整性
  ├── 地址扫描: 在不同地址区域读写（起始/中间/末尾）
  └── 预期: 0 错误

Phase 2: 并发测试
  ├── 多端口并发读写（如 NUM_PORTS >= 2）
  ├── 读写交错（连续写 + 连续读）
  └── 预期: 数据一致性，无死锁

Phase 3: 压力测试
  ├── 全地址空间随机读写（>= 10000 次事务）
  ├── burst 对齐和跨边界测试
  └── 预期: 0 数据错误

Phase 4 (FPGA 可选): 时序验证
  ├── Vivado/Quartus 时序报告无违规
  ├── 目标频率下 ChipScope/ILA 波形验证
  └── 预期: 时序收敛，实际读写正确
```

### 7.2 Wrapper 接口模板

```systemverilog
module VX_mem_ctrl_wrapper_<控制器名> #(
    parameter AXI_DATA_WIDTH = 512,   // Vortex 侧数据宽度
    parameter MC_DATA_WIDTH  = ???,   // 控制器侧数据宽度
    parameter AXI_ADDR_WIDTH = 32,    // byte-addressable
    parameter AXI_ID_WIDTH   = 8
) (
    input  wire clk,
    input  wire reset,

    // === AXI4 Master (来自 VX_mem_axi_bridge) ===
    // (标准 AXI4 5 通道，参见 bridge 端口定义)

    // === 控制器专用接口 (DFI/APB/配置) ===
    // (控制器特有的初始化、配置、PHY 接口)

    // === 调试/监控 ===
    output wire [31:0] debug_err_count,   // AXI 错误计数
    output wire        debug_init_done,    // 初始化完成
    output wire [31:0] debug_rd_bytes,    // 读字节计数
    output wire [31:0] debug_wr_bytes     // 写字节计数
);
```

### 7.3 必须实现的调试信号

| 信号 | 宽度 | 描述 |
|------|:---:|------|
| `debug_init_done` | 1 | MC 初始化完成标志 |
| `debug_err_count` | 32 | AXI BRESP/RRESP != OKAY 累计 |
| `debug_rd_bytes` | 32 | 成功读取的总字节数 |
| `debug_wr_bytes` | 32 | 成功写入的总字节数 |
| `debug_timeout` | 1 | 事务超时标志（>10K 周期无响应） |

---

## 8. 开源内存控制器适配矩阵

### 8.1 已适配 / 适配中

| 控制器 | 标准 | 频率 | 数据宽度 | 模式 | 许可 | 验证状态 | Wrapper文件 | 维护者 |
|--------|------|------|:---:|:---:|------|:---:|------|------|
| **[白杨 (YuQuan)](https://github.com/OpenXiangShan/YuQuan)** | DDR4 | 2400 | 256-bit | B | MulanPSL-2.0 | ✅ SimX | `VX_yuquan_wrapper.sv` | DiVo |
| 白杨 DDR4-3200 | DDR4 | 3200 | 256-bit | B | MulanPSL-2.0 | ✅ APB3 Init TB | `VX_mem_ctrl_wrapper_baiyang_ddr4.sv` | DiVo |
| **DDR4-IP / CVA6 / serv** | DDR4 | — | 512-bit | A | 各项目许可 | ✅ 62 tests | `VX_mem_ctrl_wrapper_passthrough.sv` | DiVo |
| **LiteDRAM** | DDR3/4 | — | 128/256 | B | MIT | ✅ 20 tests | `VX_mem_ctrl_wrapper_litedram.sv` | DiVo |
| **DDR3-Controller** | DDR3 | — | 128 | B | MIT | ✅ 20 tests | `VX_mem_ctrl_wrapper_ddr3ctrl.sv` | DiVo |
| **CVA6 AXI DRAM** | DDR4 | — | 128/512 | A/B | Solderpad | ✅ 20 tests (passthrough) | `VX_mem_ctrl_wrapper_cva6_axi.sv` | DiVo |
| 白杨 LPDDR5 | LPDDR5 | — | — | B | MulanPSL-2.0 | 🔮 远期 | — | — |

> **验证状态说明**: "✅ N tests" 表示 Verilator 5.020 standalone testbench 通过 N 次写-读验证；
> "✅ APB3 Init TB" 表示仅 APB3 初始化序列通过（AXI4 数据通路为框架 TODO）；
> "✅ SimX" 表示 Vortex SimX 全系统仿真通过

### 8.2 计划适配（欢迎贡献）

| 控制器 | 标准 | 数据宽度 | 难度 | 许可 |
|--------|------|:---:|:---:|------|
| **[serv DDR](https://github.com/olofk/serv)** | LPDDR | 32 | ⭐ | ISC |
| [Caliptra AHB-Lite](https://github.com/chipsalliance/caliptra-rtl) | SRAM | 32 | ⭐ | Apache 2.0 |
| [LPDDR4-Controller](https://github.com/AMBArDLab/lpddr4-controller) | LPDDR4 | 16/32 | ⭐⭐⭐ | BSD-3 |

### 8.3 远期目标

| 控制器 | 标准 | 数据宽度 | 难度 | 预估工时 |
|--------|------|:---:|:---:|:---:|
| 白杨 DDR5（等上游开放） | DDR5 | 512 | ⭐⭐⭐⭐ | ~2周 |
| [NVDLA SDP](https://github.com/nvdla/hw) | 统一内存 | 512 | ⭐⭐⭐ | ~1周 |

### 8.4 难度评级

| 难度 | 说明 | 示例 |
|:---:|------|------|
| ⭐ | 同宽直连（模式 A），无适配逻辑 | DDR4-IP 512-bit |
| ⭐⭐ | 宽度适配（模式 B），简单 FSM | LiteDRAM 128→512 |
| ⭐⭐⭐ | 复杂初始化序列 + CDC | 带 DDR training |
| ⭐⭐⭐⭐ | 全新协议（DFI 5.2 / LPDDR5） | 白杨 DDR5 |

---

## 9. Wrapper 开发检查清单

在提交 PR 前，确认以下各项：

### 代码质量
- [ ] 接口信号命名遵循 `VX_mem_ctrl_wrapper_<name>` 约定
- [ ] 所有参数有默认值和注释
- [ ] 宽度适配逻辑有独立的状态机（不混入初始化逻辑）
- [ ] 初始化序列有清晰的 FSM 注释和状态图
- [ ] 包含调试信号（init_done, err_count, rd/wr_bytes）
- [ ] 条件编译用 `VX_CFG_<NAME>_MC_ENABLE` 包裹

### 仿真验证
- [ ] rtlsim 基本读写通过（0 错误）
- [ ] 并发多端口读写通过（0 死锁）
- [ ] 压力测试通过（>= 10000 随机地址，0 数据错误）
- [ ] AXI 错误注入测试通过（超时/错误响应不 crash）
- [ ] Verilator 编译无 LATCh/UNUSED 警告
- [ ] 测试覆盖边界：地址 0、地址最大值、跨 bank、非对齐

### 文档
- [ ] 本文件 §8 适配矩阵表已更新
- [ ] README 中有构建命令（`make EXT_MC=1`）
- [ ] wrapper 头注释说明支持的配置/频率
- [ ] 已知限制已标注

---

## 10. Verilator Standalone 验证

每个 wrapper 附带独立 testbench，无需完整 Vortex 构建即可验证。

### 10.1 目录结构

```
hw/rtl/mem/wrappers/
├── VX_mem_ctrl_wrapper_passthrough.sv      # 模式A: 同宽直连
├── VX_mem_ctrl_wrapper_litedram.sv         # 模式B: Wishbone 适配
├── VX_mem_ctrl_wrapper_ddr3ctrl.sv         # 模式B: DDR3 简单握手
├── VX_mem_ctrl_wrapper_cva6_axi.sv         # 模式A/B: CVA6 AXI
├── VX_mem_ctrl_wrapper_baiyang_ddr4.sv     # 模式B: 白杨 DDR4 (ifdef 保护)
└── common/
    ├── VX_mock_axi_memory.sv               # AXI4 BRAM mock memory
    ├── tb_wrapper_passthrough_standalone.sv # passthrough TB (62 tests)
    ├── tb_wrapper_litedram_standalone.sv    # litedram TB (20 tests)
    ├── tb_wrapper_ddr3ctrl_standalone.sv    # ddr3ctrl TB (20 tests)
    ├── tb_wrapper_cva6_axi_standalone.sv    # cva6_axi TB (20 tests)
    ├── tb_wrapper_baiyang_ddr4_standalone.sv# baiyang DDR4 TB (APB3)
    ├── main_passthrough.cpp                 # passthrough C++ main
    └── main_wrappers.cpp                    # 通用 C++ main (多 TB)
```

### 10.2 构建命令

```bash
cd hw/rtl/mem/wrappers/common

# passthrough (62 tests)
verilator --cc --exe --build -j 0 --language 1800-2012 \
  -Wno-fatal -Wno-LATCH -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL \
  -Mdir obj_dir tb_wrapper_passthrough_standalone.sv \
  ../VX_mem_ctrl_wrapper_passthrough.sv VX_mock_axi_memory.sv \
  main_passthrough.cpp -o tb_passthrough

# litedram (20 tests)
verilator --cc --exe --build -j 0 --language 1800-2012 \
  -Wno-fatal -Wno-LATCH -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
  -CFLAGS -DTB_LITEDRAM -Mdir obj_dir_ld \
  tb_wrapper_litedram_standalone.sv ../VX_mem_ctrl_wrapper_litedram.sv \
  main_wrappers.cpp -o tb_litedram

# ddr3ctrl (20 tests)
verilator --cc --exe --build -j 0 --language 1800-2012 \
  -Wno-fatal -Wno-LATCH -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
  -CFLAGS -DTB_DDR3CTRL -Mdir obj_dir_ddr3 \
  tb_wrapper_ddr3ctrl_standalone.sv ../VX_mem_ctrl_wrapper_ddr3ctrl.sv \
  main_wrappers.cpp -o tb_ddr3ctrl

# cva6_axi (20 tests, passthrough 模式)
verilator --cc --exe --build -j 0 --language 1800-2012 \
  -Wno-fatal -Wno-LATCH -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
  -CFLAGS -DTB_CVA6_AXI -Mdir obj_dir_cva6 \
  tb_wrapper_cva6_axi_standalone.sv ../VX_mem_ctrl_wrapper_cva6_axi.sv \
  main_wrappers.cpp -o tb_cva6

# baiyang DDR4 (APB3 初始化验证, 需 ifdef 宏)
verilator --cc --exe --build -j 0 --language 1800-2012 \
  -Wno-fatal -Wno-LATCH -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
  -DVX_CFG_YUQUAN_MC_ENABLE \
  -CFLAGS -DTB_BAIYANG_DDR4 -Mdir obj_dir_baiyang \
  tb_wrapper_baiyang_ddr4_standalone.sv ../VX_mem_ctrl_wrapper_baiyang_ddr4.sv \
  main_wrappers.cpp -o tb_baiyang
```

运行: `./obj_dir/tb_passthrough` (输出 `PASSED: ...`)

### 10.3 验证结果汇总

| Wrapper | 测试类型 | 测试次数 | 结果 | 修复的 Bug |
|---------|----------|:--------:|:----:|-----------|
| passthrough | 写-读验证 | 62 | PASSED | — |
| litedram | 512→128 WB 适配 | 20 | PASSED | — |
| ddr3ctrl | 512→128 cmd/data | 20 | PASSED | mask 反转 + NBA 读旧值 + 响应模型地址偏移 |
| cva6_axi | passthrough 模式 | 20 | PASSED | — |
| baiyang_ddr4 | APB3 初始化序列 | — | PASSED | — |

### 10.4 已知限制

| ID | 限制 | 影响 | 计划 |
|----|------|------|------|
| W-1 | CVA6 AXI wrapper 宽度适配模式(512→128)为 stub | 仅 passthrough 模式可用 | 后续实现 |
| W-2 | 白杨 DDR4 wrapper AXI4 数据通路(512→256)为框架 | 仅 APB3 初始化可验证 | VX_yuquan_wrapper.sv (RVDon 私有) 中完整实现 |
| W-3 | 白杨 DDR4 wrapper DFI 信号仅框架定义 | 无法接真实 PHY | 用户按实际 PHY 补充 |
| W-4 | ddr3ctrl wrapper mask 语义反转 | ultraembedded 协议特有，非通用 | 已在 wrapper 内处理 |
| W-5 | litedram/ddr3ctrl 要求 AW 与 W 同周期到达 | AW 先到不锁存 → 死锁 | 上游 VX_axi_adapter 保征同拍; 后续独立锁存 |
| W-6 | 白杨 DDR4 APB3 信号为内部 reg 无端口 | 仅仿真可验证初始化序列 | 开源版仅仿真; 私有版有端口 |
| W-7 | TB 测试覆盖缺口: 无大地址回绕/非对齐/部分写 | 宽度适配高 beat 通路已验证 | 后续迭代补充 |

> **W-5 说明**: litedram 和 ddr3ctrl wrapper 的 S_IDLE 要求 `awvalid && wvalid` 同时为高才锁存。
> 这是因为 Vortex 的 VX_axi_adapter 在同一拍发出 AW 和 W 信号。
> 如果您的上游不保证同拍 AW/W，需修改 wrapper 为独立锁存模式（参照 passthrough wrapper）。

---

## 11. 白杨 DDR4 集成实例 (DiVo RVDon)

我们使用本指南的方法成功集成了[白杨 DDR4 控制器](https://github.com/OpenXiangShan/YuQuan) (MulanPSL-2.0)：

- 集成电路图参见 §2 架构概览
- 512→256 宽度适配 (模式 B, §4.2)
- APB3 自动初始化 (PHY ready → 写配置寄存器 → MC 启动)
- DFI 3.1 仿真模型 (Verilator 可用 BRAM 替代)
- SimX 行为级验证通过

白杨集成详情见 [openwiki/yuquan-integration.md](../openwiki/yuquan-integration.md)。

---

## 12. 贡献

欢迎提交 PR 添加新的 DDR 控制器兼容适配器。详见 §9 开发检查清单。

**开源策略**: "开源小手信" — 每个适配器小而精，充分验证，独立提交。

**维护者**: DiVo Gen²AI — 王掬琅 (Peter Wang) · 王潇奕 (Shawn Wang)  
**仓库**: https://github.com/vortexgpgpu/vortex (上游)  
**联系**: 通过 Vortex GitHub Issues 或 Discussions
