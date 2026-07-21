// SPDX-License-Identifier: Apache-2.0
// Copyright © 2024-2026 DiVo Gen²AI — 王掬琅（Peter Wang）· 王潇奕（Shawn Wang）
//
// VX_mem_ctrl_wrapper_litedram — LiteDRAM 适配器 (模式B: 宽度适配)
//
// LiteDRAM 使用 Wishbone B4 总线，与 Vortex 的 AXI4 不兼容。
// 本 wrapper 实现 Wishbone→AXI4 双向转换。
//
// LiteDRAM 典型配置:
//   - Wishbone B4: 128-bit 或 256-bit 数据
//   - Vortex AXI4: 通常 512-bit
//   - 宽度适配: 512→256 (或 512→128) 拆分/拼合
//
// 参考: https://github.com/enjoy-digital/litedram
// 许可: Apache-2.0 (wrapper) | LiteDRAM: BSD/MIT

module VX_mem_ctrl_wrapper_litedram #(
    parameter AXI_DATA_WIDTH  = 512,     // Vortex AXI4 数据宽度
    parameter WB_DATA_WIDTH   = 128,     // LiteDRAM Wishbone 数据宽度
    parameter ADDR_WIDTH      = 32,      // byte-addressable
    parameter ID_WIDTH        = 8,
    parameter NUM_BANKS       = 1
) (
    input  wire clk,
    input  wire reset,

    // === AXI4 Master (来自 VX_mem_axi_bridge) ===
    // 标准 AXI4 5通道 (AW/W/B/AR/R)
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

    // === LiteDRAM Wishbone (连接到 LiteDRAM 控制器) ===
    output wire                     wb_cyc   [NUM_BANKS],
    output wire                     wb_stb   [NUM_BANKS],
    output wire                     wb_we    [NUM_BANKS],
    output wire [ADDR_WIDTH-1:0]    wb_adr   [NUM_BANKS],
    output wire [WB_DATA_WIDTH-1:0] wb_dat_w [NUM_BANKS],
    output wire [WB_DATA_WIDTH/8-1:0] wb_sel [NUM_BANKS],
    input  wire                     wb_ack   [NUM_BANKS],
    input  wire [WB_DATA_WIDTH-1:0] wb_dat_r [NUM_BANKS],

    // === 调试 ===
    output wire                     debug_init_done,
    output wire [31:0]              debug_rd_bytes,
    output wire [31:0]              debug_wr_bytes,
    output wire [31:0]              debug_err_count
);

    localparam BEATS_PER_AXI = AXI_DATA_WIDTH / WB_DATA_WIDTH;
    localparam BEAT_BITS     = $clog2(BEATS_PER_AXI);
    localparam WB_BYTES      = WB_DATA_WIDTH / 8;

    // 状态机
    localparam [2:0] S_IDLE     = 3'd0,
                     S_WR_DATA  = 3'd1,
                     S_WR_ACK   = 3'd2,
                     S_RD_DATA  = 3'd3,
                     S_RD_RESP  = 3'd4,  // DiVo Gen²AI: H-2 fix — 延迟1拍等 rd_data_hold NBA 生效
                     S_RD_WAIT  = 3'd5;

    genvar bank;
    generate
        for (bank = 0; bank < NUM_BANKS; bank = bank + 1) begin : g_bank

            reg [2:0] state;
            reg [BEAT_BITS-1:0] beat_cnt;
            reg [ADDR_WIDTH-1:0] addr_hold;
            reg [ID_WIDTH-1:0] id_hold;
            reg [AXI_DATA_WIDTH-1:0] wr_data_hold;
            reg [AXI_DATA_WIDTH/8-1:0] wr_strb_hold;
            reg [AXI_DATA_WIDTH-1:0] rd_data_hold;
            reg rw_hold; // 0=read, 1=write

            // Wishbone drive signals
            reg wb_cyc_r, wb_stb_r, wb_we_r;
            reg [ADDR_WIDTH-1:0] wb_adr_r;
            reg [WB_DATA_WIDTH-1:0] wb_dat_w_r;
            reg [WB_DATA_WIDTH/8-1:0] wb_sel_r;

            // AXI response signals
            reg axi_bvalid_r;
            reg axi_rvalid_r;
            reg [AXI_DATA_WIDTH-1:0] axi_rdata_r;
            reg [ID_WIDTH-1:0] axi_rid_r;

            assign wb_cyc[bank]   = wb_cyc_r;
            assign wb_stb[bank]   = wb_stb_r;
            assign wb_we[bank]    = wb_we_r;
            assign wb_adr[bank]   = wb_adr_r;
            assign wb_dat_w[bank] = wb_dat_w_r;
            assign wb_sel[bank]   = wb_sel_r;

            assign m_axi_bvalid[bank] = axi_bvalid_r;
            assign m_axi_bid[bank]    = id_hold;
            assign m_axi_bresp[bank]  = 2'b00;

            assign m_axi_rvalid[bank] = axi_rvalid_r;
            assign m_axi_rdata[bank]  = axi_rdata_r;
            assign m_axi_rid[bank]    = axi_rid_r;
            assign m_axi_rresp[bank]  = 2'b00;
            assign m_axi_rlast[bank]  = 1'b1;

            always @(posedge clk) begin
                if (reset) begin
                    state     <= S_IDLE;
                    beat_cnt  <= '0;
                    wb_cyc_r  <= 1'b0;
                    wb_stb_r  <= 1'b0;
                    axi_bvalid_r <= 1'b0;
                    axi_rvalid_r <= 1'b0;
                end else begin
                    case (state)
                        S_IDLE: begin
                            axi_bvalid_r <= 1'b0;
                            axi_rvalid_r <= 1'b0;
                            wb_cyc_r  <= 1'b0;
                            wb_stb_r  <= 1'b0;

                            // 优先处理写请求
                            if (m_axi_awvalid[bank] && m_axi_wvalid[bank]) begin
                                addr_hold    <= m_axi_awaddr[bank];
                                id_hold      <= m_axi_awid[bank];
                                wr_data_hold <= m_axi_wdata[bank];
                                wr_strb_hold <= m_axi_wstrb[bank];
                                rw_hold      <= 1'b1;
                                beat_cnt     <= '0;

                                // 发送第一个 beat
                                wb_adr_r   <= m_axi_awaddr[bank];
                                wb_dat_w_r <= m_axi_wdata[bank][WB_DATA_WIDTH-1:0];
                                wb_sel_r   <= m_axi_wstrb[bank][WB_BYTES-1:0];
                                wb_we_r    <= 1'b1;
                                wb_cyc_r   <= 1'b1;
                                wb_stb_r   <= 1'b1;
                                state      <= S_WR_DATA;
                            end
                            // 读请求
                            else if (m_axi_arvalid[bank]) begin
                                addr_hold  <= m_axi_araddr[bank];
                                id_hold    <= m_axi_arid[bank];
                                rw_hold    <= 1'b0;
                                beat_cnt   <= '0;
                                rd_data_hold <= '0;

                                // 发送第一个读 beat
                                wb_adr_r <= m_axi_araddr[bank];
                                wb_we_r  <= 1'b0;
                                wb_cyc_r <= 1'b1;
                                wb_stb_r <= 1'b1;
                                state    <= S_RD_DATA;
                            end
                        end

                        S_WR_DATA: begin
                            if (wb_ack[bank]) begin
                                beat_cnt <= beat_cnt + 1'b1;

                                if (beat_cnt == BEAT_BITS'(BEATS_PER_AXI - 2)) begin
                                    // 最后一个 beat (beat N-1)
                                    wb_adr_r   <= addr_hold + (beat_cnt + 1) * WB_BYTES; // DiVo Gen²AI: H-1 fix — 地址必须更新
                                    wb_dat_w_r <= wr_data_hold[(beat_cnt+1)*WB_DATA_WIDTH +: WB_DATA_WIDTH];
                                    wb_sel_r   <= wr_strb_hold[(beat_cnt+1)*WB_BYTES +: WB_BYTES];
                                    wb_stb_r   <= 1'b1;
                                    state      <= S_WR_ACK;
                                end else begin
                                    // 中间 beat (beat 1..N-2)
                                    wb_adr_r   <= addr_hold + (beat_cnt + 1) * WB_BYTES;
                                    wb_dat_w_r <= wr_data_hold[(beat_cnt+1)*WB_DATA_WIDTH +: WB_DATA_WIDTH];
                                    wb_sel_r   <= wr_strb_hold[(beat_cnt+1)*WB_BYTES +: WB_BYTES];
                                end
                            end
                        end

                        S_WR_ACK: begin
                            if (wb_ack[bank]) begin
                                wb_cyc_r  <= 1'b0;
                                wb_stb_r  <= 1'b0;
                                axi_bvalid_r <= 1'b1;
                                state <= S_IDLE;
                            end
                        end

                        S_RD_DATA: begin
                            if (wb_ack[bank]) begin
                                // 锁存读数据
                                rd_data_hold[beat_cnt * WB_DATA_WIDTH +: WB_DATA_WIDTH] <= wb_dat_r[bank];
                                beat_cnt <= beat_cnt + 1'b1;

                                if (beat_cnt == BEAT_BITS'(BEATS_PER_AXI - 1)) begin
                                    // 所有 beat 收齐 — 但 rd_data_hold 的 NBA 还没生效
                                    wb_cyc_r <= 1'b0;
                                    wb_stb_r <= 1'b0;
                                    state <= S_RD_RESP;  // DiVo Gen²AI: H-2 fix — 延迟1拍再锁存
                                end else begin
                                    // 继续读下一个 beat
                                    wb_adr_r <= addr_hold + (beat_cnt + 1) * WB_BYTES;
                                end
                            end
                        end

                        S_RD_RESP: begin
                            // rd_data_hold 的 NBA 已生效，可以安全锁存
                            axi_rdata_r  <= rd_data_hold;
                            axi_rid_r    <= id_hold;
                            axi_rvalid_r <= 1'b1;
                            state <= S_RD_WAIT;
                        end

                        S_RD_WAIT: begin
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
    assign debug_err_count = 32'd0;
    assign debug_rd_bytes  = 32'd0;
    assign debug_wr_bytes  = 32'd0;

endmodule
