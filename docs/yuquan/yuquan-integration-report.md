# 白杨 (YuQuan) DDR4 控制器与 RVDon 集成技术报告

> **DiVo Gen²AI RVDon** — 技术报告 TR-2026-001
>
> 作者: 王掬琅（Peter Wang）· 王潇奕（Shawn Wang）
>
> 日期: 2026-07-19

---

## 摘要

本文记录 RVDon（基于 Vortex RISC-V GPGPU 的领域专用加速节点）与开源 DDR4 内存控制器白杨（YuQuan）的集成过程。集成使 RVDon 的内存子系统从行为级理想模型升级为第三方 IP 验证过的真实 DDR4 控制器，标志着项目从学术原型向工程产品的关键转变。

**关键词**: DDR4 控制器, DFI 3.1, AXI4 适配, RISC-V GPGPU, 开源 IP 集成

---

## 1. 背景

### 1.1 RVDon 内存子系统的局限

RVDon 基于 Vortex GPGPU，其 RTL 仿真使用 DPI-C DramSim 作为内存模型。DramSim 是行为级理想模型，无法反映真实 DDR4 的协议约束、时序参数和初始化流程。这使得 RTL 仿真结果无法直接映射到硅片实现。

### 1.2 白杨 (YuQuan) DDR4 控制器

白杨是香山团队（北京开源芯片研究院 BOSC / 中科院计算所 ICT CAS）开源的 DDR4 内存控制器，基于 Chisel 开发，使用 CIRCT firtool 编译为 SystemVerilog。

关键特性：
- **AXI4 总线接口** — Cacheline 粒度读写
- **DFI 3.1 PHY 接口** — 与 PHY 通信的标准协议
- **DDR4-2400 支持** — 已在香山昆明湖-V2 上通过 Cadence Palladium Z2 验证
- **SPEC CPU2006 性能** — 14 分/GHz，接近商用 IP
- **许可证** — MulanPSL-2.0（可商用）

仓库: [OpenXiangShan/YuQuan](https://github.com/OpenXiangShan/YuQuan)

---

## 2. 集成架构

### 2.1 整体数据通路

```
Vortex GPU Core
  → L3 Cache
    → mem_bus_if
      → VX_mem_data_adapter
        → VX_mem_bank_adapter
          → VX_axi_adapter (mem_req/rsp → AXI4 Master)
            → VX_yuquan_wrapper (512-bit → 256-bit AXI4 适配)
              → mc_top (白杨 DDR4 MC)
                → VX_dfi_sim_model (DFI 3.1 仿真响应模型)
```

### 2.2 接口适配

| 参数 | Vortex 侧 | 白杨侧 | 适配策略 |
|------|-----------|--------|----------|
| 数据宽度 | 512-bit | 256-bit | FSM 拆分为 2×256 burst |
| 地址宽度 | 48-bit | 36-bit | 高位截断 |
| AXI ID | 8-bit | 14-bit | 零扩展 |
| AXI burst | 单 beat (awlen=0) | 2-beat (awlen=1) | FSM 控制 |
| 配置接口 | — | APB3 | 自动初始化序列 |
| PHY 接口 | — | DFI 3.1 | 简化仿真模型 |

---

## 3. 关键设计决策

### 3.1 数据宽度适配: 512→256 拆分 FSM

白杨 AXI4 数据宽度为 256-bit（`BY_PORT_DW_0 = 256`），而 Vortex 内存总线为 512-bit。我们设计了双 FSM 实现拆分：

- **写路径 (5 状态)**: `IDLE → WAIT_WDATA → BEAT0(低256-bit) → BEAT1(高256-bit) → WAIT_BRESP`
- **读路径 (4 状态)**: `IDLE → PEND → BEAT0(锁存低256-bit) → BEAT1(拼合返回512-bit)`

burst length 从 N 变为 2N+1，wstrb 同步拆分。

### 3.2 APB3 自动初始化

白杨 mc_top 需要通过 APB3 写入配置寄存器才能启动。我们实现了自动初始化 FSM：

**最小初始化序列**:
1. 写 `scgmcctrl` (0x034) = `0x1` → `gen=1`，启动 MC
2. 写 `apbcfg` (0xFF4) = `0x1` → 触发 `apbDone`，锁定寄存器

**启动条件链**:
```
复位 → mig_phy_done (200周期) → APB3 写入 → apbDone=1
  → SCG 启动 → DRAM 初始化 → dfi_init_start → dfi_init_complete
  → MC 就绪，接受 AXI 读写
```

其余 DDR4 时序寄存器使用白杨复位默认值（DDR4-2400 时序已内嵌）。

### 3.3 DFI 初始化握手

白杨 mc_top 完成内部初始化后拉高 `dfi_init_start`，等待 PHY 返回 `dfi_init_complete`。我们的 DFI 仿真模型在收到 `dfi_init_start` 后延迟 100 周期拉高 `dfi_init_complete`，模拟 DRAM MRS 编程 + ZQ 校准 + CKE 等待时间。

### 3.4 条件编译隔离

所有白杨相关代码使用 `VX_CFG_YUQUAN_MC_ENABLE` 宏包裹，默认禁用。这确保：
- 不影响原有 Vortex 构建
- 可随时启用/禁用白杨路径
- 对上游 Vortex 无侵入性

---

## 4. DFI 3.1 仿真模型

我们设计了 `VX_dfi_sim_model.sv`，替代真实 PHY 功能：

| 功能 | 实现 |
|------|------|
| 存储阵列 | 64MB BRAM（256K × 256-bit），扁平地址 |
| 读延迟 | 固定 8 周期（近似 CAS Latency=8） |
| DFI init 握手 | 检测 init_start 上升沿，100 周期后返回 init_complete |
| PHY 就绪 | 复位后 200 周期拉高 mig_phy_done |
| DDR4 时序 | 不模拟（tRCD/tRP/tCL），只保证功能正确 |

简化策略: Phase M0 阶段目标是功能验证而非性能评估，时序精确仿真留待后续。

---

## 5. Verilator 兼容性

白杨 RTL 由 CIRCT firtool-1.62.0 生成（58,534 行，116 个 .sv 文件）。兼容性扫描结果：

| 检查项 | 结果 |
|--------|------|
| SVA 并发断言 | ✅ 无（CIRCT 使用过程块 + $error/$fatal）|
| DPI-C 导入 | ✅ 无 |
| SystemVerilog interface | ✅ 无 |
| struct/enum/packed | ✅ 无（CIRCT 展平为位向量）|
| $error/$fatal | ⚠️ 16 处（3 文件），通过 `+define+ASSERT_VERBOSE_COND_=0` 规避 |
| 异步复位 | ⚠️ 63 个 always 块，Verilator 报 SYNCASYNCNET 警告 |
| 多维 wire 数组 | ⚠️ 部分模块内部使用，Verilator 通常支持 |

**关键结论**: CIRCT 生成的 SystemVerilog 对 Verilator 基本友好。唯一硬性障碍是 `$error`/`$fatal`，但 CIRCT 已通过宏体系（`ASSERT_VERBOSE_COND_`/`STOP_COND_`）预留了关闭路径。

---

## 6. 构建结果

| 配置 | 二进制大小 | Verilator 编译 | rtlsim 回归 |
|------|-----------|---------------|------------|
| 白杨宏禁用 | 3.1 MB | ✅ 通过 | ✅ pf_tcu PASSED |
| 白杨宏启用 | 6.2 MB | ✅ 通过 | ⏳ 功能验证中 |

白杨 RTL 约占编译后二进制的 50%。

---

## 7. 集成进度

| 阶段 | 内容 | 状态 | 完成日期 |
|------|------|:----:|----------|
| Phase 1 | 接口分析 + wrapper 骨架 | ✅ | 2026-07-17 |
| Phase 2 | Verilog 生成 + RTL 集成 + FSM 完善 | ✅ | 2026-07-19 |
| Phase 3 | Verilator 编译 + DFI 仿真模型 | ✅ | 2026-07-19 |
| Phase 4 | 完整数据通路 + APB3 初始化 + DFI 握手 | ✅ | 2026-07-19 |
| Phase 5 | 白杨宏启用 rtlsim 功能回归 | 🔄 | — |
| Phase 6 | FPGA 原型验证 (TinyPHY) | ⏳ | — |

---

## 8. 致谢

白杨 (YuQuan) DDR4 控制器由以下团队开发：

- **北京开源芯片研究院 (BOSC)**
- **中国科学院计算技术研究所 (ICT, CAS)**

白杨是目前唯一接近流片级的开源 DDR4 控制器，为 RVDon 提供了从 FPGA 验证到 ASIC 流片的可控 DRAM 访问路径。

白杨许可证: MulanPSL-2.0 — 详见 [MulanPSL-2.0](http://license.coscl.org.cn/MulanPSL2)

---

## 9. 参考文献

1. OpenXiangShan/YuQuan — https://github.com/OpenXiangShan/YuQuan
2. Vortex RISC-V GPGPU — https://github.com/vortexgpgpu/vortex
3. DFI 3.1 Specification — JEDEC Standard No. 21-C
4. DDR4 SDRAM Standard — JEDEC JESD79-4
5. CIRCT MLIR-based Hardware Compiler — https://github.com/llvm/circt

---

*© 2024-2026 DiVo Gen²AI — 王掬琅（Peter Wang）· 王潇奕（Shawn Wang）*
