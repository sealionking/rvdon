# DiVo Gen²AI RVDon 开源计划

> 日期：2026-07-02
>
> 状态：**已批准，启动执行**

---

## 1 开源决策

### 1.1 决策依据

| 因素 | 判断 |
|------|------|
| 技术栈根底 | 整个项目建立在 Vortex（Apache 2.0）开源基础上，闭源自己的扩展逻辑不一致 |
| 商业护城河 | RTL 是设计图纸，真正的壁垒在芯片制造和产品集成；PF 扩展的算法思路（三角掩码、在线 softmax）已在公开文献中 |
| 客户信任 | 闭源加速卡在国内市场面临供应商锁定顾虑；开源消除黑盒问题 |
| 开发效率 | FPGA 原型验证是下一阶段瓶颈，开源可吸引社区在不同 FPGA 板上验证 |
| 学术影响 | 高校/研究所是生物计算加速的天然用户，开源才能被论文引用和复现 |
| 生态对齐 | RISC-V 成功验证了"开放架构 + 商业实现"模式 |

### 1.2 许可证

**Apache 2.0**，与 Vortex 上游保持一致。

---

## 2 代码修改范围盘点

### 2.1 RVDon 全新文件（7 个）

| 文件 | 类型 | 行数 | 说明 |
|------|------|------|------|
| `hw/rtl/tcu/VX_tcu_fa.sv` | RTL | 637 | Flash Attention Online Softmax 流水线 |
| `sw/kernel/include/vx_pf.h` | 头文件 | ~80 | Pairformer Extension intrinsics |
| `tests/regression/pf_tcu/kernel.cpp` | 测试 | ~200 | PF_TMM / FA_SOFTMAX 设备端测试 |
| `tests/regression/pf_tcu/main.cpp` | 测试 | ~350 | Host 端验证 |
| `tests/regression/pf_tcu/common.h` | 测试 | ~30 | 公共定义 |
| `tests/regression/pf_tcu/Makefile` | 构建 | ~50 | 测试构建脚本 |
| `sim/rtlsim/verilator.vlt` 补丁 | Lint | ~15 | DiVo 抑制规则 |

### 2.2 上游文件修改（13 个）

| 文件 | 修改程度 | 说明 |
|------|----------|------|
| `VX_config.toml` | 小 | 新增 3 个 PF 配置项 |
| `hw/VX_config.vh` | 小 | 新增 PF 宏定义 |
| `sw/VX_config.h` | 小 | 新增 PF C 宏定义 |
| `hw/rtl/VX_gpu_pkg.sv` | 小 | 新增 4 个指令操作码 |
| `hw/rtl/tcu/VX_tcu_pkg.sv` | 小 | 新增 PF trace 打印 |
| `hw/rtl/core/VX_decode.sv` | 小 | 新增 funct3=3/4/5 解码 |
| `hw/rtl/tcu/VX_tcu_core.sv` | 大 | 三角遮罩 + 因果遮罩 + FA_SOFTMAX 旁路 |
| `hw/rtl/tcu/VX_tcu_uops.sv` | 中 | PF 指令 uop 展开 + NRC=8 强制 |
| `hw/rtl/tcu/VX_tcu_wgmma.sv` | 中 | PF 指令共享 WGMMA 数据通路 |
| `hw/rtl/core/VX_uop_sequencer.sv` | 小 | PF 指令序列化 |
| `sim/simx/types.h` | 小 | PF 枚举 + 辅助函数 |
| `sim/simx/decode.cpp` | 小 | PF 指令解码 |
| `sim/simx/tcu/tcu_unit.cpp` | 大 | PF_TMM + FA 功能模拟 |

---

## 3 分层开源策略

| 层级 | 内容 | 开源时机 | 理由 |
|------|------|----------|------|
| **L0 架构规范** | PF 扩展 ISA 定义、寄存器映射、编程模型 | **立即** | ISA 级规范，越多人用越好，类似 RISC-V 扩展 |
| **L1 RTL 实现** | VX_tcu_fa.sv、PF_TMM/PF_FA 逻辑、uop 扩展 | **Phase 2.4 验证后** | 等测试 0 错误，确保代码质量可对外 |
| **L2 仿真模型** | SimX PF_TMM/FA 行为模型 | **Phase 2.4 验证后** | 与 RTL 同步 |
| **L3 测试用例** | pf_tcu 回归测试 | **Phase 2.4 验证后** | 与 RTL 同步 |
| **L4 工具链** | LLVM intrinsic、驱动、SDK | **FPGA 验证后** | 需要硬件配合验证 |
| **L5 文档** | 设计文档、调试记录、phase 报告 | **持续** | 随开发进度逐步公开 |

---

## 4 时间节点

| 里程碑 | 目标时间 | 交付物 |
|--------|----------|--------|
| M0: 项目框架搭建 | 2026-07-02 | README.md、ARCHITECTURE.md、CONTRIBUTING.md、LICENSE |
| M1: ISA 规范发布 | 2026-07-03 | rvdon-isa-spec.md（PF 扩展指令集规范 v0.1） |
| M2: RTL 首次发布 | Phase 2.4 通过后 | VX_tcu_fa.sv + 全部修改补丁 + 测试 |
| M3: SimX 模型发布 | M2 后 1 周 | SimX PF_TMM/FA 行为模型 |
| M4: FPGA 验证 | Phase 3 完成后 | FPGA bitstream + 验证报告 |
| M5: SDK 发布 | FPGA 验证后 | LLVM intrinsic + 驱动 + 示例程序 |

---

## 5 代码组织策略

RVDon 以 Vortex fork 形式维护，通过清晰标注区分上游代码和 RVDon 扩展：

- 所有 RVDon 新增/修改处标注 `DiVo Gen²AI RVDon` 注释
- 新增文件头部标注 `Copyright (C) 2024-2026 DiVo Gen²AI (王掬琅 Peter Wang · 王潇奕 Shawn Wang)`
- 修改上游文件时保留原始 Apache 2.0 版权头
- 通过 `VX_CFG_TCU_PF_*_ENABLE` 条件编译宏隔离，禁用时回退到原版 Vortex

### Git 分支策略

```
main          ← Vortex 上游同步
  └── rvdon   ← RVDon PF 扩展开发主线
       └── rvdon-v0.1  ← 首个开源发布标签
```

---

## 6 社区运营

### 6.1 代码仓库

- GitHub: [sealionking/rvdon](https://github.com/sealionking/rvdon)
- 镜像: Gitee（国内访问）

### 6.2 文档站点

- GitHub Pages: 架构规范 + API 文档 + 设计笔记
- 随代码仓库同步更新

### 6.3 贡献者引导

- CONTRIBUTING.md 明确代码风格、提交规范、PR 流程
- 优先接收：bug 修复、FPGA 验证、新架构移植、文档改进
- PF 扩展新指令需先通过 RFC 流程

---

## 7 风险与缓解

| 风险 | 概率 | 影响 | 缓解 |
|------|------|------|------|
| 竞争对手复制设计 | 低 | 低 | PF 扩展针对 Protenix Pairformer，场景窄；真正壁垒在芯片制造 |
| 社区参与度低 | 中 | 中 | 通过学术合作（天冬酰胺酶管线 benchmark）吸引第一批用户 |
| 上游 Vortex 不兼容变更 | 低 | 高 | 条件编译隔离；定期同步上游 |
| 代码质量问题影响声誉 | 中 | 中 | Phase 2.4 验证后再发布 RTL；CI 自动化测试 |

---

## 8 第一步行动

- [x] 编写开源计划（本文档）
- [ ] 创建 README.md
- [ ] 创建 ARCHITECTURE.md（含 PF 扩展 ISA 规范）
- [ ] 创建 CONTRIBUTING.md
- [ ] 添加 Apache 2.0 LICENSE
- [ ] 完成 Phase 2.4 FA_SOFTMAX 修复（3 个 bug）
- [ ] 重跑测试确认 0/128 错误
- [ ] 创建 GitHub 仓库并推送
