// SPDX-License-Identifier: Apache-2.0
// Copyright © 2024-2026 DiVo Gen²AI — 王掬琅（Peter Wang）· 王潇奕（Shawn Wang）
//
// VX_mock_axi_memory — AXI4 Slave 内存模型，用于 wrapper 独立验证
//
// H-4 fix: 加固写通路 — AW/W 独立锁存，B 在 W 收齐后才发
// 支持单 beat 读写（awlen=0, arlen=0）。
// 内部用 BRAM 数组存储数据，无需真实 DDR 控制器。

module VX_mock_axi_memory #(
    parameter DATA_WIDTH = 512,
    parameter ADDR_WIDTH = 32,     // byte-addressable
    parameter ID_WIDTH   = 8,
    parameter MEM_DEPTH   = 1024   // addressable units (DATA_WIDTH bits each)
) (
    input  wire clk,
    input  wire reset,

    // AXI4 Write Address
    input  wire                     s_axi_awvalid,
    output wire                     s_axi_awready,
    input  wire [ADDR_WIDTH-1:0]    s_axi_awaddr,
    input  wire [ID_WIDTH-1:0]      s_axi_awid,
    input  wire [7:0]               s_axi_awlen,
    input  wire [2:0]               s_axi_awsize,
    input  wire [1:0]               s_axi_awburst,

    // AXI4 Write Data
    input  wire                     s_axi_wvalid,
    output wire                     s_axi_wready,
    input  wire [DATA_WIDTH-1:0]    s_axi_wdata,
    input  wire [DATA_WIDTH/8-1:0]  s_axi_wstrb,
    input  wire                     s_axi_wlast,

    // AXI4 Write Response
    output wire                     s_axi_bvalid,
    input  wire                     s_axi_bready,
    output wire [ID_WIDTH-1:0]      s_axi_bid,
    output wire [1:0]               s_axi_bresp,

    // AXI4 Read Address
    input  wire                     s_axi_arvalid,
    output wire                     s_axi_arready,
    input  wire [ADDR_WIDTH-1:0]    s_axi_araddr,
    input  wire [ID_WIDTH-1:0]      s_axi_arid,
    input  wire [7:0]               s_axi_arlen,
    input  wire [2:0]               s_axi_arsize,
    input  wire [2:0]               s_axi_arburst, // DiVo Gen²AI: unused but keep port

    // AXI4 Read Data
    output wire                     s_axi_rvalid,
    input  wire                     s_axi_rready,
    output wire [DATA_WIDTH-1:0]    s_axi_rdata,
    output wire [ID_WIDTH-1:0]      s_axi_rid,
    output wire [1:0]               s_axi_rresp,
    output wire                     s_axi_rlast,

    // Debug
    output wire [31:0]              debug_rd_count,
    output wire [31:0]              debug_wr_count
);

    localparam AXI_OKAY = 2'b00;

    // BRAM storage
    reg [DATA_WIDTH-1:0] mem [0:MEM_DEPTH-1];

    // Address translation: byte-address → word index
    localparam L2_DATA = $clog2(DATA_WIDTH/8);

    // ================================================================
    // Write path — H-4 fix: AW/W 独立锁存 + W 收齐后才发 B
    // ================================================================
    reg aw_latched;       // AW 已锁存
    reg w_received;       // W data 已收到
    reg [ADDR_WIDTH-1:0]  aw_addr_latch;
    reg [ID_WIDTH-1:0]    aw_id_latch;
    reg b_pending;        // B 响应待发
    reg [ID_WIDTH-1:0]    b_id_latch;

    wire aw_handshake = s_axi_awvalid && s_axi_awready;
    wire w_handshake  = s_axi_wvalid  && s_axi_wready;

    // AW 锁存: 空闲时接受 AW
    assign s_axi_awready = ~aw_latched;

    // W 锁存: AW 已锁存 或 AW 同拍到达时均可接受 W
    wire aw_arriving = s_axi_awvalid && s_axi_awready;
    assign s_axi_wready  = (aw_latched || aw_arriving) && ~w_received;

    always @(posedge clk) begin
        if (reset) begin
            aw_latched    <= 1'b0;
            w_received    <= 1'b0;
            b_pending     <= 1'b0;
            aw_addr_latch <= '0;
            aw_id_latch   <= '0;
            b_id_latch    <= '0;
        end else begin
            // 锁存 AW
            if (aw_handshake) begin
                aw_latched    <= 1'b1;
                aw_addr_latch <= s_axi_awaddr;
                aw_id_latch   <= s_axi_awid;
            end

            // 锁存 W — 写入 BRAM
            if (w_handshake) begin
                w_received <= 1'b1;
                // 写入地址: AW 已锁存用锁存值，同拍到达用当前值
                // DiVo Gen²AI: wstrb 部分写支持
                for (integer b = 0; b < DATA_WIDTH/8; b = b + 1) begin
                    if (s_axi_wstrb[b]) begin
                        if (aw_latched)
                            mem[$clog2(MEM_DEPTH)'(aw_addr_latch[ADDR_WIDTH-1:L2_DATA])][b*8 +: 8] <= s_axi_wdata[b*8 +: 8];
                        else
                            mem[$clog2(MEM_DEPTH)'(s_axi_awaddr[ADDR_WIDTH-1:L2_DATA])][b*8 +: 8] <= s_axi_wdata[b*8 +: 8];
                    end
                end
                // W 收齐 → 发 B
                b_pending  <= 1'b1;
                b_id_latch <= aw_latched ? aw_id_latch : s_axi_awid;
            end

            // B 握手完成 → 清除
            if (b_pending && s_axi_bready) begin
                b_pending  <= 1'b0;
                aw_latched <= 1'b0;
                w_received <= 1'b0;
            end
        end
    end

    assign s_axi_bvalid = b_pending;
    assign s_axi_bid    = b_id_latch;
    assign s_axi_bresp  = AXI_OKAY;

    // ================================================================
    // Read path — 锁存 AR addr/id，1 拍后出数据
    // ================================================================
    reg rd_pending;
    reg [ID_WIDTH-1:0]    rd_id;
    reg [ADDR_WIDTH-1:0]  rd_addr_latch;

    assign s_axi_arready = ~rd_pending;

    always @(posedge clk) begin
        if (reset) begin
            rd_pending    <= 1'b0;
            rd_id         <= '0;
            rd_addr_latch <= '0;
        end else begin
            if (s_axi_arvalid && s_axi_arready) begin
                rd_pending    <= 1'b1;
                rd_id         <= s_axi_arid;
                rd_addr_latch <= s_axi_araddr;
            end
            if (rd_pending && s_axi_rready) begin
                rd_pending <= 1'b0;
            end
        end
    end

    assign s_axi_rvalid = rd_pending;
    assign s_axi_rdata  = mem[$clog2(MEM_DEPTH)'(rd_addr_latch[ADDR_WIDTH-1:L2_DATA])];
    assign s_axi_rid    = rd_id;
    assign s_axi_rresp  = AXI_OKAY;
    assign s_axi_rlast  = 1'b1;

    // ================================================================
    // Debug counters
    // ================================================================
    reg [31:0] wr_count;
    reg [31:0] rd_count;

    always @(posedge clk) begin
        if (reset) begin
            wr_count <= 32'd0;
            rd_count <= 32'd0;
        end else begin
            if (w_handshake)
                wr_count <= wr_count + 32'd1;
            if (s_axi_arvalid && s_axi_arready)
                rd_count <= rd_count + 32'd1;
        end
    end

    assign debug_rd_count = rd_count;
    assign debug_wr_count = wr_count;

endmodule
