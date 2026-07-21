// SPDX-License-Identifier: Apache-2.0
// Copyright © 2024-2026 DiVo Gen²AI
//
// tb_wrapper_baiyang_ddr4_standalone — 白杨 DDR4 wrapper APB3 初始化独立验证
//
// 验证 APB3 初始化 FSM 序列:
//   1. mig_phy_done → 开始 APB3 写序列
//   2. 写 scgmcctrl (0x034) = 0x00000021
//   3. 写 apbcfg (0x3FD) = 0x00000001
//   4. init_done 置位
//   5. dfi_init_complete + init_done → mc_ready

module tb_wrapper_baiyang_ddr4_standalone (
    input wire clk,
    input wire reset
);

    localparam AXI_DATA_WIDTH = 512;
    localparam YQ_DATA_WIDTH  = 256;
    localparam ADDR_WIDTH     = 48;
    localparam YQ_ADDR_WIDTH  = 36;
    localparam ID_WIDTH       = 8;
    localparam YQ_ID_WIDTH    = 14;
    localparam DATA_SIZE      = AXI_DATA_WIDTH / 8;
    localparam NUM_BANKS      = 1;

    // AXI4 Master 信号 — unpacked array 匹配 wrapper 端口
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

    // DFI 接口
    wire dfi_init_start;
    reg  dfi_init_complete;
    reg  mig_phy_done;

    // Debug
    wire debug_init_done;
    wire [31:0] debug_err_count;

    // DUT
    VX_mem_ctrl_wrapper_baiyang_ddr4 #(
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .YQ_DATA_WIDTH(YQ_DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .YQ_ADDR_WIDTH(YQ_ADDR_WIDTH),
        .ID_WIDTH(ID_WIDTH),
        .YQ_ID_WIDTH(YQ_ID_WIDTH),
        .DDR_FREQ_MHZ(3200),
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
        .dfi_init_start, .dfi_init_complete, .mig_phy_done,
        .debug_init_done, .debug_err_count
    );

    // =========================================================
    // APB3 监控 — 验证写序列
    // =========================================================
    reg [31:0] apb_writes_seen;
    reg [11:0] apb_addr_log [0:1];
    reg [31:0] apb_data_log [0:1];

    always @(posedge clk) begin
        if (reset) begin
            apb_writes_seen <= 0;
        end else begin
            if (dut.apb_psel_r && dut.apb_penable_r && dut.apb_pwrite_r) begin
                if (apb_writes_seen < 2) begin
                    apb_addr_log[apb_writes_seen] <= dut.apb_paddr_r;
                    apb_data_log[apb_writes_seen] <= dut.apb_pwdata_r;
                end
                apb_writes_seen <= apb_writes_seen + 1;
            end
        end
    end

    // =========================================================
    // 模拟 mig_phy_done 和 dfi_init_complete
    // =========================================================
    reg [7:0] phy_delay_cnt;

    always @(posedge clk) begin
        if (reset) begin
            mig_phy_done     <= 1'b0;
            dfi_init_complete <= 1'b0;
            phy_delay_cnt    <= 8'd0;
        end else begin
            if (!mig_phy_done) begin
                if (phy_delay_cnt < 8'd20)
                    phy_delay_cnt <= phy_delay_cnt + 8'd1;
                else
                    mig_phy_done <= 1'b1;
            end
            if (dfi_init_start && !dfi_init_complete) begin
                phy_delay_cnt <= phy_delay_cnt + 8'd1;
                if (phy_delay_cnt >= 8'd30)
                    dfi_init_complete <= 1'b1;
            end
        end
    end

    // =========================================================
    // 测试 FSM — 只验证 APB3 初始化序列
    // =========================================================
    localparam [3:0] T_WAIT_INIT = 0, T_VERIFY_APB = 1, T_DONE = 2;

    reg [3:0] test_state;
    reg [31:0] errors;

    always @(posedge clk) begin
        if (reset) begin
            test_state <= T_WAIT_INIT;
            errors     <= 0;
            // 初始化 AXI 信号（未使用但需要连接）
            m_axi_awvalid[0] <= 0; m_axi_wvalid[0] <= 0; m_axi_arvalid[0] <= 0;
            m_axi_bready[0] <= 0; m_axi_rready[0] <= 0;
            m_axi_awaddr[0] <= 0; m_axi_awid[0] <= 0;
            m_axi_awlen[0] <= 0; m_axi_awsize[0] <= 0; m_axi_awburst[0] <= 0;
            m_axi_wdata[0] <= 0; m_axi_wstrb[0] <= 0; m_axi_wlast[0] <= 1;
            m_axi_araddr[0] <= 0; m_axi_arid[0] <= 0;
            m_axi_arlen[0] <= 0; m_axi_arsize[0] <= 0; m_axi_arburst[0] <= 0;
        end else begin
            case (test_state)
                T_WAIT_INIT: begin
                    if (debug_init_done) begin
                        test_state <= T_VERIFY_APB;
                    end
                end

                T_VERIFY_APB: begin
                    if (apb_writes_seen != 2) begin
                        errors <= errors + 1;
                        $display("  [FAIL] Expected 2 APB writes, got %0d", apb_writes_seen);
                    end else begin
                        if (apb_addr_log[0] !== 12'h034 || apb_data_log[0] !== 32'h0000_0021) begin
                            errors <= errors + 1;
                            $display("  [FAIL] APB write 0: addr=0x%h data=0x%h (exp 0x034/0x00000021)",
                                     apb_addr_log[0], apb_data_log[0]);
                        end
                        if (apb_addr_log[1] !== 12'h3FD || apb_data_log[1] !== 32'h0000_0001) begin
                            errors <= errors + 1;
                            $display("  [FAIL] APB write 1: addr=0x%h data=0x%h (exp 0x3FD/0x00000001)",
                                     apb_addr_log[1], apb_data_log[1]);
                        end
                    end

                    if (!dfi_init_start) begin
                        errors <= errors + 1;
                        $display("  [FAIL] dfi_init_start not asserted after mig_phy_done");
                    end

                    test_state <= T_DONE;
                end

                T_DONE: begin
                    if (errors == 0)
                        $display("PASSED: baiyang DDR4 APB3 init sequence verified, 0 errors");
                    else
                        $display("FAILED: %0d errors in baiyang DDR4 APB3 init", errors);
                    $finish;
                end

                default: test_state <= T_WAIT_INIT;
            endcase
        end
    end

endmodule
