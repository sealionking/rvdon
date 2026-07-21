// SPDX-License-Identifier: Apache-2.0
// Copyright © 2024-2026 DiVo Gen²AI
//
// tb_wrapper_passthrough_standalone — passthrough wrapper 独立验证
//
// 链路: AXI4 Master driver → VX_mem_ctrl_wrapper_passthrough → VX_mock_axi_memory
// 时钟和复位由 C++ main 驱动，不使用 #delay / @(posedge clk)

module tb_wrapper_passthrough_standalone (
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

    // s_axi_ 信号
    wire                     s_axi_awvalid [NUM_BANKS];
    wire                     s_axi_awready [NUM_BANKS];
    wire [ADDR_WIDTH-1:0]    s_axi_awaddr  [NUM_BANKS];
    wire [ID_WIDTH-1:0]      s_axi_awid    [NUM_BANKS];
    wire [7:0]                s_axi_awlen   [NUM_BANKS];
    wire [2:0]                s_axi_awsize  [NUM_BANKS];
    wire [1:0]                s_axi_awburst [NUM_BANKS];

    wire                     s_axi_wvalid  [NUM_BANKS];
    wire                     s_axi_wready  [NUM_BANKS];
    wire [DATA_WIDTH-1:0]    s_axi_wdata   [NUM_BANKS];
    wire [DATA_SIZE-1:0]     s_axi_wstrb   [NUM_BANKS];
    wire                     s_axi_wlast   [NUM_BANKS];

    wire                     s_axi_bvalid  [NUM_BANKS];
    wire                     s_axi_bready  [NUM_BANKS];
    wire [ID_WIDTH-1:0]      s_axi_bid     [NUM_BANKS];
    wire [1:0]                s_axi_bresp   [NUM_BANKS];

    wire                     s_axi_arvalid [NUM_BANKS];
    wire                     s_axi_arready [NUM_BANKS];
    wire [ADDR_WIDTH-1:0]    s_axi_araddr  [NUM_BANKS];
    wire [ID_WIDTH-1:0]      s_axi_arid    [NUM_BANKS];
    wire [7:0]                s_axi_arlen   [NUM_BANKS];
    wire [2:0]                s_axi_arsize  [NUM_BANKS];
    wire [1:0]                s_axi_arburst [NUM_BANKS];

    wire                     s_axi_rvalid  [NUM_BANKS];
    wire                     s_axi_rready  [NUM_BANKS];
    wire [DATA_WIDTH-1:0]    s_axi_rdata   [NUM_BANKS];
    wire [ID_WIDTH-1:0]      s_axi_rid     [NUM_BANKS];
    wire [1:0]                s_axi_rresp   [NUM_BANKS];
    wire                     s_axi_rlast   [NUM_BANKS];

    wire debug_init_done;
    wire [31:0] debug_rd_bytes, debug_wr_bytes;

    // DUT
    VX_mem_ctrl_wrapper_passthrough #(
        .AXI_DATA_WIDTH(DATA_WIDTH),
        .AXI_ADDR_WIDTH(ADDR_WIDTH),
        .AXI_ID_WIDTH(ID_WIDTH),
        .NUM_BANKS(NUM_BANKS),
        .MC_NAME("test")
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
        .s_axi_awvalid, .s_axi_awready, .s_axi_awaddr, .s_axi_awid,
        .s_axi_awlen, .s_axi_awsize, .s_axi_awburst,
        .s_axi_wvalid, .s_axi_wready, .s_axi_wdata, .s_axi_wstrb, .s_axi_wlast,
        .s_axi_bvalid, .s_axi_bready, .s_axi_bid, .s_axi_bresp,
        .s_axi_arvalid, .s_axi_arready, .s_axi_araddr, .s_axi_arid,
        .s_axi_arlen, .s_axi_arsize, .s_axi_arburst,
        .s_axi_rvalid, .s_axi_rready, .s_axi_rdata, .s_axi_rid,
        .s_axi_rresp, .s_axi_rlast,
        .debug_init_done, .debug_rd_bytes(debug_rd_bytes), .debug_wr_bytes(debug_wr_bytes)
    );

    // Mock memory
    wire [31:0] mock_rd, mock_wr;
    VX_mock_axi_memory #(
        .DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(ADDR_WIDTH),
        .ID_WIDTH(ID_WIDTH), .MEM_DEPTH(1024)
    ) mock_mem (
        .clk, .reset,
        .s_axi_awvalid(s_axi_awvalid[0]), .s_axi_awready(s_axi_awready[0]),
        .s_axi_awaddr(s_axi_awaddr[0]),   .s_axi_awid(s_axi_awid[0]),
        .s_axi_awlen(s_axi_awlen[0]),     .s_axi_awsize(s_axi_awsize[0]),
        .s_axi_awburst(s_axi_awburst[0]),
        .s_axi_wvalid(s_axi_wvalid[0]),   .s_axi_wready(s_axi_wready[0]),
        .s_axi_wdata(s_axi_wdata[0]),     .s_axi_wstrb(s_axi_wstrb[0]),
        .s_axi_wlast(s_axi_wlast[0]),
        .s_axi_bvalid(s_axi_bvalid[0]),   .s_axi_bready(s_axi_bready[0]),
        .s_axi_bid(s_axi_bid[0]),         .s_axi_bresp(s_axi_bresp[0]),
        .s_axi_arvalid(s_axi_arvalid[0]), .s_axi_arready(s_axi_arready[0]),
        .s_axi_araddr(s_axi_araddr[0]),   .s_axi_arid(s_axi_arid[0]),
        .s_axi_arlen(s_axi_arlen[0]),     .s_axi_arsize(s_axi_arsize[0]),
        .s_axi_arburst(s_axi_arburst[0]),
        .s_axi_rvalid(s_axi_rvalid[0]),   .s_axi_rready(s_axi_rready[0]),
        .s_axi_rdata(s_axi_rdata[0]),     .s_axi_rid(s_axi_rid[0]),
        .s_axi_rresp(s_axi_rresp[0]),     .s_axi_rlast(s_axi_rlast[0]),
        .debug_rd_count(mock_rd), .debug_wr_count(mock_wr)
    );

    // =========================================================
    // FSM-based AXI4 驱动（无需 @(posedge clk) 或 #delay）
    // =========================================================
    localparam [3:0] T_IDLE = 0, T_WR_AW = 1, T_WR_W = 2, T_WR_B = 3,
                      T_RD_AR = 4, T_RD_R = 5, T_DONE = 6;

    reg [3:0] test_state;
    reg [31:0] test_cnt;    // 当前测试编号
    reg [31:0] total_tests; // 总测试数
    reg [31:0] errors;

    // 写/readback 数据
    reg [DATA_WIDTH-1:0] write_data;
    reg [DATA_WIDTH-1:0] expected_data;
    reg [ADDR_WIDTH-1:0] test_addr;
    reg is_write_phase;  // 1=写, 0=读回
    reg [31:0] sub_cnt;

    // passthrough 是直连，mock memory awready/wready = 1，bvalid 跟随 awvalid
    // 所以单拍就能完成写握手
    // 读：arready = ~rd_pending, 1拍后 rvalid = rd_pending

    always @(posedge clk) begin
        if (reset) begin
            test_state   <= T_IDLE;
            test_cnt     <= 0;
            total_tests  <= 0;
            errors       <= 0;
            sub_cnt      <= 0;
            is_write_phase <= 1'b1;
            m_axi_awvalid[0] <= 0;
            m_axi_wvalid[0]  <= 0;
            m_axi_arvalid[0] <= 0;
            m_axi_bready[0]  <= 0;
            m_axi_rready[0]  <= 0;
            m_axi_awaddr[0]  <= 0;
            m_axi_awid[0]    <= 0;
            m_axi_awlen[0]   <= 0;
            m_axi_awsize[0]  <= 0;
            m_axi_awburst[0] <= 0;
            m_axi_wdata[0]   <= 0;
            m_axi_wstrb[0]   <= 0;
            m_axi_wlast[0]   <= 1;
            m_axi_araddr[0]  <= 0;
            m_axi_arid[0]    <= 0;
            m_axi_arlen[0]   <= 0;
            m_axi_arsize[0]  <= 0;
            m_axi_arburst[0] <= 0;
        end else begin
            case (test_state)
                T_IDLE: begin
                    if (test_cnt < 62) begin // 1 initial + 10 fixed + 50 random
                        // 准备测试数据
                        if (test_cnt == 0) begin
                            test_addr  <= 32'h0;
                            write_data <= 512'hDEADBEEF_CAFEBABE_01234567_89ABCDEF_FEDCBA98_76543210_BADC0FFE_DEADBEEF_CAFEBABE; // H-3 fix: full 512-bit
                            is_write_phase <= 1'b1;
                            sub_cnt <= 0;
                        end else if (test_cnt <= 10) begin
                            test_addr  <= (test_cnt - 1) * 64;
                            write_data <= {$urandom, $urandom, $urandom, $urandom, // H-3 fix: 16×32=512 bit
                                           $urandom, $urandom, $urandom, $urandom,
                                           $urandom, $urandom, $urandom, $urandom,
                                           $urandom, $urandom, $urandom, $urandom};
                            is_write_phase <= 1'b1;
                            sub_cnt <= 0;
                        end else begin
                            test_addr  <= (($urandom % 256) * 64);
                            write_data <= {$urandom, $urandom, $urandom, $urandom, // H-3 fix: 16×32=512 bit
                                           $urandom, $urandom, $urandom, $urandom,
                                           $urandom, $urandom, $urandom, $urandom,
                                           $urandom, $urandom, $urandom, $urandom};
                            is_write_phase <= 1'b1;
                            sub_cnt <= 0;
                        end
                        test_state <= T_WR_AW;
                    end else begin
                        test_state <= T_DONE;
                    end
                end

                T_WR_AW: begin
                    // 发起写请求 (aw + w 同时)
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
                    test_state <= T_WR_B;
                end

                T_WR_B: begin
                    // 等待写完成 (mock memory awready=1, wready=1, bvalid=awvalid)
                    // passthrough 直接转发，所以握手会很快
                    m_axi_awvalid[0] <= 1'b0;
                    m_axi_wvalid[0]  <= 1'b0;
                    if (m_axi_bvalid[0]) begin
                        m_axi_bready[0] <= 1'b0;
                        // 写完成，开始读
                        test_state <= T_RD_AR;
                    end
                end

                T_RD_AR: begin
                    // 发起读请求
                    m_axi_arvalid[0] <= 1'b1;
                    m_axi_araddr[0]  <= test_addr;
                    m_axi_arid[0]    <= 8'h01;
                    m_axi_arlen[0]   <= 8'h00;
                    m_axi_arsize[0]  <= 3'd6;
                    m_axi_arburst[0] <= 2'b01;
                    m_axi_rready[0]  <= 1'b1;
                    test_state <= T_RD_R;
                end

                T_RD_R: begin
                    m_axi_arvalid[0] <= 1'b0;
                    if (m_axi_rvalid[0]) begin
                        m_axi_rready[0] <= 1'b0;
                        // 检查数据
                        if (m_axi_rdata[0] !== expected_data) begin
                            errors <= errors + 1;
                        end
                        total_tests <= total_tests + 1;
                        test_cnt <= test_cnt + 1;
                        test_state <= T_IDLE;
                    end
                end

                T_DONE: begin
                    // 仿真结束
                    if (errors == 0)
                        $display("PASSED: %0d write-read tests, 0 errors (mock: %0d rd, %0d wr)", total_tests, mock_rd, mock_wr);
                    else
                        $display("FAILED: %0d errors in %0d tests", errors, total_tests);
                    $finish;
                end

                default: test_state <= T_IDLE;
            endcase
        end
    end

endmodule
