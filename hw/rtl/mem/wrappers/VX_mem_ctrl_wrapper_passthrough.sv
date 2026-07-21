// SPDX-License-Identifier: Apache-2.0
// Copyright © 2024-2026 DiVo Gen²AI — 王掬琅（Peter Wang）· 王潇奕（Shawn Wang）
//
// VX_mem_ctrl_wrapper_passthrough — 同宽直连通用 wrapper (模式A)
//
// 适用于任何与 Vortex 数据宽度相同的 AXI4 DDR 控制器。
// 不做宽度适配，不做初始化——仅参数化直连。
//
// 适用控制器:
//   - DDR4-IP (davidcastells/ddr4-ip, MIT) — 512-bit AXI4
//   - CVA6 AXI DRAM (openhwgroup/cva6) — 64/128-bit AXI4
//   - serv DDR (olofk/serv) — 32-bit Wishbone (需外部 Wishbone→AXI4)
//
// 验证: VX_mock_axi_memory + standalone testbench

module VX_mem_ctrl_wrapper_passthrough #(
    parameter AXI_DATA_WIDTH = 512,
    parameter AXI_ADDR_WIDTH = 32,
    parameter AXI_ID_WIDTH   = 8,
    parameter NUM_BANKS      = 1,
    parameter MC_NAME         = "generic"
) (
    input  wire clk,
    input  wire reset,

    // === AXI4 Master (来自 VX_mem_axi_bridge) ===
    input  wire                     m_axi_awvalid [NUM_BANKS],
    output wire                     m_axi_awready [NUM_BANKS],
    input  wire [AXI_ADDR_WIDTH-1:0] m_axi_awaddr [NUM_BANKS],
    input  wire [AXI_ID_WIDTH-1:0]  m_axi_awid   [NUM_BANKS],
    input  wire [7:0]               m_axi_awlen  [NUM_BANKS],
    input  wire [2:0]               m_axi_awsize [NUM_BANKS],
    input  wire [1:0]               m_axi_awburst[NUM_BANKS],

    input  wire                     m_axi_wvalid [NUM_BANKS],
    output wire                     m_axi_wready [NUM_BANKS],
    input  wire [AXI_DATA_WIDTH-1:0] m_axi_wdata [NUM_BANKS],
    input  wire [AXI_DATA_WIDTH/8-1:0] m_axi_wstrb[NUM_BANKS],
    input  wire                     m_axi_wlast  [NUM_BANKS],

    output wire                     m_axi_bvalid [NUM_BANKS],
    input  wire                     m_axi_bready [NUM_BANKS],
    output wire [AXI_ID_WIDTH-1:0]  m_axi_bid    [NUM_BANKS],
    output wire [1:0]               m_axi_bresp  [NUM_BANKS],

    input  wire                     m_axi_arvalid[NUM_BANKS],
    output wire                     m_axi_arready[NUM_BANKS],
    input  wire [AXI_ADDR_WIDTH-1:0] m_axi_araddr[NUM_BANKS],
    input  wire [AXI_ID_WIDTH-1:0]  m_axi_arid  [NUM_BANKS],
    input  wire [7:0]               m_axi_arlen [NUM_BANKS],
    input  wire [2:0]               m_axi_arsize[NUM_BANKS],
    input  wire [1:0]               m_axi_arburst[NUM_BANKS],

    output wire                     m_axi_rvalid[NUM_BANKS],
    input  wire                     m_axi_rready[NUM_BANKS],
    output wire [AXI_DATA_WIDTH-1:0] m_axi_rdata[NUM_BANKS],
    output wire [AXI_ID_WIDTH-1:0]  m_axi_rid  [NUM_BANKS],
    output wire [1:0]               m_axi_rresp[NUM_BANKS],
    output wire                     m_axi_rlast[NUM_BANKS],

    // === 控制器 AXI4 Slave (直连到下游 DDR 控制器) ===
    output wire                     s_axi_awvalid [NUM_BANKS],
    input  wire                     s_axi_awready [NUM_BANKS],
    output wire [AXI_ADDR_WIDTH-1:0] s_axi_awaddr[NUM_BANKS],
    output wire [AXI_ID_WIDTH-1:0]  s_axi_awid   [NUM_BANKS],
    output wire [7:0]               s_axi_awlen  [NUM_BANKS],
    output wire [2:0]               s_axi_awsize [NUM_BANKS],
    output wire [1:0]               s_axi_awburst[NUM_BANKS],

    output wire                     s_axi_wvalid [NUM_BANKS],
    input  wire                     s_axi_wready [NUM_BANKS],
    output wire [AXI_DATA_WIDTH-1:0] s_axi_wdata [NUM_BANKS],
    output wire [AXI_DATA_WIDTH/8-1:0] s_axi_wstrb[NUM_BANKS],
    output wire                     s_axi_wlast  [NUM_BANKS],

    input  wire                     s_axi_bvalid [NUM_BANKS],
    output wire                     s_axi_bready [NUM_BANKS],
    input  wire [AXI_ID_WIDTH-1:0]  s_axi_bid    [NUM_BANKS],
    input  wire [1:0]               s_axi_bresp  [NUM_BANKS],

    output wire                     s_axi_arvalid[NUM_BANKS],
    input  wire                     s_axi_arready[NUM_BANKS],
    output wire [AXI_ADDR_WIDTH-1:0] s_axi_araddr[NUM_BANKS],
    output wire [AXI_ID_WIDTH-1:0]  s_axi_arid  [NUM_BANKS],
    output wire [7:0]               s_axi_arlen [NUM_BANKS],
    output wire [2:0]               s_axi_arsize[NUM_BANKS],
    output wire [1:0]               s_axi_arburst[NUM_BANKS],

    input  wire                     s_axi_rvalid[NUM_BANKS],
    output wire                     s_axi_rready[NUM_BANKS],
    input  wire [AXI_DATA_WIDTH-1:0] s_axi_rdata[NUM_BANKS],
    input  wire [AXI_ID_WIDTH-1:0]  s_axi_rid  [NUM_BANKS],
    input  wire [1:0]               s_axi_rresp[NUM_BANKS],
    input  wire                     s_axi_rlast[NUM_BANKS],

    // === 调试 ===
    output wire                     debug_init_done,
    output wire [31:0]              debug_rd_bytes,
    output wire [31:0]              debug_wr_bytes
);

    // Passthrough: 直连，不做转换
    // 注: 此 wrapper 不处理初始化、宽度适配、CDC。
    // 如果控制器需要初始化，请在 s_axi_ 侧添加初始化逻辑。

    genvar i;
    generate
        for (i = 0; i < NUM_BANKS; i = i + 1) begin : g_passthrough
            // Write address
            assign s_axi_awvalid[i] = m_axi_awvalid[i];
            assign s_axi_awaddr[i]  = m_axi_awaddr[i];
            assign s_axi_awid[i]    = m_axi_awid[i];
            assign s_axi_awlen[i]   = m_axi_awlen[i];
            assign s_axi_awsize[i]  = m_axi_awsize[i];
            assign s_axi_awburst[i] = m_axi_awburst[i];
            assign m_axi_awready[i] = s_axi_awready[i];

            // Write data
            assign s_axi_wvalid[i]  = m_axi_wvalid[i];
            assign s_axi_wdata[i]   = m_axi_wdata[i];
            assign s_axi_wstrb[i]   = m_axi_wstrb[i];
            assign s_axi_wlast[i]   = m_axi_wlast[i];
            assign m_axi_wready[i]  = s_axi_wready[i];

            // Write response
            assign m_axi_bvalid[i]  = s_axi_bvalid[i];
            assign m_axi_bid[i]     = s_axi_bid[i];
            assign m_axi_bresp[i]   = s_axi_bresp[i];
            assign s_axi_bready[i]  = m_axi_bready[i];

            // Read address
            assign s_axi_arvalid[i] = m_axi_arvalid[i];
            assign s_axi_araddr[i]  = m_axi_araddr[i];
            assign s_axi_arid[i]    = m_axi_arid[i];
            assign s_axi_arlen[i]   = m_axi_arlen[i];
            assign s_axi_arsize[i]  = m_axi_arsize[i];
            assign s_axi_arburst[i] = m_axi_arburst[i];
            assign m_axi_arready[i] = s_axi_arready[i];

            // Read data
            assign m_axi_rvalid[i]  = s_axi_rvalid[i];
            assign m_axi_rdata[i]   = s_axi_rdata[i];
            assign m_axi_rid[i]     = s_axi_rid[i];
            assign m_axi_rresp[i]   = s_axi_rresp[i];
            assign m_axi_rlast[i]   = s_axi_rlast[i];
            assign s_axi_rready[i]  = m_axi_rready[i];
        end
    endgenerate

    // Debug: passthrough 无需初始化
    assign debug_init_done = 1'b1;

    // 字节计数（基于 handshake）
    reg [31:0] rd_bytes_r;
    reg [31:0] wr_bytes_r;
    localparam B_PER_BEAT = AXI_DATA_WIDTH / 8;

    always @(posedge clk) begin
        if (reset) begin
            rd_bytes_r <= 32'd0;
            wr_bytes_r <= 32'd0;
        end else begin
            for (int b = 0; b < NUM_BANKS; b = b + 1) begin
                if (s_axi_wvalid[b] && s_axi_wready[b])
                    wr_bytes_r <= wr_bytes_r + 32'(B_PER_BEAT);
                if (s_axi_rvalid[b] && s_axi_rready[b])
                    rd_bytes_r <= rd_bytes_r + 32'(B_PER_BEAT);
            end
        end
    end

    assign debug_rd_bytes = rd_bytes_r;
    assign debug_wr_bytes = wr_bytes_r;

endmodule
