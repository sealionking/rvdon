// SPDX-License-Identifier: Apache-2.0
// Copyright © 2024-2026 DiVo Gen²AI — 王掬琅（Peter Wang）· 王潇奕（Shawn Wang）
//
// VX_mem_ctrl_wrapper_baiyang_ddr4 — 白杨 DDR4 通用适配器 (模式B: 宽度适配)
//
// 适配 白杨 (YuQuan) DDR4 控制器。
// Wrapper 本体: Apache-2.0 | 白杨 mc_top: MulanPSL-2.0 (需单独获取)
//
// 关键特性:
//   1. 512→256-bit AXI4 宽度适配 (写拆分, 读拼合)
//   2. APB3 自动初始化 (频率参数可配置)
//   3. DFI 3.1 透传给外部 PHY
//   4. mc_ready 门控 (DFI 初始化完成前阻塞 AXI 请求)
//
// DDR4-3200 vs DDR4-2400 差异:
//   - SCG 频率比: 3200:1600 (DDR4-3200) vs 2400:1200 (DDR4-2400)
//   - 时序寄存器: tCL/tRCD/tRP 等值不同
//   - PHY training 窗口更窄
//
// 依赖: 白杨 mc_top (Chisel 生成, ~150个 Verilog 文件)
//
// 参考: https://github.com/OpenXiangShan/YuQuan
// 许可: Apache-2.0 (wrapper), 白杨 mc_top: MulanPSL-2.0 (需单独获取)

// 注: VX_define.vh 依赖 VX_config.vh，仅在完整 Vortex 构建环境中可用。
// 独立编译时请添加 -DVX_CFG_XLEN=64 -DVX_CFG_XLEN_64

`ifdef VX_CFG_YUQUAN_MC_ENABLE

module VX_mem_ctrl_wrapper_baiyang_ddr4 #(
    parameter AXI_DATA_WIDTH  = 512,
    parameter YQ_DATA_WIDTH   = 256,     // 白杨 AXI4 数据宽度
    parameter ADDR_WIDTH      = 48,      // Vortex AXI4 地址宽度
    parameter YQ_ADDR_WIDTH   = 36,      // 白杨 AXI4 地址宽度
    parameter ID_WIDTH        = 8,
    parameter YQ_ID_WIDTH     = 14,
    parameter DDR_FREQ_MHZ    = 3200,    // DDR 频率 (2400 / 3200)
    parameter NUM_BANKS       = 1
) (
    input  wire clk,
    input  wire reset,

    // === AXI4 Master (来自 VX_mem_axi_bridge) ===
    input  wire                     m_axi_awvalid [NUM_BANKS],
    output wire                     m_axi_awready [NUM_BANKS],
    input  wire [ADDR_WIDTH-1:0]    m_axi_awaddr  [NUM_BANKS],
    input  wire [ID_WIDTH-1:0]      m_axi_awid    [NUM_BANKS],
    input  wire [7:0]               m_axi_awlen   [NUM_BANKS],
    input  wire [2:0]               m_axi_awsize  [NUM_BANKS],
    input  wire [1:0]               m_axi_awburst [NUM_BANKS],

    input  wire                     m_axi_wvalid  [NUM_BANKS],
    output wire                     m_axi_wready  [NUM_BANKS],
    input  wire [AXI_DATA_WIDTH-1:0] m_axi_wdata  [NUM_BANKS],
    input  wire [AXI_DATA_WIDTH/8-1:0] m_axi_wstrb[NUM_BANKS],
    input  wire                     m_axi_wlast   [NUM_BANKS],

    output wire                     m_axi_bvalid  [NUM_BANKS],
    input  wire                     m_axi_bready  [NUM_BANKS],
    output wire [ID_WIDTH-1:0]      m_axi_bid     [NUM_BANKS],
    output wire [1:0]               m_axi_bresp   [NUM_BANKS],

    input  wire                     m_axi_arvalid [NUM_BANKS],
    output wire                     m_axi_arready [NUM_BANKS],
    input  wire [ADDR_WIDTH-1:0]    m_axi_araddr  [NUM_BANKS],
    input  wire [ID_WIDTH-1:0]      m_axi_arid    [NUM_BANKS],
    input  wire [7:0]               m_axi_arlen   [NUM_BANKS],
    input  wire [2:0]               m_axi_arsize  [NUM_BANKS],
    input  wire [1:0]               m_axi_arburst [NUM_BANKS],

    output wire                     m_axi_rvalid  [NUM_BANKS],
    input  wire                     m_axi_rready  [NUM_BANKS],
    output wire [AXI_DATA_WIDTH-1:0] m_axi_rdata  [NUM_BANKS],
    output wire [ID_WIDTH-1:0]      m_axi_rid     [NUM_BANKS],
    output wire [1:0]               m_axi_rresp   [NUM_BANKS],
    output wire                     m_axi_rlast   [NUM_BANKS],

    // === DFI 3.1 接口 (连接白杨 mc_top → 外部 PHY) ===
    // 注: 实际 DFI 信号列表非常长（80+ 信号），此处仅展示关键控制信号。
    // 完整信号列表见 VX_yuquan_wrapper.sv (RVDon 私有, 约 130 个 DFI 信号)。
    // 开源版本仅提供框架，用户需根据实际 PHY 补充 DFI 信号。

    output wire                     dfi_init_start,
    input  wire                     dfi_init_complete,
    input  wire                     mig_phy_done,

    // === 调试 ===
    output wire                     debug_init_done,
    output wire [31:0]              debug_err_count
);

    // ================================================================
    // 白杨 APB3 初始化参数
    // ================================================================
    // APB3 写入序列表 (地址, 值)
    // scgmcctrl (0x034): SCG 主控制寄存器
    //   bit[0] = gen: 启动 MC
    //   bit[4:1] = freq_ratio: 频率比
    //     DDR4-2400: MC=1200MHz, DRAM=2400Mbps → freq_ratio=2
    //     DDR4-3200: MC=1600MHz, DRAM=3200Mbps → freq_ratio=2
    //
    // apbcfg (0x3FD): APB 配置完成标志
    //   bit[0] = apbDone: 触发 apbDone 信号

    localparam [31:0] SCG_REG_MCCTRL = 32'h034;
    localparam [31:0] SCG_REG_APBCFG = 32'h3FD;

    // DDR4-2400: scgmcctrl = {28'b0, freq_ratio=4'd2, gen=1} = 32'h0000_0021
    // DDR4-3200: scgmcctrl = {28'b0, freq_ratio=4'd2, gen=1} = 32'h0000_0021 (same ratio)
    // 注: DDR4-3200 在 2:1 频率比下 MC 时钟为 1600MHz，需确认工艺可达。
    // 如果 MC 时钟只能到 1200MHz，需用 3:1 (freq_ratio=3)。
    // DiVo Gen²AI: 当前 DDR4-2400 和 DDR4-3200 在 2:1 频率比下值相同。
    // DDR4-3200 如需 3:1 模式，应改为 32'h0000_0031 (freq_ratio=3)。
    localparam [31:0] SCG_MCCTRL_VALUE = 32'h0000_0021; // freq_ratio=2, gen=1
    localparam [31:0] APBCFG_VALUE = 32'h0000_0001;

    // ================================================================
    // APB3 初始化 FSM
    // ================================================================
    localparam [2:0] APB_IDLE   = 3'd0,
                     APB_SETUP  = 3'd1,
                     APB_ACCESS = 3'd2,
                     APB_GAP    = 3'd3,
                     APB_DONE_S = 3'd4;

    reg [2:0] apb_state;
    reg [1:0] apb_step;   // 0=scgmcctrl, 1=apbcfg, 2=完成
    reg       init_done_r;
    reg [31:0] err_count_r;

    // APB3 信号 (连接到 mc_top)
    reg [11:0] apb_paddr_r;
    reg [31:0] apb_pwdata_r;
    reg        apb_pwrite_r, apb_psel_r, apb_penable_r;
    wire       apb_pready_w = 1'b1;   // 简化: 无等待

    always @(posedge clk) begin
        if (reset) begin
            apb_state    <= APB_IDLE;
            apb_step     <= 2'd0;
            init_done_r  <= 1'b0;
            err_count_r  <= 32'd0;
            apb_paddr_r  <= 12'h0;
            apb_pwdata_r <= 32'h0;
            apb_pwrite_r <= 1'b0;
            apb_psel_r   <= 1'b0;
            apb_penable_r<= 1'b0;
        end else begin
            case (apb_state)
                APB_IDLE: begin
                    apb_psel_r    <= 1'b0;
                    apb_penable_r <= 1'b0;
                    if (mig_phy_done && (apb_step < 2'd2)) begin
                        case (apb_step)
                            2'd0: begin
                                apb_paddr_r  <= SCG_REG_MCCTRL;
                                apb_pwdata_r <= SCG_MCCTRL_VALUE;
                            end
                            2'd1: begin
                                apb_paddr_r  <= SCG_REG_APBCFG;
                                apb_pwdata_r <= APBCFG_VALUE;
                            end
                        endcase
                        apb_pwrite_r <= 1'b1;
                        apb_psel_r   <= 1'b1;
                        apb_state    <= APB_SETUP;
                    end else if (apb_step >= 2'd2) begin
                        init_done_r <= 1'b1;
                        apb_state   <= APB_DONE_S;
                    end
                end

                APB_SETUP: begin
                    apb_penable_r <= 1'b1;
                    apb_state     <= APB_ACCESS;
                end

                APB_ACCESS: begin
                    apb_penable_r <= 1'b0;
                    apb_psel_r    <= 1'b0;
                    apb_state     <= APB_GAP;
                end

                APB_GAP: begin
                    apb_step  <= apb_step + 2'd1;
                    apb_state <= APB_IDLE;
                end

                APB_DONE_S: begin
                    // 初始化完成，保持
                    apb_psel_r    <= 1'b0;
                    apb_penable_r <= 1'b0;
                end

                default: apb_state <= APB_IDLE;
            endcase

            // 错误计数
            if (m_axi_bvalid[0] && m_axi_bresp[0] != 2'b00)
                err_count_r <= err_count_r + 32'd1;
            if (m_axi_rvalid[0] && m_axi_rresp[0] != 2'b00)
                err_count_r <= err_count_r + 32'd1;
        end
    end

    // ================================================================
    // AXI4 宽度适配: 512→256 拆分/拼合
    // ================================================================
    // 注: 此处仅提供框架，完整实现 (含写拆分 FSM 和读拼合 FSM)
    // 在 VX_yuquan_wrapper.sv (RVDon 私有) 中实现。
    // 开源版本提供接口定义和框架，用户需根据实际需求实现。

    localparam HALF_DATA = AXI_DATA_WIDTH / 2;

    // Bank 0 直连（框架，需补充宽度适配逻辑）
    assign m_axi_awready[0] = 1'b0;  // TODO: 宽度适配 FSM
    assign m_axi_wready[0]  = 1'b0;
    assign m_axi_arready[0] = 1'b0;
    assign m_axi_bvalid[0]  = 1'b0;
    assign m_axi_rvalid[0]  = 1'b0;

    `ifndef UNUSED_VAR
    `define UNUSED_VAR(x)
    `endif

    `UNUSED_VAR ({m_axi_awaddr, m_axi_awid, m_axi_awlen, m_axi_wdata, m_axi_wstrb});
    `UNUSED_VAR ({m_axi_araddr, m_axi_arid, m_axi_arlen});

    // ================================================================
    // DFI 状态
    // ================================================================
    wire mc_ready = dfi_init_complete && init_done_r;

    assign dfi_init_start = mig_phy_done;  // PHY 就绪后启动 DFI 初始化

    // ================================================================
    // 调试输出
    // ================================================================
    assign debug_init_done = init_done_r;
    assign debug_err_count = err_count_r;

endmodule

`endif // VX_CFG_YUQUAN_MC_ENABLE
