# RVDon 项目详细标准化验证清单 v1.1

> 使用说明：请严格按照以下每一项进行测试和汇报，不得遗漏、不得使用"大概""应该"等模糊词，必须给出具体数据、代码片段或截图证据。

---

## 一、基本信息（必须最先写）

- 测试日期、使用的 AI 模型
- 测试环境（Vortex commit 版本、RVDon commit、rvdon-kahan 版本、NT 配置、仿真器/FPGA 板卡）
- 编译选项和运行命令

---

## 二、硬件验证（RVDon PF Extension）

### 功能正确性

- [ ] PF_TMM（Outgoing & Incoming）回归测试结果（错误数 / 总测试数）
- [ ] PF_FLASH_ATTN 三个子操作测试结果
- [ ] SimX 与 RTL 仿真一致性（是否 0 错误）

### 精度验证

- [ ] LUT exp 近似精度（max error、mean error、16项或32项）
- [ ] Pairformer / Triangle Attention E2E cosine similarity
- [ ] 与 FP64 参考实现的相对误差
- [ ] 测试向量匹配率（至少 1000+ 向量）

### 配置鲁棒性

- [ ] NT=4 默认配置下的行为是否正常
- [ ] 切换 NT=8 后的兼容性和性能变化
- [ ] 关闭所有 PF Extension 后是否完美回退到原 Vortex

### 资源与实用性（如果在 FPGA 上）

- [ ] LUT / FF / BRAM / DSP 使用率
- [ ] 最高可达时钟频率
- [ ] 估算功耗

---

## 三、软件验证（RVDon-Kahan）

### Kahan 算法基础测试

- [ ] 大小差异大的数列求和（2000+ 项），Kahan FP32 vs Naive FP32 提升倍数
- [ ] 与 FP64 参考值的误差对比

### MD 实际场景测试

- [ ] LJ 力累加（邻居数分别测试 50、100、200、400）
- [ ] 单原子力累加相对误差
- [ ] 能量漂移（drift per step），目标 < 1e-6
- [ ] Kahan 状态是否正确贯穿单个原子的所有邻居累加（最重要！）

### API 使用检查

- [ ] `rvdon_force_acc_create`、`accum_pair`、`get` 等接口使用是否正确
- [ ] 是否存在状态管理错误

---

## 四、软硬协同测试（最核心）

### RVDon PF_TMM 硬件加速 + Kahan 补偿的完整测试

- [ ] 256~1024 原子 LJ 系统，运行 1000~5000 步 Verlet 积分
- [ ] 输出：总时间、能量守恒情况、力 RMS 误差、整体精度提升

### 与三种对比方案的结果

- [ ] 纯 Naive FP32
- [ ] 仅 RVDon 硬件（无 Kahan）
- [ ] 纯 FP64 参考

---

## 五、最终结论与风险

- [ ] 发现的所有问题、bug 或不一致点
- [ ] 与官方 ARCHITECTURE.md 设计目标的符合程度（高/中/低 + 理由）
- [ ] 潜在风险和改进建议
- [ ] **最终推荐意见**（强烈推荐 / 有条件推荐 / 不推荐）并说明理由
