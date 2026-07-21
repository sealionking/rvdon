// SPDX-License-Identifier: Apache-2.0
// Copyright © 2024-2026 DiVo Gen²AI — 王掬琅（Peter Wang）· 王潇奕（Shawn Wang）
//
// VX_mem_ctrl_wrapper_ddr3ctrl — ultraembedded DDR3 控制器适配器 (模式B: 宽度适配)
//
// 适配 ultraembedded/core_ddr3_controller (MIT)
// DDR3 控制器接口: 简单的 cmd/wdata/rdata 握手协议
//   cmd + cmd_stb → cmd_rdy
//   wdata + wmask + wstb → wrdy  
//   rdata + rvalid → rrdy
//
// 与 Vortex 512-bit AXI4 的适配:
//   - 宽度: 512-bit → 128-bit DDR3 (4 beat 拆分)
//   - 协议: AXI4 → 简单 cmd/data 握手
//
// 参考: https://github.com/ultraembedded/core_ddr3_controller
// 许可: Apache-2.0 (wrapper) | core_ddr3_controller: MIT

module VX_mem_ctrl_wrapper_ddr3ctrl #(
    parameter AXI_DATA_WIDTH  = 512,
    parameter DDR_DATA_WIDTH  = 128,     // DDR3 控制器数据宽度
    parameter ADDR_WIDTH      = 32,      // byte-addressable
    parameter DDR_ADDR_WIDTH  = 28,      // DDR3 字地址
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

    // === DDR3 控制器接口 (ultraembedded 协议) ===
    output wire                     ddr_cmd_valid [NUM_BANKS],
    input  wire                     ddr_cmd_ready [NUM_BANKS],
    output wire [DDR_ADDR_WIDTH-1:0] ddr_cmd_addr [NUM_BANKS],
    output wire                     ddr_cmd_we    [NUM_BANKS],

    output wire                     ddr_wr_valid  [NUM_BANKS],
    input  wire                     ddr_wr_ready  [NUM_BANKS],
    output wire [DDR_DATA_WIDTH-1:0] ddr_wr_data  [NUM_BANKS],
    output wire [DDR_DATA_WIDTH/8-1:0] ddr_wr_mask[NUM_BANKS],

    input  wire                     ddr_rd_valid  [NUM_BANKS],
    output wire                     ddr_rd_ready  [NUM_BANKS],
    input  wire [DDR_DATA_WIDTH-1:0] ddr_rd_data  [NUM_BANKS],

    // === 调试 ===
    output wire                     debug_init_done,
    output wire [31:0]              debug_rd_bytes,
    output wire [31:0]              debug_wr_bytes
);

    localparam BEATS_PER_AXI = AXI_DATA_WIDTH / DDR_DATA_WIDTH;
    localparam BEAT_BITS     = $clog2(BEATS_PER_AXI);
    localparam DDR_BYTES     = DDR_DATA_WIDTH / 8;
    localparam L2_DDR_BYTES  = $clog2(DDR_BYTES);
    localparam WORD_ADDR_W   = DDR_ADDR_WIDTH + L2_DDR_BYTES;

    genvar bank;
    generate
        for (bank = 0; bank < NUM_BANKS; bank = bank + 1) begin : g_bank

            reg [2:0] state;
            reg [BEAT_BITS-1:0] beat_cnt;
            reg [ID_WIDTH-1:0] id_hold;
            reg [AXI_DATA_WIDTH-1:0] wr_data_hold;
            reg [AXI_DATA_WIDTH/8-1:0] wr_strb_hold;
            reg [AXI_DATA_WIDTH-1:0] rd_data_hold;

            // Local states
            localparam [2:0] S_IDLE     = 3'd0,
                             S_WR_CMD   = 3'd1,
                             S_WR_DATA  = 3'd2,
                             S_WR_DONE  = 3'd3,
                             S_RD_CMD   = 3'd4,
                             S_RD_DATA  = 3'd5,
                             S_RD_RESP  = 3'd6,
                             S_RD_DONE  = 3'd7;

            // DDR3 驱动
            reg ddr_cmd_valid_r, ddr_wr_valid_r, ddr_rd_ready_r;
            reg [DDR_ADDR_WIDTH-1:0] ddr_cmd_addr_r;
            reg ddr_cmd_we_r;

            // AXI 响应
            reg axi_bvalid_r, axi_rvalid_r;
            reg [AXI_DATA_WIDTH-1:0] axi_rdata_r;

            assign ddr_cmd_valid[bank] = ddr_cmd_valid_r;
            assign ddr_cmd_addr[bank]  = ddr_cmd_addr_r;
            assign ddr_cmd_we[bank]    = ddr_cmd_we_r;
            assign ddr_wr_valid[bank]  = ddr_wr_valid_r;
            assign ddr_wr_data[bank]   = wr_data_hold[beat_cnt * DDR_DATA_WIDTH +: DDR_DATA_WIDTH];
            assign ddr_wr_mask[bank]   = ~wr_strb_hold[beat_cnt * DDR_BYTES +: DDR_BYTES]; // inverted: 1=mask(don't write)
            assign ddr_rd_ready[bank]  = ddr_rd_ready_r;

            assign m_axi_bvalid[bank] = axi_bvalid_r;
            assign m_axi_bid[bank]    = id_hold;
            assign m_axi_bresp[bank]  = 2'b00;
            assign m_axi_rvalid[bank] = axi_rvalid_r;
            assign m_axi_rdata[bank]  = axi_rdata_r;
            assign m_axi_rid[bank]    = id_hold;
            assign m_axi_rresp[bank]  = 2'b00;
            assign m_axi_rlast[bank]  = 1'b1;

            always @(posedge clk) begin
                if (reset) begin
                    state           <= S_IDLE;
                    beat_cnt        <= '0;
                    ddr_cmd_valid_r <= 1'b0;
                    ddr_wr_valid_r  <= 1'b0;
                    ddr_rd_ready_r  <= 1'b0;
                    axi_bvalid_r    <= 1'b0;
                    axi_rvalid_r    <= 1'b0;
                end else begin
                    case (state)
                        S_IDLE: begin
                            ddr_cmd_valid_r <= 1'b0;
                            ddr_wr_valid_r  <= 1'b0;
                            ddr_rd_ready_r  <= 1'b0;
                            axi_bvalid_r    <= 1'b0;
                            axi_rvalid_r    <= 1'b0;

                            // 写优先
                            if (m_axi_awvalid[bank] && m_axi_wvalid[bank]) begin
                                wr_data_hold  <= m_axi_wdata[bank];
                                wr_strb_hold  <= m_axi_wstrb[bank];
                                id_hold       <= m_axi_awid[bank];
                                beat_cnt      <= '0;

                                ddr_cmd_addr_r <= m_axi_awaddr[bank][ADDR_WIDTH-1:L2_DDR_BYTES];
                                ddr_cmd_we_r   <= 1'b1;
                                ddr_cmd_valid_r<= 1'b1;
                                state          <= S_WR_CMD;
                            end
                            else if (m_axi_arvalid[bank]) begin
                                id_hold        <= m_axi_arid[bank];
                                beat_cnt       <= '0;
                                rd_data_hold   <= '0;

                                ddr_cmd_addr_r <= m_axi_araddr[bank][ADDR_WIDTH-1:L2_DDR_BYTES];
                                ddr_cmd_we_r   <= 1'b0;
                                ddr_cmd_valid_r<= 1'b1;
                                state          <= S_RD_CMD;
                            end
                        end

                        S_WR_CMD: begin
                            if (ddr_cmd_ready[bank]) begin
                                ddr_cmd_valid_r <= 1'b0;
                                ddr_wr_valid_r  <= 1'b1;
                                beat_cnt        <= '0;
                                state           <= S_WR_DATA;
                            end
                        end

                        S_WR_DATA: begin
                            if (ddr_wr_ready[bank]) begin
                                beat_cnt <= beat_cnt + 1'b1;
                                if (beat_cnt == BEAT_BITS'(BEATS_PER_AXI - 1)) begin
                                    ddr_wr_valid_r <= 1'b0;
                                    axi_bvalid_r   <= 1'b1;
                                    state <= S_WR_DONE;
                                end
                            end
                        end

                        S_WR_DONE: begin
                            if (m_axi_bready[bank]) begin
                                axi_bvalid_r <= 1'b0;
                                state <= S_IDLE;
                            end
                        end

                        S_RD_CMD: begin
                            if (ddr_cmd_ready[bank]) begin
                                ddr_cmd_valid_r <= 1'b0;
                                ddr_rd_ready_r  <= 1'b1;
                                beat_cnt        <= '0;
                                state           <= S_RD_DATA;
                            end
                        end

                        S_RD_DATA: begin
                            if (ddr_rd_valid[bank] && ddr_rd_ready_r) begin
                                rd_data_hold[beat_cnt * DDR_DATA_WIDTH +: DDR_DATA_WIDTH] <= ddr_rd_data[bank];
                                beat_cnt <= beat_cnt + 1'b1;
                                if (beat_cnt == BEAT_BITS'(BEATS_PER_AXI - 1)) begin
                                    ddr_rd_ready_r <= 1'b0;
                                    state <= S_RD_RESP; // DiVo Gen²AI: delay 1 cycle for rd_data_hold NBA update
                                end
                            end
                        end

                        S_RD_RESP: begin
                            // rd_data_hold now has all beats (NBA from S_RD_DATA took effect)
                            axi_rdata_r  <= rd_data_hold;
                            axi_rvalid_r <= 1'b1;
                            state <= S_RD_DONE;
                        end

                        S_RD_DONE: begin
                            if (m_axi_rready[bank]) begin
                                axi_rvalid_r <= 1'b0;
                                state <= S_IDLE;
                            end
                        end

                        default: state <= S_IDLE;
                    endcase
                end
            end

            assign m_axi_awready[bank] = (state == S_IDLE) && !m_axi_arvalid[bank];
            assign m_axi_wready [bank] = (state == S_IDLE);
            assign m_axi_arready[bank] = (state == S_IDLE) && !m_axi_awvalid[bank];

        end
    endgenerate

    assign debug_init_done = 1'b1;
    assign debug_rd_bytes  = 32'd0;
    assign debug_wr_bytes  = 32'd0;

endmodule
