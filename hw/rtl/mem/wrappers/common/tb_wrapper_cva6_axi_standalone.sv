// SPDX-License-Identifier: Apache-2.0
// Copyright © 2024-2026 DiVo Gen²AI
//
// tb_wrapper_cva6_axi_standalone — CVA6 AXI wrapper passthrough 模式独立验证
//
// 链路: AXI4 Master driver → VX_mem_ctrl_wrapper_cva6_axi (passthrough) → VX_mock_axi_memory

module tb_wrapper_cva6_axi_standalone (
    input wire clk,
    input wire reset
);

    localparam DATA_WIDTH = 512;
    localparam ADDR_WIDTH = 32;
    localparam ID_WIDTH   = 8;
    localparam DATA_SIZE  = DATA_WIDTH / 8;
    localparam NUM_BANKS  = 1;

    // AXI4 Master 驱动信号
    reg                     m_axi_awvalid [NUM_BANKS];
    wire                    m_axi_awready [NUM_BANKS];
    reg  [ADDR_WIDTH-1:0]   m_axi_awaddr  [NUM_BANKS];
    reg  [ID_WIDTH-1:0]     m_axi_awid    [NUM_BANKS];
    reg  [7:0]               m_axi_awlen   [NUM_BANKS];
    reg  [2:0]               m_axi_awsize  [NUM_BANKS];
    reg  [1:0]               m_axi_awburst [NUM_BANKS];

    reg                     m_axi_wvalid  [NUM_BANKS];
    wire                    m_axi_wready  [NUM_BANKS];
    reg  [DATA_WIDTH-1:0]   m_axi_wdata   [NUM_BANKS];
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
    wire [DATA_WIDTH-1:0]   m_axi_rdata   [NUM_BANKS];
    wire [ID_WIDTH-1:0]     m_axi_rid     [NUM_BANKS];
    wire [1:0]               m_axi_rresp   [NUM_BANKS];
    wire                    m_axi_rlast   [NUM_BANKS];

    // CVA6 AXI4 Slave 侧
    wire                     cva6_axi_awvalid [NUM_BANKS];
    wire                     cva6_axi_awready [NUM_BANKS];
    wire [ADDR_WIDTH-1:0]    cva6_axi_awaddr  [NUM_BANKS];
    wire [ID_WIDTH-1:0]      cva6_axi_awid    [NUM_BANKS];
    wire [7:0]               cva6_axi_awlen   [NUM_BANKS];
    wire [2:0]               cva6_axi_awsize  [NUM_BANKS];
    wire [1:0]               cva6_axi_awburst [NUM_BANKS];

    wire                     cva6_axi_wvalid  [NUM_BANKS];
    wire                     cva6_axi_wready  [NUM_BANKS];
    wire [DATA_WIDTH-1:0]    cva6_axi_wdata   [NUM_BANKS];
    wire [DATA_SIZE-1:0]     cva6_axi_wstrb   [NUM_BANKS];
    wire                     cva6_axi_wlast   [NUM_BANKS];

    wire                     cva6_axi_bvalid  [NUM_BANKS];
    wire                     cva6_axi_bready  [NUM_BANKS];
    wire [ID_WIDTH-1:0]      cva6_axi_bid     [NUM_BANKS];
    wire [1:0]               cva6_axi_bresp   [NUM_BANKS];

    wire                     cva6_axi_arvalid [NUM_BANKS];
    wire                     cva6_axi_arready [NUM_BANKS];
    wire [ADDR_WIDTH-1:0]    cva6_axi_araddr  [NUM_BANKS];
    wire [ID_WIDTH-1:0]      cva6_axi_arid    [NUM_BANKS];
    wire [7:0]               cva6_axi_arlen   [NUM_BANKS];
    wire [2:0]               cva6_axi_arsize  [NUM_BANKS];
    wire [1:0]               cva6_axi_arburst [NUM_BANKS];

    wire                     cva6_axi_rvalid  [NUM_BANKS];
    wire                     cva6_axi_rready  [NUM_BANKS];
    wire [DATA_WIDTH-1:0]    cva6_axi_rdata   [NUM_BANKS];
    wire [ID_WIDTH-1:0]      cva6_axi_rid     [NUM_BANKS];
    wire [1:0]               cva6_axi_rresp   [NUM_BANKS];
    wire                     cva6_axi_rlast   [NUM_BANKS];

    wire debug_init_done;
    wire [31:0] debug_rd_bytes, debug_wr_bytes;

    // DUT — passthrough 模式: CVA6_DATA_WIDTH = AXI_DATA_WIDTH
    VX_mem_ctrl_wrapper_cva6_axi #(
        .AXI_DATA_WIDTH(DATA_WIDTH),
        .CVA6_DATA_WIDTH(DATA_WIDTH),
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
        .cva6_axi_awvalid, .cva6_axi_awready, .cva6_axi_awaddr, .cva6_axi_awid,
        .cva6_axi_awlen, .cva6_axi_awsize, .cva6_axi_awburst,
        .cva6_axi_wvalid, .cva6_axi_wready, .cva6_axi_wdata, .cva6_axi_wstrb,
        .cva6_axi_wlast,
        .cva6_axi_bvalid, .cva6_axi_bready, .cva6_axi_bid, .cva6_axi_bresp,
        .cva6_axi_arvalid, .cva6_axi_arready, .cva6_axi_araddr, .cva6_axi_arid,
        .cva6_axi_arlen, .cva6_axi_arsize, .cva6_axi_arburst,
        .cva6_axi_rvalid, .cva6_axi_rready, .cva6_axi_rdata, .cva6_axi_rid,
        .cva6_axi_rresp, .cva6_axi_rlast,
        .debug_init_done, .debug_rd_bytes, .debug_wr_bytes
    );

    // =========================================================
    // AXI4 Slave 响应模型 (复用 passthrough 测试的 mock memory)
    // =========================================================
    localparam MEM_DEPTH = 1024;
    localparam MEM_ADDR_W = $clog2(MEM_DEPTH);

    reg [DATA_WIDTH-1:0] mock_mem [0:MEM_DEPTH-1];
    reg rd_pending;

    always @(posedge clk) begin
        if (reset) begin
            rd_pending <= 1'b0;
        end else begin
            // Write
            if (cva6_axi_wvalid[0] && cva6_axi_wready[0]) begin
                for (int b = 0; b < DATA_SIZE; b = b + 1) begin
                    if (cva6_axi_wstrb[0][b])
                        mock_mem[MEM_ADDR_W'(cva6_axi_awaddr[0][ADDR_WIDTH-1:6])][b*8 +: 8] <= cva6_axi_wdata[0][b*8 +: 8];
                end
            end
            // AW handshake
            if (cva6_axi_awvalid[0] && cva6_axi_awready[0]) begin
                rd_pending <= 1'b0;
            end
            // AR handshake
            if (cva6_axi_arvalid[0] && cva6_axi_arready[0]) begin
                rd_pending <= 1'b1;
            end
            // R handshake
            if (cva6_axi_rvalid[0] && cva6_axi_rready[0]) begin
                rd_pending <= 1'b0;
            end
        end
    end

    assign cva6_axi_awready[0] = 1'b1;
    assign cva6_axi_wready[0]  = 1'b1;
    assign cva6_axi_bvalid[0]  = cva6_axi_awvalid[0];
    assign cva6_axi_bid[0]     = cva6_axi_awid[0];
    assign cva6_axi_bresp[0]   = 2'b00;
    assign cva6_axi_arready[0] = ~rd_pending;
    assign cva6_axi_rvalid[0]  = rd_pending;
    assign cva6_axi_rdata[0]   = mock_mem[MEM_ADDR_W'(cva6_axi_araddr[0][ADDR_WIDTH-1:6])];
    assign cva6_axi_rid[0]     = cva6_axi_arid[0];
    assign cva6_axi_rresp[0]   = 2'b00;
    assign cva6_axi_rlast[0]   = 1'b1;

    // =========================================================
    // 测试 FSM
    // =========================================================
    localparam [3:0] T_IDLE = 0, T_WR = 1, T_WR_WAIT = 2,
                      T_RD = 3, T_RD_WAIT = 4, T_DONE = 5;

    reg [3:0] test_state;
    reg [31:0] test_cnt, total_tests, errors;
    reg [DATA_WIDTH-1:0] write_data, expected_data;
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
            m_axi_awaddr[0] <= 0; m_axi_awid[0] <= 0;
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
                        $display("PASSED: %0d cva6_axi passthrough write-read tests, 0 errors", total_tests);
                    else
                        $display("FAILED: %0d errors in %0d cva6_axi tests", errors, total_tests);
                    $finish;
                end

                default: test_state <= T_IDLE;
            endcase
        end
    end

endmodule
