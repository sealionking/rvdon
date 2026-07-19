# RVDon YuQuan DDR4 MC 集成验证套件

> **验证方案 A: 二进制 + 时间指纹**
> 
> 本套件让第三方无需访问 RVDon RTL 源码即可验证白杨 (YuQuan) DDR4 控制器
> 确实被集成到 RVDon (Vortex GPGPU) 中。

## 背景

RVDon (RISC-V Domain-specific Open Node) 基于 Vortex RISC-V GPGPU，扩展了
Pairformer Extension (PF Extension) 用于 AlphaFold3/Proteinix Pairformer 硬件加速。

在 Phase M0 集成中，我们将白杨 (YuQuan) DDR4 控制器集成到 Vortex 的内存子系统中，
替代了原有的 DramSim 行为模型。白杨由北京开源芯片研究院 (BOSC) / 中科院计算所 (ICT)
开发，基于 Mulan PSL v2 许可证。

## 验证原理

从软件视角看内存就是内存——无法直接区分 DramSim vs 白杨 MC。但白杨 MC 有 DramSim
不具备的时序特征（初始化延迟、协议栈开销），这些特征在 Verilator 编译产物中留下了
不可伪造的"指纹"。

### 证据链

| # | 证据类型 | 验证方法 | 不可伪造原因 |
|---|---------|---------|------------|
| 1 | **二进制差异** | 对比两个 .so 文件大小 + ELF 段分析 | 白杨版 6.4M vs DramSim 版 3.4M；.text 段 2.28× 差异 |
| 2 | **符号表指纹** | `nm -D` 提取动态符号 | 白杨版含 236 个白杨特有唯一符号 (yq_wrapper/mc_top/CmdStation/CommandGen/SCG/yq_axi) |
| 3 | **字符串指纹** | `strings` 提取可读字符串 | 白杨版含 Chisel 源码断言 (dfiphasectrl.scala:120) |
| 4 | **时间指纹** | 运行同一 kernel 对比时间 | 白杨版 ~12 分钟 vs DramSim ~3 秒 (240x 差异) |

## 套件内容

```
rvdon-verify-yuquan/
├── librtlsim_yuquan.so      # 白杨版仿真库 (6.4M) — 从 GitHub Release 下载
├── librtlsim_dramsim.so     # DramSim版仿真库 (3.4M) — 从 GitHub Release 下载
├── verify_yuquan.py          # 验证脚本
├── PROMPT.md                 # 红队独立验证任务说明
└── README.md                 # 本文件
```

> **下载 .so 文件**: 由于文件体积较大，两个 .so 文件通过 [GitHub Release](https://github.com/sealionking/rvdon/releases) 分发。
> 下载后放入本目录即可运行验证。

## 使用方法

### 前提条件

- Linux x86_64 系统
- 标准工具: `nm`, `strings` (binutils)
- Python 3.6+

### 运行验证

```bash
cd rvdon-verify-yuquan
python3 verify_yuquan.py
```

### 输出示例

```
验证总结: 3/3 项通过

  ✅ 全部验证通过！

  证据链:
    1. 白杨版二进制比 DramSim 版大 ~1.9 倍（包含 MC 代码）
    2. 白杨版包含 720 个白杨特有符号（Verilator 编译产物）
    3. 白杨版包含白杨相关字符串（含 Chisel 源码断言）
    4. 白杨版仿真速度比 DramSim 慢 ~240 倍（MC 初始化开销）

  结论: RVDon 确实集成了白杨 (YuQuan) DDR4 控制器，
        且集成后功能正确（kernel 执行结果与 DramSim 一致）。
```

### 保存 JSON 结果

```bash
python3 verify_yuquan.py --json results.json
```

## 关键发现详解

### 1. 符号表中的白杨模块层次

白杨版 `librtlsim_yuquan.so` 包含以下特有符号（Demangled 名称中的层次路径）：

> **注意**: 以下为 per-keyword 命中次数（同一条符号可能匹配多个关键词）。
> 去重后唯一符号共 236 个（DramSim 版为 0）。

```
rtlsim_shim.yq_wrapper.u_mc_top.u_scg.CommandGen     (104 条)
rtlsim_shim.yq_wrapper.u_mc_top.u_scg.CmdStation      (115 条)
rtlsim_shim.yq_wrapper.u_mc_top.u_scg.SCG              (98 条)
rtlsim_shim.yq_wrapper.u_mc_top                         (201 条)
rtlsim_shim.yq_wrapper                                  (202 条)
rtlsim_shim.yq_wrapper.yq_axi_adapter                    (16 条)
rtlsim_shim.yq_wrapper.tag_buf                           (16 条)
```

这对应白杨 DDR4 MC 的内部模块层次：
- `mc_top` → 顶层 MC 封装
- `scg` → Scheduling Group（调度组）
- `CmdStation` → 命令调度站（管理 DDR4 命令队列）
- `CommandGen` → 命令生成器（生成 ACT/READ/WRITE/REFRESH 等 DDR4 命令）
- `yq_axi_adapter` → AXI4 ↔ 白杨接口适配器
- `tag_buf` → 白杨适配器中的 tag buffer

### 2. 字符串中的 Chisel 源码断言

白杨版二进制中嵌入了白杨 Chisel 源码的断言信息：

```
at dfiphasectrl.scala:120 assert(!(io.init_process & hasrefreqs))
at dfiphasectrl.scala:121 assert(!(io.init_process & hasnormalreqs))
at dfiphasectrl.scala:122 assert(!(hasrefreqs & hasnormalreqs))
```

这证明白杨 RTL 经过了完整的编译链路：
**Chisel → FIRRTL → Verilog → Verilator C++**

### 3. Verilator 编译不可逆性

`librtlsim_yuquan.so` 是 Verilator 将 RTL 编译为 C++ 再编译为机器码的产物。
Verilator 编译是**不可逆的**——无法从二进制还原 RTL 源码，但可以验证二进制
确实包含白杨模块的编译产物。

## 验证方案 B（中期规划）

方案 A 仅提供"二进制级别"的证据。方案 B 将开放以下不含 PF Extension IP 的
源码文件，提供"源码级别"的证据：

| 文件 | 内容 | 是否含 PF IP |
|------|------|:-----------:|
| `VX_yuquan_wrapper.sv` | AXI4↔白杨适配器 + APB3 初始化 + mc_ready 门控 | ❌ |
| `VX_dfi_sim_model.sv` | DFI 3.1 简易仿真响应模型 | ❌ |

这两个文件是白杨集成的基础设施，不包含 PF Extension 的核心算法。

## 独立审查记录

### DeepSeek 红队审查 (2026-07-19)

**结论**: ✅ PASS

DeepSeek 作为独立第三方红队审查员，在仅访问本验证套件（无任何 DiVo 开发目录访问）的
条件下，完成了 17 个步骤的独立验证，确认白杨 DDR4 MC 集成有效。

**核心发现**:
1. 符号指纹: 白杨版独有 256 个唯一动态符号，DramSim 版 = 0
2. Chisel 断言: 8 条 `.scala:行号` 断言（DFIPhaseCtrl.scala:120-124 等）
3. 代码量: .text 段 2.29×（5.35 MB vs 2.34 MB），反汇编确认为合法 x86-64 指令
4. AXI4 适配器: yq_axi_adapter + tag_buf 82 条 — AXI4 ↔ 白杨接口层证据
5. 编译链路: Verilator 中间产物文件名确认 Chisel → FIRRTL → Verilog → Verilator C++ 完整链路

**DeepSeek 发现的脚本问题**（已修复）:
- 原脚本符号计数 "720" 是关键词命中次数简单求和，而非去重后的唯一符号数
- 一条符号如 `yq_wrapper.u_mc_top.u_scg.CommandGen` 同时匹配多个关键词导致重复计数
- 修复: 添加 `count_unique_keyword_symbols()` 去重函数，输出同时展示求和与去重数字

## 版权声明

- **RVDon PF Extension**: Copyright © 2024-2026 DiVo Gen²AI — 王掬琅（Peter Wang）· 王潇奕（Shawn Wang）
- **白杨 (YuQuan) DDR4 控制器**: Copyright © 2021-2026 BOSC / ICT CAS. Mulan PSL v2.
- **Vortex RISC-V GPGPU**: Apache 2.0. [vortexgpgpu/vortex](https://github.com/vortexgpgpu/vortex)

---

*本验证套件由 DiVo Gen²AI 提供，目的是让第三方独立验证白杨 DDR4 MC 集成的有效性，
无需访问任何专有 RTL 源码。*
