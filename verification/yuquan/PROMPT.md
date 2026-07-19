# 独立验证任务：RVDon YuQuan DDR4 MC 集成有效性

## 你的角色

你是一名独立的第三方硬件验证工程师（红队）。你的任务是从零开始，仅凭本目录中提供的材料，独立验证 DiVo Gen²AI 公司声称的"已将白杨 (YuQuan) DDR4 控制器集成到 RVDon (Vortex RISC-V GPGPU) 中"这一声明。

**你没有任何 DiVo 内部代码的访问权限。** 你只能看到本目录中的文件。

## 背景

### 项目背景
- RVDon = RISC-V Domain-specific Open Node，基于 Vortex RISC-V GPGPU (Apache 2.0)
- 白杨 (YuQuan) = 开源 DDR4 控制器，由北京开源芯片研究院 (BOSC) / 中科院计算所 (ICT CAS) 开发，Mulan PSL v2 许可证
- DiVo Gen²AI 声称已完成白杨 DDR4 MC 与 Vortex 的集成

### 技术背景
- Vortex 使用 Verilator 将 RTL 编译为 C++ 共享库 (`librtlsim.so`) 用于仿真
- 原始 Vortex 使用 DramSim（行为模型）模拟 DRAM
- 白杨集成后，内存子系统改为通过白杨 DDR4 MC → DFI 3.1 接口访问内存
- 两套方案互斥：`VX_CFG_YUQUAN_MC_ENABLE` 宏控制编译哪一套

### 白杨 DDR4 MC 的内部模块层次（公开信息，来自白杨开源仓库）
```
mc_top                    — 顶层 MC 封装
  └─ scg                  — Scheduling Group（调度组）
      ├─ CmdStation       — 命令调度站（管理 DDR4 命令队列）
      ├─ CommandGen       — 命令生成器（生成 ACT/READ/WRITE/REFRESH 等 DDR4 命令）
      └─ DFIPhaseCtrl    — DFI 初始化相位控制器
```
白杨使用 Chisel 开发，经 CIRCT firtool 编译为 Verilog。

## 你手里的材料

```
rvdon-verify-yuquan/
├── librtlsim_yuquan.so      # 声称包含白杨 MC 的仿真库
├── librtlsim_dramsim.so     # 声称不含白杨 MC 的仿真库（对照组）
├── verify_yuquan.py          # DiVo 提供的验证脚本（你不应直接信任它）
├── README.md                 # DiVo 的说明文档（你不应直接信任它）
├── results.json              # DiVo 的验证结果（你不应直接信任它）
└── PROMPT.md                 # 本文件（你的任务说明）
```

## 你的任务

### 第1步：不信任，先验证工具

1. 检查 `nm` 和 `strings` 命令是否可用
2. 自己手动运行 `nm -D librtlsim_yuquan.so | grep yq_wrapper` 看看有没有输出
3. 自己手动运行 `nm -D librtlsim_dramsim.so | grep yq_wrapper` 看看有没有输出
4. 自己手动运行 `strings librtlsim_yuquan.so | grep -i yuquan` 看看有什么
5. 自己手动运行 `strings librtlsim_dramsim.so | grep -i yuquan` 看看有什么

### 第2步：独立分析二进制文件

用你自己的方法（不限于此列表），对两个 .so 文件进行独立分析：

1. **文件基本信息**: `file`, `readelf -h`, `ls -l`
2. **动态符号表**: `nm -D`, `readelf -s`
3. **字符串提取**: `strings -n 6`
4. **ELF 段分析**: `readelf -S`, `readelf -d`
5. **反汇编抽样**: `objdump -d` 抽样几个白杨特有函数
6. **文件哈希**: `md5sum`, `sha256sum`

### 第3步：验证 DiVo 的声明

DiVo 的验证脚本 `verify_yuquan.py` 声称：
1. 白杨版比 DramSim 版大 1.9 倍
2. 白杨版包含 720 个白杨特有符号
3. 白杨版包含 6 个白杨特有字符串关键词

**你需要独立验证这些数字是否准确。** 不要直接运行他们的脚本，用你自己的方法算一遍。

### 第4步：寻找 DiVo 脚本可能遗漏的证据

DiVo 的脚本可能遗漏了一些证据。请检查：

1. 白杨版中是否有 Chisel/FIRRTL 相关的断言字符串？（搜索 `.scala:` 模式）
2. 两个 .so 的 ELF 段差异是什么？（白杨版多出哪些段？）
3. 白杨版中是否有 DFI 协议相关的字符串？（搜索 `dfi_` 模式）
4. 符号表中是否有白杨的 AXI4 接口相关符号？（搜索 `axi` 模式）
5. 白杨版独有但 DramSim 版没有的字符串有多少条？

### 第5步：评估反伪造论证

DiVo 声称这些证据"不可伪造"。请评估：

1. 有人能否在不实际包含白杨 RTL 的情况下，在 .so 中伪造这些符号？
2. `strings` 输出中的 Chisel 源码断言能否被伪造？
3. 文件大小差异能否通过其他方式（如静态链接其他库）制造？
4. 如果有人要伪造所有这些证据，需要付出多大代价？

### 第6步：写验证报告

写一份独立验证报告（中文），包含：

1. **验证方法**：你用了哪些工具和步骤
2. **原始数据**：你手动收集的数据（不是 DiVo 脚本输出的）
3. **独立验证结果**：你的数字 vs DiVo 的数字，是否一致
4. **新发现**：DiVo 脚本可能遗漏的证据
5. **反伪造评估**：这些证据的可信度
6. **最终结论**：
   - PASS：确认白杨集成有效
   - PARTIAL：部分确认，有保留
   - FAIL：无法确认

## 约束

1. **不要访问 DiVo 的开发目录** — 你只有本目录中的文件
2. **不要直接信任 DiVo 的脚本输出** — 用你自己的方法独立验证
3. **不要假设任何事实** — 每个结论都要有证据支撑
4. **如果发现不一致，务必指出** — 这是红队验证的核心价值
5. **不要客气** — 如果发现漏洞或问题，直接指出

## 预期工作时长

约 30-60 分钟。重点在质量而非速度。
