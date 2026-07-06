# RVDon 产品形态与内存子系统 IP 授权方案

**文档编号**: RVDon-TN-014
**版本**: v1.0
**日期**: 2026-07-07
**状态**: Draft
**编写**: DiVo Gen²AI

---

## 1 概述

RVDon PF Extension 已完成功能验证（rtlsim 7/7 PASSED, 红队独立验证通过, 28nm 综合报告完成）。本文档定义 RVDon 加速卡的具体产品形态和内存子系统 IP 授权策略。

**核心设计理念**：带宽是伪问题，容量是唯一硬约束。用户自插 DDR4 内存条 = 零库存风险 + 垃圾佬友好。

---

## 2 产品形态

### 2.1 28nm 丐版（先发, 2 DIMM Slots）

```
┌─────────────────────────────────────────┐
│  [DIMM 0]  [DIMM 1]                    │ ← 2× DDR4-288pin 插槽
│                                         │
│         ┌──────────┐                    │
│         │ RVDon    │                    │ ← ASIC ~4mm², BGA 封装
│         │ 28nm Die │                    │
│         └──────────┘                    │
│                                         │
│  ┌────────────────────┐                │
│  │ 铝散热片            │                │ ← 被动散热 (~4W TDP)
│  └────────────────────┘                │
│                                         │
│████████████████                         │ ← PCIe 4.0 x8 金手指
└─────────────────────────────────────────┘
```

| 参数 | 规格 | 说明 |
|------|------|------|
| 形态 | 半高半长 (low-profile, 68.9mm × ~170mm) | 适配 2U 服务器和 SFF 主机 |
| DIMM 插槽 | 2× DDR4-288pin (UDIMM 或 RDIMM) | 同类型，自动检测 |
| 最大容量 | 64GB (UDIMM) / 256GB (RDIMM) | 远超 A100 可用部分 |
| 内存带宽 | DDR4-3200 双通道 = 51.2 GB/s | Protenix 需求的 7,300× |
| PCIe | 4.0 x8 = 16 GB/s | Protenix 需求的 2,286× |
| 功耗 | < 25W (PCIe 插槽供电) | 无外接电源 |
| 散热 | 被动铝散热片 | 无风扇 |
| PCB | 4 层 FR4 | DDR4-3200 双通道容忍度高 |
| 附属 | 全高挡板 + 半高挡板各一 | 塔式和机架两用 |

### 2.2 12nm 旗舰（4 DIMM Slots）

| 参数 | 规格 |
|------|------|
| 形态 | 全高全长 (111.15mm × ~267mm) |
| DIMM 插槽 | 4× DDR4/DDR5-288pin (支持双模) |
| 最大容量 | 512GB DDR5 RDIMM / 256GB DDR4 RDIMM |
| 内存带宽 | DDR5-6400 四通道 = 204.8 GB/s |
| PCIe | 5.0 x8 = 32 GB/s |
| PCB | 6 层 (DDR5 信号完整性要求) |

### 2.3 为什么用 DIMM 插槽而不是焊接内存？

| 理由 | 说明 |
|------|------|
| 用户自主 | 用户自选容量/价格平衡——垃圾佬插二手 16GB，企业插 128GB ECC |
| 零库存风险 | 卡厂不备内存库存，裸卡出货，像主板一样 |
| 独特市场定位 | 市面上没有任何加速卡让用户自插内存——对比 NVIDIA (焊接 HBM)、国产 GPU (焊接 GDDR) |
| 即插即用 | SPD 自动检测，零配置 |

---

## 3 内存子系统 IP 产品线

### 3.1 ARM Cortex 策略

ARM 将 Cortex-A55 (入门)、A76 (高性能)、X1 (旗舰) 拆分为独立 IP 授权。DiVo 将 DDR4/DDR5 控制器按内存类型拆分：

| IP 产品 | 代号 | 支持内存类型 | 门数 (28nm) | 定位 |
|---------|------|:---:|:---:|------|
| **RVDon-MC-U4** | Street | DDR4 UDIMM | ~15K | 垃圾佬丐版 |
| **RVDon-MC-R4** | Server | DDR4 UDIMM + RDIMM (自动检测) | ~30K | 专业版 |
| **RVDon-MC-L4** | Datacenter | DDR4 UDIMM + RDIMM + LR-DIMM | ~45K | 企业版 |
| **RVDon-MC-U5** | Street5 | DDR5 UDIMM | ~20K | 12nm 丐版 |
| **RVDon-MC-R5** | Server5 | DDR5 UDIMM + RDIMM | ~40K | 12nm 专业版 |
| **RVDon-MC-DUAL** | Flex | DDR4/DDR5 全双模 | ~50K | 12nm 旗舰 |

### 3.2 技术实现策略

MC-R4 是完整设计，MC-U4 是条件编译子集（与 PF 扩展 `VX_CFG_*_ENABLE` 模式一致）：

```systemverilog
module rvdon_mc import rvdon_mc_pkg::*; #(
    parameter VX_CFG_MC_RDIMM_ENABLE  = 1,  // MC-U4=0, MC-R4=1
    parameter VX_CFG_MC_LRDIMM_ENABLE = 0,  // MC-L4=1
    parameter VX_CFG_MC_DDR5_ENABLE   = 0   // MC-DUAL=1
) (
    // DFI interface to PHY
    // AXI interface to Vortex memory subsystem
    // I2C for SPD access
    // ...
);
```

### 3.3 PHY IP 归属

DDR4/DDR5 PHY 是 Synopsys/Cadence 第三方 IP，客户自行采购。DiVo 提供：
- **PHY 选型指南** — 哪个 Synopsys part number 匹配哪个 RVDon-MC
- **PHY-Controller 集成参考** — DFI 接口 RTL wrapper
- **已验证的 PHY 配置** — 时序参数和引脚分配

---

## 4 UDIMM + RDIMM 同插槽技术分析

### 4.1 结论：同一个 288-pin 插槽可以插 UDIMM 和 RDIMM

| 对比 | UDIMM | RDIMM |
|------|-------|-------|
| 引脚定义 | 288-pin (JEDEC 标准) | 288-pin (相同) |
| 注册时钟驱动 (RCD) | 无 | 有 (地址/命令/控制线) |
| SPD byte 3 | 0x01 | 0x02 |
| ECC | 可选奇偶校验 | 72-bit SECDED |
| 单条最大容量 | 32 GB | 128 GB |

### 4.2 自动检测流程

```
Boot:
  1. DDR PHY 上电
  2. I2C 读取 SPD EEPROM
  3. 解析 SPD byte 3:
     0x01 = UDIMM → 控制器配置为 UDIMM 模式
     0x02 = RDIMM → 控制器配置为 RDIMM 模式
     0x03 = LR-DIMM → 控制器配置为 LR-DIMM 模式
  4. RDIMM: 通过 MRS 命令初始化 RCD 寄存器
  5. 执行 JEDEC DRAM 初始化序列
  6. 运行 memory training (read/write leveling)
  7. RDIMM: 启用 ECC 引擎
  8. 标记内存就绪
```

### 4.3 限制

- **同一 channel 内不能混插 UDIMM 和 RDIMM**（电气负载和时序特性不同）
- **固件检测到混插时报错**（LED 指示或驱动错误码），拒绝启动内存子系统

---

## 5 垃圾佬场景分析

### 5.1 ¥900 丐版（Protenix 开箱即用）

| 组件 | 规格 | 二手价 |
|------|------|:---:|
| RVDon 28nm Street 裸卡 | PCIe4 x8, 2× UDIMM | ¥500-700 |
| 2× DDR4-3200 32GB UDIMM | 三星/海力士/镁光 | ¥400-600 |
| **总计 64GB** | | **¥900-1,300** |

- 可运行: Protenix 蛋白质 ≤ 2000 残基
- 对比: A100 80GB = ¥150,000 → **1/115 价格**

### 5.2 ¥2,000 专业版（大蛋白质/批量推理）

| 组件 | 规格 | 二手价 |
|------|------|:---:|
| RVDon 28nm Pro 裸卡 | PCIe4 x8, 2× RDIMM | ¥1,000-1,500 |
| 2× DDR4 ECC RDIMM 128GB | 服务器退役 | ¥1,000-1,600 |
| **总计 256GB** | | **¥2,000-3,100** |

- 可运行: 核糖体级大复合物 (5000+ 残基)、病毒衣壳、批量推理
- 256GB = A100 80GB 的 **3.2 倍**，价格 **1/48**

### 5.3 垃圾佬操作步骤

1. 闲鱼淘 RVDon 28nm Street 裸卡: ¥500-700
2. 闲鱼淘 2× 32GB DDR4-3200: ¥400-600
3. 插卡 + 插内存 → 开机 → SPD 自动检测
4. `modprobe rvdon` → 安装驱动
5. `protenix predict --input protein.fasta --device rvdon`
6. 等 5 分钟/蛋白质 → **¥1,000 的私人 AlphaFold**

---

## 6 IP 授权定价

### 6.1 内存控制器 IP 单独授权

| IP 产品 | 一次性授权费 | 版税/颗 | 目标客户 |
|---------|:---:|:---:|------|
| RVDon-MC-U4 | $100K | $0.50 | 丐版卡厂 |
| RVDon-MC-R4 | $250K | $1.00 | 服务器卡厂 |
| RVDon-MC-L4 | $500K | $2.00 | 数据中心厂商 |
| RVDon-MC-DUAL | $800K | $3.00 | 旗舰产品 |

### 6.2 打包套餐 (PF Extension + Memory Controller)

| 套餐 | 内容 | 价格 | 折扣 |
|------|------|:---:|:---:|
| Bio-Entry | PF RTL + MC-U4 | $250K | 29% |
| Bio-Pro | PF RTL + 验证套件 + MC-R4 | $500K | 29% |
| Bio-Enterprise | PF RTL + 验证套件 + SDK + MC-L4 | $1M | 33% |
| Bio-Flagship | PF RTL + 全套 + MC-DUAL | $1.5M | 31% |

---

## 7 竞争定位

```
                        内存容量
                              ^
                    1 TB  *   |   RVDon 12nm 旗舰 (¥6-11K)
                    512GB *   |   RVDon 12nm Pro (¥3.6-7K)
                    256GB *   |   RVDon 28nm Pro (¥2-3.1K)
                     80GB +   |   NVIDIA A100 (¥150K)
                     64GB *   |   RVDon 28nm 丐版 (¥0.9-1.3K) ← 甜点
                     48GB +   |   NVIDIA A6000 (¥45K)
                     24GB +   |   NVIDIA L4 (¥12K)
                              +──────────────────────────> 价格 (RMB)
                              0     10K    50K   100K  150K

  * = RVDon    + = NVIDIA
```

核心交易: **带宽 (Protenix 不需要) 换容量 (Protenix 急需), 1/50 价格**

---

## 8 风险与对策

| 风险 | 严重度 | 对策 |
|------|:---:|------|
| DIMM 信号完整性 | 中 | DDR4-3200 已充分验证; 遵循 JEDEC 参考布局; TDR/VNA 验证 |
| UDIMM/RDIMM 混插误操作 | 低 | 固件自动检测 + 报错; LED 指示; 清晰文档 |
| 二手 DIMM 质量 | 中 | 固件开机自检; RDIMM 路径有 ECC; 用户接受二手风险 |
| 大容量 DIMM 机械应力 | 低 | 加固 DIMM 插槽; 全高卡支撑架; DIMM 高度规格 |
| 4 DIMM 功耗 | 低 | 4 RDIMM ~16W; PCIe 插槽 25W 预算内 |
| DDR4 市场过时 | 中 | 12nm 卡支持 DDR5; 二手 DDR4 供应 10+ 年; 越老越便宜 |

---

## 9 实施路线

| 阶段 | 时间 | 交付物 | 依赖 |
|------|------|--------|------|
| Phase 0 | 月 0-3 | MC-U4 RTL + Verilator 仿真 | PF Extension RTL |
| Phase 1 | 月 3-6 | MC-R4 RTL (MC-U4 + RDIMM) | MC-U4 验证通过 |
| Phase 2 | 月 6-9 | SPD 固件 + training sequencer | MC-R4 RTL |
| Phase 3 | 月 9-12 | 参考设计 PCB (2-DIMM, 28nm) | MC-R4 + 固件 |
| Phase 4 | 月 12-15 | MC-DUAL RTL (DDR5/DDR4, 12nm) | Synopsys DDR5 PHY |
| Phase 5 | 月 15-18 | 参考设计 PCB (4-DIMM, 12nm) | MC-DUAL 验证 |

---

## 10 与现有 IP 授权体系的集成

本文档的内存控制器 IP 产品线是对 RVDon-TN-007 (IP 授权路线) 的扩展：

```
原有 Tier 2 (IP Core License):
  PF Extension RTL + 验证套件 + 集成指南
  价格: $200K-1M/license + 版税

扩展 Tier 2 (IP Core License):
  PF Extension RTL + Memory Controller RTL + 验证 + 集成
  打包价: $250K-1.5M/license + 版税
  或分开授权: PF $200K-1M + MC $100K-800K
```

内存控制器 IP 与 PF Extension IP **独立授权、可单独购买、打包有折扣**。
