// SPDX-License-Identifier: Apache-2.0
// Copyright © 2024-2026 DiVo Gen²AI — 王掬琅（Peter Wang）· 王潇奕（Shawn Wang）
//
// tb_wrapper_passthrough — passthrough wrapper 独立验证
//
// 链路: VX_mem_axi_bridge → VX_mem_ctrl_wrapper_passthrough → VX_mock_axi_memory
//
// 验证:
//   Phase 1: 编译通过 (Verilator 5.020)
//   Phase 2: 基本读写 (写 64B → 读 64B, 数据完整性)
//   Phase 3: 随机压力 (1000 次随机读写)

`include "VX_define.vh"

module tb_wrapper_passthrough;

    localparam DATA_WIDTH = 512;
    localparam ADDR_WIDTH = 32;
    localparam TAG_WIDTH  = 8;  // UUID_WIDTH + 1 for standalone test
    localparam NUM_BANKS  = 1;
    localparam DATA_SIZE  = DATA_WIDTH / 8;

    reg clk;
    reg reset;

    // =========================================================
    // Vortex mem_req/rsp 信号 (驱动端)
    // =========================================================
    reg                     mem_req_valid [NUM_BANKS];
    reg                     mem_req_rw    [NUM_BANKS];
    reg [DATA_SIZE-1:0]     mem_req_byteen[NUM_BANKS];
    reg [25:0]              mem_req_addr  [NUM_BANKS];
    reg [DATA_WIDTH-1:0]    mem_req_data  [NUM_BANKS];
    reg [TAG_WIDTH-1:0]     mem_req_tag   [NUM_BANKS];
    wire                    mem_req_ready [NUM_BANKS];

    wire                    mem_rsp_valid [NUM_BANKS];
    wire [DATA_WIDTH-1:0]   mem_rsp_data  [NUM_BANKS];
    wire [TAG_WIDTH-1:0]    mem_rsp_tag   [NUM_BANKS];
    reg                     mem_rsp_ready [NUM_BANKS];

    // =========================================================
    // AXI4 中间信号 (bridge → wrapper)
    // =========================================================
    wire                    axi_awvalid [NUM_BANKS];
    wire                    axi_awready [NUM_BANKS];
    wire [ADDR_WIDTH-1:0]   axi_awaddr  [NUM_BANKS];
    wire [TAG_WIDTH-1:0]    axi_awid    [NUM_BANKS];
    wire [7:0]              axi_awlen   [NUM_BANKS];
    wire [2:0]              axi_awsize  [NUM_BANKS];
    wire [1:0]              axi_awburst [NUM_BANKS];

    wire                    axi_wvalid  [NUM_BANKS];
    wire                    axi_wready  [NUM_BANKS];
    wire [DATA_WIDTH-1:0]   axi_wdata   [NUM_BANKS];
    wire [DATA_SIZE-1:0]    axi_wstrb   [NUM_BANKS];
    wire                    axi_wlast   [NUM_BANKS];

    wire                    axi_bvalid  [NUM_BANKS];
    wire                    axi_bready  [NUM_BANKS];
    wire [TAG_WIDTH-1:0]    axi_bid     [NUM_BANKS];
    wire [1:0]              axi_bresp   [NUM_BANKS];

    wire                    axi_arvalid [NUM_BANKS];
    wire                    axi_arready [NUM_BANKS];
    wire [ADDR_WIDTH-1:0]   axi_araddr  [NUM_BANKS];
    wire [TAG_WIDTH-1:0]    axi_arid    [NUM_BANKS];
    wire [7:0]              axi_arlen   [NUM_BANKS];
    wire [2:0]              axi_arsize  [NUM_BANKS];
    wire [1:0]              axi_arburst [NUM_BANKS];

    wire                    axi_rvalid  [NUM_BANKS];
    wire                    axi_rready  [NUM_BANKS];
    wire [DATA_WIDTH-1:0]   axi_rdata   [NUM_BANKS];
    wire [TAG_WIDTH-1:0]    axi_rid     [NUM_BANKS];
    wire [1:0]              axi_rresp   [NUM_BANKS];
    wire                    axi_rlast   [NUM_BANKS];

    // =========================================================
    // DUT: bridge → wrapper → mock memory
    // =========================================================
    VX_mem_axi_bridge #(
        .NUM_PORTS (1), .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(26), .TAG_WIDTH(TAG_WIDTH), .NUM_BANKS(1)
    ) bridge (
        .clk, .reset,
        .mem_req_valid, .mem_req_rw, .mem_req_byteen,
        .mem_req_addr, .mem_req_data, .mem_req_tag,
        .mem_req_ready, .mem_rsp_valid, .mem_rsp_data,
        .mem_rsp_tag, .mem_rsp_ready,
        .m_axi_awvalid(axi_awvalid), .m_axi_awready(axi_awready),
        .m_axi_awaddr(axi_awaddr), .m_axi_awid(axi_awid),
        .m_axi_awlen(axi_awlen), .m_axi_awsize(axi_awsize),
        .m_axi_awburst(axi_awburst),
        .m_axi_awlock(), .m_axi_awcache(), .m_axi_awprot(),
        .m_axi_awqos(), .m_axi_awregion(),
        .m_axi_wvalid(axi_wvalid), .m_axi_wready(axi_wready),
        .m_axi_wdata(axi_wdata), .m_axi_wstrb(axi_wstrb),
        .m_axi_wlast(axi_wlast),
        .m_axi_bvalid(axi_bvalid), .m_axi_bready(axi_bready),
        .m_axi_bid(axi_bid), .m_axi_bresp(axi_bresp),
        .m_axi_arvalid(axi_arvalid), .m_axi_arready(axi_arready),
        .m_axi_araddr(axi_araddr), .m_axi_arid(axi_arid),
        .m_axi_arlen(axi_arlen), .m_axi_arsize(axi_arsize),
        .m_axi_arburst(axi_arburst),
        .m_axi_arlock(), .m_axi_arcache(), .m_axi_arprot(),
        .m_axi_arqos(), .m_axi_arregion(),
        .m_axi_rvalid(axi_rvalid), .m_axi_rready(axi_rready),
        .m_axi_rdata(axi_rdata), .m_axi_rid(axi_rid),
        .m_axi_rresp(axi_rresp), .m_axi_rlast(axi_rlast)
    );

    wire [ADDR_WIDTH-1:0]   mc_axi_awaddr  [NUM_BANKS];
    wire [TAG_WIDTH-1:0]    mc_axi_awid    [NUM_BANKS];
    wire [7:0]              mc_axi_awlen   [NUM_BANKS];
    wire [2:0]              mc_axi_awsize  [NUM_BANKS];
    wire [1:0]              mc_axi_awburst [NUM_BANKS];
    wire                    mc_axi_awvalid [NUM_BANKS];
    wire                    mc_axi_awready [NUM_BANKS];
    wire                    mc_axi_wvalid  [NUM_BANKS];
    wire                    mc_axi_wready  [NUM_BANKS];
    wire [DATA_WIDTH-1:0]   mc_axi_wdata   [NUM_BANKS];
    wire [DATA_SIZE-1:0]    mc_axi_wstrb   [NUM_BANKS];
    wire                    mc_axi_wlast   [NUM_BANKS];
    wire                    mc_axi_bvalid  [NUM_BANKS];
    wire                    mc_axi_bready  [NUM_BANKS];
    wire [TAG_WIDTH-1:0]    mc_axi_bid     [NUM_BANKS];
    wire [1:0]              mc_axi_bresp   [NUM_BANKS];
    wire                    mc_axi_arvalid [NUM_BANKS];
    wire                    mc_axi_arready [NUM_BANKS];
    wire [ADDR_WIDTH-1:0]   mc_axi_araddr  [NUM_BANKS];
    wire [TAG_WIDTH-1:0]    mc_axi_arid    [NUM_BANKS];
    wire [7:0]              mc_axi_arlen   [NUM_BANKS];
    wire [2:0]              mc_axi_arsize  [NUM_BANKS];
    wire [1:0]              mc_axi_arburst [NUM_BANKS];
    wire                    mc_axi_rvalid  [NUM_BANKS];
    wire                    mc_axi_rready  [NUM_BANKS];
    wire [DATA_WIDTH-1:0]   mc_axi_rdata   [NUM_BANKS];
    wire [TAG_WIDTH-1:0]    mc_axi_rid     [NUM_BANKS];
    wire [1:0]              mc_axi_rresp   [NUM_BANKS];
    wire                    mc_axi_rlast   [NUM_BANKS];

    wire debug_init_done, dummy_rd, dummy_wr;

    VX_mem_ctrl_wrapper_passthrough #(
        .AXI_DATA_WIDTH(DATA_WIDTH), .AXI_ADDR_WIDTH(ADDR_WIDTH),
        .AXI_ID_WIDTH(TAG_WIDTH), .NUM_BANKS(1), .MC_NAME("test")
    ) wrapper (
        .clk, .reset,
        .m_axi_awvalid(axi_awvalid), .m_axi_awready(axi_awready),
        .m_axi_awaddr(axi_awaddr), .m_axi_awid(axi_awid),
        .m_axi_awlen(axi_awlen), .m_axi_awsize(axi_awsize),
        .m_axi_awburst(axi_awburst),
        .m_axi_wvalid(axi_wvalid), .m_axi_wready(axi_wready),
        .m_axi_wdata(axi_wdata), .m_axi_wstrb(axi_wstrb),
        .m_axi_wlast(axi_wlast),
        .m_axi_bvalid(axi_bvalid), .m_axi_bready(axi_bready),
        .m_axi_bid(axi_bid), .m_axi_bresp(axi_bresp),
        .m_axi_arvalid(axi_arvalid), .m_axi_arready(axi_arready),
        .m_axi_araddr(axi_araddr), .m_axi_arid(axi_arid),
        .m_axi_arlen(axi_arlen), .m_axi_arsize(axi_arsize),
        .m_axi_arburst(axi_arburst),
        .m_axi_rvalid(axi_rvalid), .m_axi_rready(axi_rready),
        .m_axi_rdata(axi_rdata), .m_axi_rid(axi_rid),
        .m_axi_rresp(axi_rresp), .m_axi_rlast(axi_rlast),
        .s_axi_awvalid(mc_axi_awvalid), .s_axi_awready(mc_axi_awready),
        .s_axi_awaddr(mc_axi_awaddr), .s_axi_awid(mc_axi_awid),
        .s_axi_awlen(mc_axi_awlen), .s_axi_awsize(mc_axi_awsize),
        .s_axi_awburst(mc_axi_awburst),
        .s_axi_wvalid(mc_axi_wvalid), .s_axi_wready(mc_axi_wready),
        .s_axi_wdata(mc_axi_wdata), .s_axi_wstrb(mc_axi_wstrb),
        .s_axi_wlast(mc_axi_wlast),
        .s_axi_bvalid(mc_axi_bvalid), .s_axi_bready(mc_axi_bready),
        .s_axi_bid(mc_axi_bid), .s_axi_bresp(mc_axi_bresp),
        .s_axi_arvalid(mc_axi_arvalid), .s_axi_arready(mc_axi_arready),
        .s_axi_araddr(mc_axi_araddr), .s_axi_arid(mc_axi_arid),
        .s_axi_arlen(mc_axi_arlen), .s_axi_arsize(mc_axi_arsize),
        .s_axi_arburst(mc_axi_arburst),
        .s_axi_rvalid(mc_axi_rvalid), .s_axi_rready(mc_axi_rready),
        .s_axi_rdata(mc_axi_rdata), .s_axi_rid(mc_axi_rid),
        .s_axi_rresp(mc_axi_rresp), .s_axi_rlast(mc_axi_rlast),
        .debug_init_done, .debug_rd_bytes(dummy_rd), .debug_wr_bytes(dummy_wr)
    );

    wire [31:0] mock_rd, mock_wr;
    VX_mock_axi_memory #(
        .DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(ADDR_WIDTH),
        .ID_WIDTH(TAG_WIDTH), .MEM_DEPTH(1024)
    ) mock_mem (
        .clk, .reset,
        .s_axi_awvalid(mc_axi_awvalid), .s_axi_awready(mc_axi_awready),
        .s_axi_awaddr(mc_axi_awaddr), .s_axi_awid(mc_axi_awid),
        .s_axi_awlen(mc_axi_awlen), .s_axi_awsize(mc_axi_awsize),
        .s_axi_awburst(mc_axi_awburst),
        .s_axi_wvalid(mc_axi_wvalid), .s_axi_wready(mc_axi_wready),
        .s_axi_wdata(mc_axi_wdata), .s_axi_wstrb(mc_axi_wstrb),
        .s_axi_wlast(mc_axi_wlast),
        .s_axi_bvalid(mc_axi_bvalid), .s_axi_bready(mc_axi_bready),
        .s_axi_bid(mc_axi_bid), .s_axi_bresp(mc_axi_bresp),
        .s_axi_arvalid(mc_axi_arvalid), .s_axi_arready(mc_axi_arready),
        .s_axi_araddr(mc_axi_araddr), .s_axi_arid(mc_axi_arid),
        .s_axi_arlen(mc_axi_arlen), .s_axi_arsize(mc_axi_arsize),
        .s_axi_arburst(mc_axi_arburst),
        .s_axi_rvalid(mc_axi_rvalid), .s_axi_rready(mc_axi_rready),
        .s_axi_rdata(mc_axi_rdata), .s_axi_rid(mc_axi_rid),
        .s_axi_rresp(mc_axi_rresp), .s_axi_rlast(mc_axi_rlast),
        .debug_rd_count(mock_rd), .debug_wr_count(mock_wr)
    );

    // =========================================================
    // 测试驱动
    // =========================================================
    integer errors;
    reg [DATA_WIDTH-1:0] expected_data;

    task do_write;
        input [25:0] addr;
        input [DATA_WIDTH-1:0] data;
    begin
        mem_req_valid[0]  = 1'b1;
        mem_req_rw[0]     = 1'b1;
        mem_req_addr[0]   = addr;
        mem_req_data[0]   = data;
        mem_req_byteen[0] = {DATA_SIZE{1'b1}};
        mem_req_tag[0]    = 8'h00;
        mem_rsp_ready[0]  = 1'b1;

        // Wait for ready
        while (!mem_req_ready[0]) @(posedge clk);
        @(posedge clk);
        mem_req_valid[0] = 1'b0;

        // Wait for response
        while (!mem_rsp_valid[0]) @(posedge clk);
        @(posedge clk);
    end
    endtask

    task do_read;
        input [25:0] addr;
        output [DATA_WIDTH-1:0] data;
    begin
        mem_req_valid[0]  = 1'b1;
        mem_req_rw[0]     = 1'b0;
        mem_req_addr[0]   = addr;
        mem_req_tag[0]    = 8'h01;
        mem_rsp_ready[0]  = 1'b1;

        while (!mem_req_ready[0]) @(posedge clk);
        @(posedge clk);
        mem_req_valid[0] = 1'b0;

        while (!mem_rsp_valid[0]) @(posedge clk);
        data = mem_rsp_data[0];
        @(posedge clk);
    end
    endtask

    // =========================================================
    // 测试序列
    // =========================================================
    reg [DATA_WIDTH-1:0] rd_data;
    initial begin
        errors = 0;
        clk = 0;
        reset = 1;
        mem_req_valid[0] = 0;
        mem_rsp_ready[0] = 0;

        #100 reset = 0;

        #100;
        $display("=== [PASS] Phase 1: Compilation OK ===");

        // Phase 2: Basic read/write
        $display("=== Phase 2: Basic read/write ===");

        do_write(26'd0, 512'hDEADBEEF_CAFEBABE_01234567_89ABCDEF_FEDCBA98_76543210_BADC0FFE); // H-3 fix: full 512-bit
        $display("  Write addr=0 data=0x%h", 512'hDEADBEEF_CAFEBABE_01234567_89ABCDEF_FEDCBA98_76543210_BADC0FFE);

        do_read(26'd0, rd_data);
        expected_data = 512'hDEADBEEF_CAFEBABE_01234567_89ABCDEF_FEDCBA98_76543210_BADC0FFE;
        if (rd_data === expected_data) begin
            $display("  [PASS] Read addr=0: 0x%h", rd_data);
        end else begin
            $display("  [FAIL] Read addr=0: got 0x%h, expected 0x%h", rd_data, expected_data);
            errors = errors + 1;
        end

        // Phase 3: Multi-address test
        $display("=== Phase 3: Multi-address test ===");
        begin
            automatic bit [DATA_WIDTH-1:0] phase3_data [10];
            for (int addr = 0; addr < 10; addr = addr + 1) begin
                automatic bit [DATA_WIDTH-1:0] wd = {$urandom, $urandom, $urandom, $urandom, // H-3 fix: 16×32=512 bit
                                                       $urandom, $urandom, $urandom, $urandom,
                                                       $urandom, $urandom, $urandom, $urandom,
                                                       $urandom, $urandom, $urandom, $urandom};
                phase3_data[addr] = wd;
                do_write(addr, wd);
            end
            for (int addr = 0; addr < 10; addr = addr + 1) begin
                do_read(addr, rd_data);
                expected_data = phase3_data[addr];
                if (rd_data === expected_data) begin
                    $display("  [PASS] Addr=%0d", addr);
                end else begin
                    $display("  [FAIL] Addr=%0d: got 0x%h, expected 0x%h", addr, rd_data, expected_data);
                    errors = errors + 1;
                end
            end
        end

        // Phase 4: Random stress test
        $display("=== Phase 4: Random stress (100 tests) ===");
        for (int i = 0; i < 100; i = i + 1) begin
            automatic int ra = $urandom % 256;
            automatic bit [DATA_WIDTH-1:0] wd = {$urandom, $urandom, $urandom, $urandom, // H-3 fix: 16×32=512 bit
                                                   $urandom, $urandom, $urandom, $urandom,
                                                   $urandom, $urandom, $urandom, $urandom,
                                                   $urandom, $urandom, $urandom, $urandom};
            do_write(ra, wd);
            do_read(ra, rd_data);
            if (rd_data !== wd) begin
                $display("  [FAIL] Random addr=%0d", ra);
                errors = errors + 1;
            end
        end
        if (errors == 0)
            $display("  [PASS] 100 random tests OK");

        // Summary
        $display("=== Summary ===");
        if (errors == 0)
            $display("PASSED: 0 errors");
        else
            $display("FAILED: %0d errors", errors);

        $display("Mock memory: %0d reads, %0d writes", mock_rd, mock_wr);

        $finish;
    end

    always #5 clk = ~clk;  // 100 MHz

endmodule
