# Contributing to RVDon

感谢你对 RVDon 项目的关注！本文档说明如何参与贡献。

---

## 代码仓库结构

RVDon 是 Vortex RISC-V GPGPU 的 fork，所有 RVDon 扩展通过以下方式标识：

- 新增文件头部标注 `Copyright (C) 2024-2026 DiVo Gen²AI`
- 修改上游文件处标注 `DiVo Gen²AI RVDon` 注释
- 条件编译宏 `VX_CFG_TCU_PF_*_ENABLE` 隔离扩展功能

---

## 贡献类型

### 欢迎的贡献

- **Bug 修复**：RTL、SimX、测试中的 bug 修复
- **FPGA 验证**：在不同 FPGA 平台上的验证报告和适配代码
- **文档改进**：架构规范补充、使用教程、调试指南
- **新架构移植**：将 PF 扩展适配到不同 NT 配置（NT=4/16/32）
- **性能优化**：VX_tcu_fa.sv 的 exp 近似精度改进、流水线优化

### 需要 RFC 的贡献

- **新 PF 指令**：新增指令需先提交 RFC（Request for Comments），讨论编码空间分配、语义定义、与现有指令的交互
- **TCU 数据通路变更**：修改 WGMMA 数据通路或 uop 展开逻辑的 PR 需附带详细的正确性论证

---

## 开发环境

```bash
# 依赖
sudo apt install verilator libfl-dev  # RTL 仿真
# GCC RISC-V 交叉编译器（见 Vortex 文档）

# 构建
cd rvdon
make -C build64/sim/rtlsim

# 测试
cd build64/tests/regression/pf_tcu
make run-rtlsim
```

---

## 代码规范

### SystemVerilog

- 遵循 Vortex 上游代码风格
- 新增模块使用 `VX_tcu_*.sv` 命名
- 条件编译使用 `ifdef VX_CFG_TCU_PF_*_ENABLE` 包裹
- 所有 RVDon 新增/修改处标注 `DiVo Gen²AI RVDon`

### C/C++

- 遵循 Vortex 上游代码风格
- SimX 扩展在 `tcu_unit.cpp` 中新增 `case TcuType::PF_*` 分支
- Intrinsics 在 `vx_pf.h` 的 `rvdon::pf` 命名空间中定义

### 提交信息

```
[PF_TMM] 简短描述

详细说明修改内容和原因。
```

前缀：`[PF_TMM]`、`[PF_FA]`、`[SIMX]`、`[TEST]`、`[DOC]`、`[BUILD]`

---

## PR 流程

1. Fork 仓库，从 `rvdon` 分支创建 feature 分支
2. 确保所有现有测试通过（`make run-rtlsim` in pf_tcu）
3. 新功能需附带测试用例
4. 提交 PR，描述修改内容和测试结果
5. 维护者 review 后合并

---

## 测试

### 回归测试

```bash
cd build64/tests/regression/pf_tcu
make run-rtlsim
```

期望输出：`PASSED`（WGMMA 0 错误，PF_TMM 0 错误，PF_FA TBD）

### SimX 功能测试

```bash
cd build64/tests/regression/pf_tcu
make run-simx
```

---

## 问题反馈

- GitHub Issues：bug 报告、功能请求
- 标签：`bug`、`enhancement`、`pf-tmm`、`pf-fa`、`fpga`、`documentation`

---

## 许可证

提交的贡献按 Apache License 2.0 授权，与项目主许可证一致。

---

© 2024-2026 DiVo Gen²AI — [wangjueju.cn](https://wangjueju.cn) · [jueju.wang](https://jueju.wang)
