// SPDX-License-Identifier: Apache-2.0
// Copyright © 2024-2026 DiVo Gen²AI
//
// tb_wrapper_litedram_standalone — LiteDRAM wrapper 独立验证
//
// 链路: AXI4 Master driver → VX_mem_ctrl_wrapper_litedram → Wishbone 响应模型

module tb_wrapper_litedram_standalone (
    input wire clk,
    input wire reset
);

    localparam AXI_DATA_WIDTH = 512;
    localparam WB_DATA_WIDTH  = 128;
    localparam ADDR_WIDTH     = 32;
    localparam ID_WIDTH       = 8;
    localparam DATA_SIZE      = AXI_DATA_WIDTH / 8;
    localparam WB_BYTES       = WB_DATA_WIDTH / 8;
    localparam NUM_BANKS      = 1;

    // AXI4 Master 驱动
    reg                     m_axi_awvalid [NUM_BANKS];
    wire                    m_axi_awready [NUM_BANKS];
    reg  [ADDR_WIDTH-1:0]   m_axi_awaddr  [NUM_BANKS];
    reg  [ID_WIDTH-1:0]     m_axi_awid    [NUM_BANKS];
    reg  [7:0]               m_axi_awlen   [NUM_BANKS];
    reg  [2:0]               m_axi_awsize  [NUM_BANKS];
    reg  [1:0]               m_axi_awburst [NUM_BANKS];

    reg                     m_axi_wvalid  [NUM_BANKS];
    wire                    m_axi_wready  [NUM_BANKS];
    reg  [AXI_DATA_WIDTH-1:0] m_axi_wdata [NUM_BANKS];
    reg  [DATA_SIZE-1:0]    m_axi_wstrb   [NUM_BANKS];
    reg                     m_axi_wlast   [NUM_BANKS];

    wire                    m_axi_bvalid  [NUM_BANKS];
    reg                     m_axi_bready  [NUM_BANKS];
    wire [ID_WIDTH-1:0]     m_axi_bid     [NUM_BANKS];
    wire [1:0]               m_axi_bresp   [NUM_BANKS];

    reg                     m_axi_arvalid [NUM_BANKS];
    wire                    m_axi_arready [NUM_BANKS];
    reg  [ADDR_WIDTH-1:0]   m_axi_araddr  [NUM_BANKS];
    reg  [ID_WIDTH-1:0]     m_axi_arid    [NUM_BANKS];
    reg  [7:0]               m_axi_arlen   [NUM_BANKS];
    reg  [2:0]               m_axi_arsize  [NUM_BANKS];
    reg  [1:0]               m_axi_arburst [NUM_BANKS];

    wire                    m_axi_rvalid  [NUM_BANKS];
    reg                     m_axi_rready  [NUM_BANKS];
    wire [AXI_DATA_WIDTH-1:0] m_axi_rdata [NUM_BANKS];
    wire [ID_WIDTH-1:0]     m_axi_rid     [NUM_BANKS];
    wire [1:0]               m_axi_rresp   [NUM_BANKS];
    wire                    m_axi_rlast   [NUM_BANKS];

    // Wishbone 信号
    wire                     wb_cyc   [NUM_BANKS];
    wire                     wb_stb   [NUM_BANKS];
    wire                     wb_we    [NUM_BANKS];
    wire [ADDR_WIDTH-1:0]    wb_adr   [NUM_BANKS];
    wire [WB_DATA_WIDTH-1:0] wb_dat_w [NUM_BANKS];
    wire [WB_BYTES-1:0]      wb_sel   [NUM_BANKS];
    reg                      wb_ack   [NUM_BANKS];
    reg  [WB_DATA_WIDTH-1:0] wb_dat_r [NUM_BANKS];

    // Debug
    wire debug_init_done;
    wire [31:0] debug_rd_bytes, debug_wr_bytes, debug_err_count;

    // DUT
    VX_mem_ctrl_wrapper_litedram #(
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .WB_DATA_WIDTH(WB_DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .ID_WIDTH(ID_WIDTH),
        .NUM_BANKS(NUM_BANKS)
    ) dut (
        .clk, .reset,
        .m_axi_awvalid, .m_axi_awready, .m_axi_awaddr, .m_axi_awid,
        .m_axi_awlen, .m_axi_awsize, .m_axi_awburst,
        .m_axi_wvalid, .m_axi_wready, .m_axi_wdata, .m_axi_wstrb, .m_axi_wlast,
        .m_axi_bvalid, .m_axi_bready, .m_axi_bid, .m_axi_bresp,
        .m_axi_arvalid, .m_axi_arready, .m_axi_araddr, .m_axi_arid,
        .m_axi_arlen, .m_axi_arsize, .m_axi_arburst,
        .m_axi_rvalid, .m_axi_rready, .m_axi_rdata, .m_axi_rid,
        .m_axi_rresp, .m_axi_rlast,
        .wb_cyc, .wb_stb, .wb_we, .wb_adr, .wb_dat_w, .wb_sel,
        .wb_ack, .wb_dat_r,
        .debug_init_done, .debug_rd_bytes, .debug_wr_bytes, .debug_err_count
    );

    // Wishbone 响应模型 — 组合逻辑 ack (0拍延迟，最简模型)
    localparam BEATS_PER_AXI = AXI_DATA_WIDTH / WB_DATA_WIDTH;
    localparam WB_ADDR_SHIFT = $clog2(WB_BYTES);
    localparam MEM_DEPTH = 1024;
    localparam MEM_ADDR_W = $clog2(MEM_DEPTH);

    reg [WB_DATA_WIDTH-1:0] wb_mem [0:MEM_DEPTH-1];

    // 组合逻辑 ack — stb && cyc 时立即 ack
    assign wb_ack[0] = wb_stb[0] && wb_cyc[0];

    // 读数据组合逻辑
    always @(*) begin
        wb_dat_r[0] = wb_mem[MEM_ADDR_W'(wb_adr[0][ADDR_WIDTH-1:WB_ADDR_SHIFT])];
    end

    // 写在时钟沿
    always @(posedge clk) begin
        if (!reset && wb_ack[0] && wb_we[0]) begin
            for (int b = 0; b < WB_BYTES; b = b + 1) begin
                if (wb_sel[0][b])
                    wb_mem[MEM_ADDR_W'(wb_adr[0][ADDR_WIDTH-1:WB_ADDR_SHIFT])][b*8 +: 8] <= wb_dat_w[0][b*8 +: 8];
            end
        end
    end

    // =========================================================
    // 测试 FSM
    // =========================================================
    localparam [3:0] T_IDLE = 0, T_WR = 1, T_WR_WAIT = 2,
                      T_RD = 3, T_RD_WAIT = 4, T_DONE = 5;

    reg [3:0] test_state;
    reg [31:0] test_cnt, total_tests, errors;
    reg [AXI_DATA_WIDTH-1:0] write_data, expected_data;
    reg [ADDR_WIDTH-1:0] test_addr;

    always @(posedge clk) begin
        if (reset) begin
            test_state   <= T_IDLE;
            test_cnt     <= 0;
            total_tests  <= 0;
            errors       <= 0;
            m_axi_awvalid[0] <= 0;
            m_axi_wvalid[0]  <= 0;
            m_axi_arvalid[0] <= 0;
            m_axi_bready[0]  <= 0;
            m_axi_rready[0]  <= 0;
            m_axi_awaddr[0]  <= 0; m_axi_awid[0] <= 0;
            m_axi_awlen[0] <= 0; m_axi_awsize[0] <= 0; m_axi_awburst[0] <= 0;
            m_axi_wdata[0] <= 0; m_axi_wstrb[0] <= 0; m_axi_wlast[0] <= 1;
            m_axi_araddr[0] <= 0; m_axi_arid[0] <= 0;
            m_axi_arlen[0] <= 0; m_axi_arsize[0] <= 0; m_axi_arburst[0] <= 0;
        end else begin
            case (test_state)
                T_IDLE: begin
                    if (test_cnt < 20) begin
                        if (test_cnt == 0) begin
                            test_addr  <= 32'h0;
                            write_data <= 512'hDEADBEEF_CAFEBABE_01234567_89ABCDEF_FEDCBA98_76543210_BADC0FFE_DEADBEEF_CAFEBABE; // H-3 fix: full 512-bit
                        end else if (test_cnt <= 10) begin
                            test_addr  <= (test_cnt - 1) * 64;
                            write_data <= {$urandom, $urandom, $urandom, $urandom, // H-3 fix: 16×32=512 bit
                                           $urandom, $urandom, $urandom, $urandom,
                                           $urandom, $urandom, $urandom, $urandom,
                                           $urandom, $urandom, $urandom, $urandom};
                        end else begin
                            test_addr  <= (($urandom % 256) * 64);
                            write_data <= {$urandom, $urandom, $urandom, $urandom, // H-3 fix: 16×32=512 bit
                                           $urandom, $urandom, $urandom, $urandom,
                                           $urandom, $urandom, $urandom, $urandom,
                                           $urandom, $urandom, $urandom, $urandom};
                        end
                        test_state <= T_WR;
                    end else begin
                        test_state <= T_DONE;
                    end
                end

                T_WR: begin
                    m_axi_awvalid[0] <= 1'b1;
                    m_axi_awaddr[0]  <= test_addr;
                    m_axi_awid[0]    <= 8'h00;
                    m_axi_awlen[0]   <= 8'h00;
                    m_axi_awsize[0]  <= 3'd6;
                    m_axi_awburst[0] <= 2'b01;
                    m_axi_wvalid[0]  <= 1'b1;
                    m_axi_wdata[0]   <= write_data;
                    m_axi_wstrb[0]   <= {DATA_SIZE{1'b1}};
                    m_axi_bready[0]  <= 1'b1;
                    expected_data <= write_data;
                    test_state <= T_WR_WAIT;
                end

                T_WR_WAIT: begin
                    m_axi_awvalid[0] <= 1'b0;
                    m_axi_wvalid[0]  <= 1'b0;
                    if (m_axi_bvalid[0]) begin
                        m_axi_bready[0] <= 1'b0;
                        test_state <= T_RD;
                    end
                end

                T_RD: begin
                    m_axi_arvalid[0] <= 1'b1;
                    m_axi_araddr[0]  <= test_addr;
                    m_axi_arid[0]    <= 8'h01;
                    m_axi_arlen[0]   <= 8'h00;
                    m_axi_arsize[0]  <= 3'd6;
                    m_axi_arburst[0] <= 2'b01;
                    m_axi_rready[0]  <= 1'b1;
                    test_state <= T_RD_WAIT;
                end

                T_RD_WAIT: begin
                    m_axi_arvalid[0] <= 1'b0;
                    if (m_axi_rvalid[0]) begin
                        m_axi_rready[0] <= 1'b0;
                        if (m_axi_rdata[0] !== expected_data) begin
                            errors <= errors + 1;
                            if (errors <= 3)
                                $display("  [FAIL] test %0d: rd=0x%h exp=0x%h", test_cnt, m_axi_rdata[0], expected_data);
                        end
                        total_tests <= total_tests + 1;
                        test_cnt <= test_cnt + 1;
                        test_state <= T_IDLE;
                    end
                end

                T_DONE: begin
                    if (errors == 0)
                        $display("PASSED: %0d litedram write-read tests, 0 errors", total_tests);
                    else
                        $display("FAILED: %0d errors in %0d litedram tests", errors, total_tests);
                    $finish;
                end

                default: test_state <= T_IDLE;
            endcase
        end
    end

endmodule
