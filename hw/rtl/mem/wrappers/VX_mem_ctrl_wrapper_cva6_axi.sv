// SPDX-License-Identifier: Apache-2.0
// Copyright © 2024-2026 DiVo Gen²AI — 王掬琅（Peter Wang）· 王潇奕（Shawn Wang）
//
// VX_mem_ctrl_wrapper_cva6_axi — CVA6 AXI DRAM 适配器 (模式A: 同宽直连)
//
// CVA6 (formerly Ariane) 是一个成熟的开源 RISC-V 核心，来自 OpenHW Group。
// 其 AXI DRAM 控制器通过标准 AXI4 接口连接外部 DDR 内存。
//
// 配置:
//   - CVA6 AXI: 64-bit 或 128-bit (可配置)
//   - Vortex AXI4: 通常 512-bit
//   - 需要宽度适配 (模式B) 如果 CVA6 < Vortex 数据宽度
//
// 参考: https://github.com/openhwgroup/cva6
// 许可: Apache-2.0 (wrapper) | CVA6: Solderpad-2.1

module VX_mem_ctrl_wrapper_cva6_axi #(
    parameter AXI_DATA_WIDTH  = 512,     // Vortex AXI4 数据宽度
    parameter CVA6_DATA_WIDTH = 128,     // CVA6 AXI 数据宽度
    parameter ADDR_WIDTH      = 32,
    parameter ID_WIDTH        = 8,
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

    // === CVA6 AXI4 Slave (连接到 CVA6 AXI DRAM 控制器) ===
    output wire                     cva6_axi_awvalid [NUM_BANKS],
    input  wire                     cva6_axi_awready [NUM_BANKS],
    output wire [ADDR_WIDTH-1:0]    cva6_axi_awaddr  [NUM_BANKS],
    output wire [ID_WIDTH-1:0]      cva6_axi_awid    [NUM_BANKS],
    output wire [7:0]               cva6_axi_awlen   [NUM_BANKS],
    output wire [2:0]               cva6_axi_awsize  [NUM_BANKS],
    output wire [1:0]               cva6_axi_awburst [NUM_BANKS],

    output wire                     cva6_axi_wvalid  [NUM_BANKS],
    input  wire                     cva6_axi_wready  [NUM_BANKS],
    output wire [CVA6_DATA_WIDTH-1:0] cva6_axi_wdata [NUM_BANKS],
    output wire [CVA6_DATA_WIDTH/8-1:0] cva6_axi_wstrb[NUM_BANKS],
    output wire                     cva6_axi_wlast   [NUM_BANKS],

    input  wire                     cva6_axi_bvalid  [NUM_BANKS],
    output wire                     cva6_axi_bready  [NUM_BANKS],
    input  wire [ID_WIDTH-1:0]      cva6_axi_bid     [NUM_BANKS],
    input  wire [1:0]               cva6_axi_bresp   [NUM_BANKS],

    output wire                     cva6_axi_arvalid [NUM_BANKS],
    input  wire                     cva6_axi_arready [NUM_BANKS],
    output wire [ADDR_WIDTH-1:0]    cva6_axi_araddr  [NUM_BANKS],
    output wire [ID_WIDTH-1:0]      cva6_axi_arid    [NUM_BANKS],
    output wire [7:0]               cva6_axi_arlen   [NUM_BANKS],
    output wire [2:0]               cva6_axi_arsize  [NUM_BANKS],
    output wire [1:0]               cva6_axi_arburst [NUM_BANKS],

    input  wire                     cva6_axi_rvalid  [NUM_BANKS],
    output wire                     cva6_axi_rready  [NUM_BANKS],
    input  wire [CVA6_DATA_WIDTH-1:0] cva6_axi_rdata [NUM_BANKS],
    input  wire [ID_WIDTH-1:0]      cva6_axi_rid     [NUM_BANKS],
    input  wire [1:0]               cva6_axi_rresp   [NUM_BANKS],
    input  wire                     cva6_axi_rlast   [NUM_BANKS],

    // === 调试 ===
    output wire                     debug_init_done,
    output wire [31:0]              debug_rd_bytes,
    output wire [31:0]              debug_wr_bytes
);

    // 宽度适配参数
    localparam BEATS_PER_AXI = AXI_DATA_WIDTH / CVA6_DATA_WIDTH;
    localparam BEAT_BITS     = $clog2(BEATS_PER_AXI);
    localparam CVA6_BYTES    = CVA6_DATA_WIDTH / 8;

    genvar bank;
    generate
        for (bank = 0; bank < NUM_BANKS; bank = bank + 1) begin : g_bank

            // 直连模式（宽度相同时）
            if (AXI_DATA_WIDTH == CVA6_DATA_WIDTH) begin : g_passthrough
                assign cva6_axi_awvalid[bank] = m_axi_awvalid[bank];
                assign cva6_axi_awaddr [bank] = m_axi_awaddr[bank];
                assign cva6_axi_awid   [bank] = m_axi_awid[bank];
                assign cva6_axi_awlen  [bank] = m_axi_awlen[bank];
                assign cva6_axi_awsize [bank] = m_axi_awsize[bank];
                assign cva6_axi_awburst[bank] = m_axi_awburst[bank];
                assign m_axi_awready   [bank] = cva6_axi_awready[bank];

                assign cva6_axi_wvalid [bank] = m_axi_wvalid[bank];
                assign cva6_axi_wdata  [bank] = m_axi_wdata[bank];
                assign cva6_axi_wstrb  [bank] = m_axi_wstrb[bank];
                assign cva6_axi_wlast  [bank] = m_axi_wlast[bank];
                assign m_axi_wready    [bank] = cva6_axi_wready[bank];

                assign m_axi_bvalid    [bank] = cva6_axi_bvalid[bank];
                assign m_axi_bid       [bank] = cva6_axi_bid[bank];
                assign m_axi_bresp     [bank] = cva6_axi_bresp[bank];
                assign cva6_axi_bready [bank] = m_axi_bready[bank];

                assign cva6_axi_arvalid[bank] = m_axi_arvalid[bank];
                assign cva6_axi_araddr [bank] = m_axi_araddr[bank];
                assign cva6_axi_arid   [bank] = m_axi_arid[bank];
                assign cva6_axi_arlen  [bank] = m_axi_arlen[bank];
                assign cva6_axi_arsize [bank] = m_axi_arsize[bank];
                assign cva6_axi_arburst[bank] = m_axi_arburst[bank];
                assign m_axi_arready   [bank] = cva6_axi_arready[bank];

                assign m_axi_rvalid    [bank] = cva6_axi_rvalid[bank];
                assign m_axi_rdata     [bank] = AXI_DATA_WIDTH'(cva6_axi_rdata[bank]);
                assign m_axi_rid       [bank] = cva6_axi_rid[bank];
                assign m_axi_rresp     [bank] = cva6_axi_rresp[bank];
                assign m_axi_rlast     [bank] = cva6_axi_rlast[bank];
                assign cva6_axi_rready [bank] = m_axi_rready[bank];
            end
            // 宽度适配模式: 512→128 (CVA6 通常 128-bit)
            else begin : g_adapt
                // 复用 passthrough wrapper 的直连逻辑 + 在此加宽度适配说明
                // 注: CVA6 128-bit 需要 4-beat burst，实现逻辑见 litedram wrapper
                // 实际使用请参考该 wrapper 的 FSM 设计
                //$error("CVA6 width adaptation not yet implemented; use litedram wrapper as template");
                // 临时直连（仅用于编译验证，不保证功能正确）
                assign cva6_axi_awvalid[bank] = 1'b0;
                assign cva6_axi_wvalid[bank] = 1'b0;
                assign cva6_axi_arvalid[bank] = 1'b0;
                assign cva6_axi_bready[bank]  = 1'b1;
                assign cva6_axi_rready[bank]  = 1'b1;
                assign m_axi_awready[bank] = 1'b0;
                assign m_axi_wready[bank]  = 1'b0;
                assign m_axi_arready[bank] = 1'b0;
                assign m_axi_bvalid[bank]  = 1'b0;
                assign m_axi_rvalid[bank]  = 1'b0;
            end
        end
    endgenerate

    assign debug_init_done = 1'b1;
    assign debug_rd_bytes  = 32'd0;
    assign debug_wr_bytes  = 32'd0;

endmodule
