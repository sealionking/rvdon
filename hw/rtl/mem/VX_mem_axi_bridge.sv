// SPDX-License-Identifier: Apache-2.0
// Copyright © 2024-2026 DiVo Gen²AI — 王掬琅（Peter Wang）· 王潇奕（Shawn Wang）
//
// VX_mem_axi_bridge — Vortex 内存总线到 AXI4 通用桥接器
//
// 将 Vortex 内部的 mem_req/rsp 信号数组转换为标准 AXI4 接口，
// 使得任何支持 AXI4 的外部 DDR/DDR4/DDR5 控制器都可以接入 Vortex。
//
// 架构:
//   Vortex mem_req/rsp (flat arrays)
//     → 内部 VX_axi_adapter (Apache 2.0, Vortex upstream)
//     → 标准 AXI4 Master 接口 (可配置数据宽度/地址宽度/ID宽度)
//     → 用户的 DDR 控制器 wrapper
//
// 参数:
//   NUM_PORTS     — Vortex 内存端口数 (通常 = VX_MEM_PORTS)
//   DATA_WIDTH    — 数据总线宽度 (位，默认 512)
//   ADDR_WIDTH    — 字地址宽度 (默认 26，即 2^26 × 64B = 4GB)
//   TAG_WIDTH     — 事务标签宽度 (默认 8)
//   NUM_BANKS     — AXI4 输出 bank 数 (默认 1)
//   INTERLEAVE    — bank 地址交错 (默认 0，无交错)
//
// 集成示例 (连接白杨 DDR4):
//   VX_mem_axi_bridge #(
//     .NUM_PORTS  (VX_MEM_PORTS),
//     .DATA_WIDTH (512),
//     .ADDR_WIDTH (26)
//   ) bridge (
//     .clk         (clk),
//     .reset       (reset),
//     // Vortex 侧
//     .mem_req_valid, .mem_req_rw, .mem_req_byteen,
//     .mem_req_addr, .mem_req_data, .mem_req_tag,
//     .mem_req_ready,
//     .mem_rsp_valid, .mem_rsp_data, .mem_rsp_tag,
//     .mem_rsp_ready,
//     // AXI4 侧
//     .m_axi_awvalid, .m_axi_awready, .m_axi_awaddr, ...
//   );
//
// 之后连接白杨的具体适配器 (VX_yuquan_wrapper) 或任何其他
// AXI4 DDR 控制器。

`include "VX_define.vh"

module VX_mem_axi_bridge #(
    parameter NUM_PORTS  = 1,
    parameter DATA_WIDTH = 512,         // 数据宽度 (位)
    parameter ADDR_WIDTH = 26,          // 字地址宽度
    parameter TAG_WIDTH  = `UUID_WIDTH + 1, // 默认使用 Vortex UUID tag
    parameter NUM_BANKS  = 1,           // AXI4 bank 数量
    parameter INTERLEAVE = 0            // Bank 交错: 0=顺序, 1=交错
) (
    input  wire clk,
    input  wire reset,

    // ============================================================
    // Vortex 内存总线 (mem_req/rsp 信号数组)
    // ============================================================
    input  wire                     mem_req_valid [NUM_PORTS],
    input  wire                     mem_req_rw    [NUM_PORTS],
    input  wire [DATA_WIDTH/8-1:0]  mem_req_byteen[NUM_PORTS],
    input  wire [ADDR_WIDTH-1:0]    mem_req_addr  [NUM_PORTS],
    input  wire [DATA_WIDTH-1:0]    mem_req_data  [NUM_PORTS],
    input  wire [TAG_WIDTH-1:0]     mem_req_tag   [NUM_PORTS],
    output wire                     mem_req_ready [NUM_PORTS],

    output wire                     mem_rsp_valid [NUM_PORTS],
    output wire [DATA_WIDTH-1:0]    mem_rsp_data  [NUM_PORTS],
    output wire [TAG_WIDTH-1:0]     mem_rsp_tag   [NUM_PORTS],
    input  wire                     mem_rsp_ready [NUM_PORTS],

    // ============================================================
    // AXI4 Master 接口 (连接外部 DDR 控制器)
    // ============================================================
    // Write Address
    output wire                     m_axi_awvalid [NUM_BANKS],
    input  wire                     m_axi_awready [NUM_BANKS],
    output wire [ADDR_WIDTH-1:0]    m_axi_awaddr  [NUM_BANKS],
    output wire [TAG_WIDTH-1:0]     m_axi_awid    [NUM_BANKS],
    output wire [7:0]               m_axi_awlen   [NUM_BANKS],
    output wire [2:0]               m_axi_awsize  [NUM_BANKS],
    output wire [1:0]               m_axi_awburst [NUM_BANKS],
    output wire [1:0]               m_axi_awlock  [NUM_BANKS],
    output wire [3:0]               m_axi_awcache [NUM_BANKS],
    output wire [2:0]               m_axi_awprot  [NUM_BANKS],
    output wire [3:0]               m_axi_awqos   [NUM_BANKS],
    output wire [3:0]               m_axi_awregion[NUM_BANKS],

    // Write Data
    output wire                     m_axi_wvalid  [NUM_BANKS],
    input  wire                     m_axi_wready  [NUM_BANKS],
    output wire [DATA_WIDTH-1:0]    m_axi_wdata   [NUM_BANKS],
    output wire [DATA_WIDTH/8-1:0]  m_axi_wstrb   [NUM_BANKS],
    output wire                     m_axi_wlast   [NUM_BANKS],

    // Write Response
    input  wire                     m_axi_bvalid  [NUM_BANKS],
    output wire                     m_axi_bready  [NUM_BANKS],
    input  wire [TAG_WIDTH-1:0]     m_axi_bid     [NUM_BANKS],
    input  wire [1:0]               m_axi_bresp   [NUM_BANKS],

    // Read Address
    output wire                     m_axi_arvalid [NUM_BANKS],
    input  wire                     m_axi_arready [NUM_BANKS],
    output wire [ADDR_WIDTH-1:0]    m_axi_araddr  [NUM_BANKS],
    output wire [TAG_WIDTH-1:0]     m_axi_arid    [NUM_BANKS],
    output wire [7:0]               m_axi_arlen   [NUM_BANKS],
    output wire [2:0]               m_axi_arsize  [NUM_BANKS],
    output wire [1:0]               m_axi_arburst [NUM_BANKS],
    output wire [1:0]               m_axi_arlock  [NUM_BANKS],
    output wire [3:0]               m_axi_arcache [NUM_BANKS],
    output wire [2:0]               m_axi_arprot  [NUM_BANKS],
    output wire [3:0]               m_axi_arqos   [NUM_BANKS],
    output wire [3:0]               m_axi_arregion[NUM_BANKS],

    // Read Response
    input  wire                     m_axi_rvalid  [NUM_BANKS],
    output wire                     m_axi_rready  [NUM_BANKS],
    input  wire [DATA_WIDTH-1:0]    m_axi_rdata   [NUM_BANKS],
    input  wire [TAG_WIDTH-1:0]     m_axi_rid     [NUM_BANKS],
    input  wire [1:0]               m_axi_rresp   [NUM_BANKS],
    input  wire                     m_axi_rlast   [NUM_BANKS]
);

    // AXI adapter: 地址为 byte-addressable 格式
    // Vortex 内部使用 word-addressable (1 word = DATA_WIDTH/8 bytes)
    // 外部 AXI4 使用 byte-addressable
    localparam DATA_SIZE  = DATA_WIDTH / 8;
    localparam ADDR_WIDTH_OUT = ADDR_WIDTH + $clog2(DATA_SIZE);

    VX_axi_adapter #(
        .DATA_WIDTH      (DATA_WIDTH),
        .ADDR_WIDTH_IN   (ADDR_WIDTH),
        .ADDR_WIDTH_OUT  (ADDR_WIDTH_OUT),
        .TAG_WIDTH_IN    (TAG_WIDTH),
        .TAG_WIDTH_OUT   (TAG_WIDTH),
        .NUM_PORTS_IN    (NUM_PORTS),
        .NUM_BANKS_OUT   (NUM_BANKS),
        .INTERLEAVE      (INTERLEAVE),
        .TAG_BUFFER_SIZE (16),
        .ARBITER         ("R"),
        .REQ_OUT_BUF     (0),
        .RSP_OUT_BUF     (0)
    ) axi_adapter (
        .clk  (clk),
        .reset(reset),

        // Vortex 侧
        .mem_req_valid (mem_req_valid),
        .mem_req_rw    (mem_req_rw),
        .mem_req_byteen(mem_req_byteen),
        .mem_req_addr  (mem_req_addr),
        .mem_req_data  (mem_req_data),
        .mem_req_tag   (mem_req_tag),
        .mem_req_ready (mem_req_ready),

        .mem_rsp_valid (mem_rsp_valid),
        .mem_rsp_data  (mem_rsp_data),
        .mem_rsp_tag   (mem_rsp_tag),
        .mem_rsp_ready (mem_rsp_ready),

        // AXI4 侧
        .m_axi_awvalid (m_axi_awvalid),
        .m_axi_awready (m_axi_awready),
        .m_axi_awaddr  (m_axi_awaddr),
        .m_axi_awid    (m_axi_awid),
        .m_axi_awlen   (m_axi_awlen),
        .m_axi_awsize  (m_axi_awsize),
        .m_axi_awburst (m_axi_awburst),
        .m_axi_awlock  (m_axi_awlock),
        .m_axi_awcache (m_axi_awcache),
        .m_axi_awprot  (m_axi_awprot),
        .m_axi_awqos   (m_axi_awqos),
        .m_axi_awregion(m_axi_awregion),

        .m_axi_wvalid  (m_axi_wvalid),
        .m_axi_wready  (m_axi_wready),
        .m_axi_wdata   (m_axi_wdata),
        .m_axi_wstrb   (m_axi_wstrb),
        .m_axi_wlast   (m_axi_wlast),

        .m_axi_bvalid  (m_axi_bvalid),
        .m_axi_bready  (m_axi_bready),
        .m_axi_bid     (m_axi_bid),
        .m_axi_bresp   (m_axi_bresp),

        .m_axi_arvalid (m_axi_arvalid),
        .m_axi_arready (m_axi_arready),
        .m_axi_araddr  (m_axi_araddr),
        .m_axi_arid    (m_axi_arid),
        .m_axi_arlen   (m_axi_arlen),
        .m_axi_arsize  (m_axi_arsize),
        .m_axi_arburst (m_axi_arburst),
        .m_axi_arlock  (m_axi_arlock),
        .m_axi_arcache (m_axi_arcache),
        .m_axi_arprot  (m_axi_arprot),
        .m_axi_arqos   (m_axi_arqos),
        .m_axi_arregion(m_axi_arregion),

        .m_axi_rvalid  (m_axi_rvalid),
        .m_axi_rready  (m_axi_rready),
        .m_axi_rdata   (m_axi_rdata),
        .m_axi_rlast   (m_axi_rlast),
        .m_axi_rid     (m_axi_rid),
        .m_axi_rresp   (m_axi_rresp)
    );

endmodule
