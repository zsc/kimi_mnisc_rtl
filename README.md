# Low-bit Conv3x3 FPGA Accelerator (低比特卷积加速器)

基于 Megvii 风格的低比特 Conv3x3 FPGA 加速器 RTL 实现，支持 2/4/8/16-bit 混合精度计算。

[![Verilog](https://img.shields.io/badge/Language-SystemVerilog-blue)](https://ieeexplore.ieee.org/document/8299585)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

## 📋 目录

- [项目简介](#-项目简介)
- [特性](#-特性)
- [架构](#-架构)
- [快速开始](#-快速开始)
- [文件结构](#-文件结构)
- [参数配置](#-参数配置)
- [性能指标](#-性能指标)
- [验证状态](#-验证状态)
- [参考文献](#-参考文献)

---

## 🎯 项目简介

本项目实现了一个层处理（Layer-wise）的低比特卷积神经网络加速器，专为 FPGA 部署优化设计。核心计算采用查找表（LUT）实现 2-bit 乘加操作，无需 DSP 资源，通过无符号累加树和 inter-cycle 累加实现高效卷积计算。

### 核心设计特点

- **纯 LUT 实现**: 2-bit 乘加使用查找表，零 DSP 使用
- **混合精度**: 支持 2/4/8/16-bit Activation 与 Weight 任意组合
- **高并行度**: 16×16 2-bit slice lanes 并行计算
- **层处理架构**: 整层权重缓存，减少 DDR 访问

---

## ✨ 特性

### 支持的配置

| 参数 | 支持值 | 备注 |
|:-----|:------|:-----|
| 卷积核 | 3×3 (固定) | KH=KW=3 |
| 步长 | 1, 2 | 可配置 |
| Activation 位宽 | 2, 4, 8, 16-bit | 运行时配置 |
| Weight 位宽 | 2, 4, 8, 16-bit | 运行时配置 |
| 输入尺寸 | ≤ 256×256 | 参数化可调整 |
| 通道数 | ≤ 256 (IC/OC) | 参数化可调整 |

### 数据格式

**2-bit 编码映射** (decode2):
```
2'b00 → -3    2'b01 → -1
2'b10 → +1    2'b11 → +3
```

**高 bit 数值重建**:
```
valN = Σ decode2(slice_s) << (2×s)
```

### MVP 限制

- 不支持同时 `act_bits>2` 且 `wgt_bits>2`
- 仅支持 Valid 卷积（无 Padding）
- Batch = 1（单样本处理）

---

## 🏗️ 架构

### 系统架构图

```
┌─────────────────────────────────────────────────────────────┐
│                    conv3x3_accel_top                        │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│  │   Weight    │    │   Feature   │    │    Conv     │     │
│  │   Buffer    │───→│ Line Buffer │───→│    Core     │     │
│  │  (Layer)    │    │  (3 Rows)   │    │  (16×16)    │     │
│  └─────────────┘    └─────────────┘    └──────┬──────┘     │
│        ↑                                       │            │
│   wgt_in_*                                partial│acc       │
│        │                                       ↓            │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│  │    DDR      │    │   Output    │←───│  Other Ops  │     │
│  │  (Stream)   │    │   Packer    │    │   (Stub)    │     │
│  └─────────────┘    └──────┬──────┘    └─────────────┘     │
│                            │                                │
│                       out_*                                 │
└─────────────────────────────────────────────────────────────┘
```

### 关键模块

| 模块 | 功能 | 代码行数 |
|:-----|:-----|:-------:|
| `muladd2_lut` | 2-bit LUT 乘加单元 | 60 |
| `conv_core_lowbit` | 卷积核心计算引擎 | 280 |
| `feature_line_buffer` | 3行特征图缓冲 + 窗口生成 | 570 |
| `weight_buffer` | 整层权重缓存 | 350 |
| `output_packer` | 输出数据打包 | 180 |
| `conv3x3_accel_top` | 顶层控制 + 系统集成 | 790 |

---

## 🚀 快速开始

### 环境要求

- **Verilog 仿真器**: Icarus Verilog (iverilog) ≥ 11.0 或 Verilator ≥ 5.0
- **C++ 编译器**: GCC/Clang (支持 C++17)
- **波形查看**: GTKWave (可选)

### 克隆项目

```bash
git clone <repo-url>
cd kimi_mnisc_rtl
```

### 运行单元测试

**1. LUT 模块测试** (推荐)
```bash
iverilog -o tb_simple.vvp tb/tb_simple.v && vvp tb_simple.vvp
```

**2. 卷积核心测试**
```bash
iverilog -o tb_conv_core.vvp tb/tb_conv_core.sv && vvp tb_conv_core.vvp
```

### 完整系统仿真 (Verilator)

```bash
# 编译
verilator --cc --exe --build --trace -j 0 -Wno-fatal \
  --top-module conv3x3_accel_top \
  rtl/*.sv tb/tb_top.cpp -Mdir obj_dir

# 运行仿真
./obj_dir/Vconv3x3_accel_top
```

### Vivado 综合 (可选)

```tcl
read_verilog -sv rtl/*.sv
synth_design -top conv3x3_accel_top -part xc7k325tffg900-2
report_utilization
report_timing
```

---

## 📁 文件结构

```
kimi_mnisc_rtl/
├── rtl/                          # RTL 源代码
│   ├── muladd2_lut.sv            # LUT 乘加单元
│   ├── conv_core_lowbit.sv       # 卷积核心
│   ├── feature_line_buffer.sv    # 特征图行缓冲
│   ├── weight_buffer.sv          # 权重缓存
│   ├── output_packer.sv          # 输出打包
│   ├── other_ops_stub.sv         # 后处理占位
│   └── conv3x3_accel_top.sv      # 顶层模块
│
├── tb/                           # 测试平台
│   ├── tb_conv3x3_accel.sv       # 完整测试平台
│   ├── tb_top.cpp                # Verilator C++ 测试
│   ├── tb_simple.v               # LUT 单元测试
│   └── tb_conv_core.sv           # 卷积核测试
│
├── AGENTS.md                     # 详细设计规格 (AGENTS)
├── REPORT.md                     # 详细实现报告
├── VERIFICATION_REPORT.md        # 验证报告
└── README.md                     # 本文件
```

**代码统计**:
- RTL: 2,275 行 SystemVerilog
- Testbench: 2,000+ 行 (SV + C++)
- 总计: ~4,300 行

---

## ⚙️ 参数配置

### 顶层参数

```systemverilog
conv3x3_accel_top #(
    .BUS_W(128),        // 数据总线位宽
    .IC2_LANES(16),     // Activation 并行度
    .OC2_LANES(16),     // Weight 并行度
    .MAX_W(256),        // 最大宽度
    .MAX_H(256),        // 最大高度
    .MAX_IC(256),       // 最大输入通道
    .MAX_OC(256),       // 最大输出通道
    .ACC_W(32)          // 累加器位宽
)
```

### 运行时配置

通过 `cfg_*` 端口配置每层参数:

```systemverilog
// 特征图尺寸
cfg_W, cfg_H          // 输入宽/高
cfg_IC, cfg_OC        // 输入/输出通道数
cfg_stride            // 0=1, 1=2

// 位宽配置
cfg_act_bits          // 2, 4, 8, 16
cfg_wgt_bits          // 2, 4, 8, 16
```

### 对齐要求

```
IC % IC_CH_PER_CYCLE == 0
OC % OC_CH_PER_CYCLE == 0

其中:
- IC_CH_PER_CYCLE = 16 / (act_bits / 2)
- OC_CH_PER_CYCLE = 16 / (wgt_bits / 2)
```

---

## 📊 性能指标

### 理论吞吐

| 配置 | 每周期 MAC | @200MHz |
|:-----|:----------:|:-------:|
| 2b × 2b | 2,304 | 460.8 GOPS |
| 4b × 2b | 1,152 | 230.4 GOPS |
| 2b × 4b | 1,152 | 230.4 GOPS |

### 资源占用预估 (Xilinx Kintex-7)

| 资源 | 预估用量 | 可用 | 利用率 |
|:-----|:--------:|:----:|:------:|
| LUT | ~14,000 | 203,800 | 6.9% |
| FF | ~6,300 | 407,600 | 1.5% |
| BRAM36 | 24 | 890 | 2.7% |
| DSP48 | 0 | 840 | 0% |

### 存储需求

| 模块 | 容量 |
|:-----|:-----|
| Feature Line Buffer | ~3.1 Mbits (3×256×256×16b) |
| Weight Buffer | ~9.4 Mbits (256×256×9×16b) |
| **总计** | **~12.6 Mbits (~1.6 MB)** |

---

## ✅ 验证状态

| 检查项 | 状态 | 工具 |
|:-------|:----:|:-----|
| 语法检查 | ✅ 通过 | iverilog, Verilator |
| LUT 单元 | ✅ 通过 | iverilog (256/256) |
| 卷积核心 | ✅ 通过 | iverilog (5/5) |
| 系统编译 | ✅ 通过 | Verilator |
| Latch 检查 | ✅ 通过 | Verilator |

**修复记录**:
- ✅ 修复 `weight_buffer.sv` always_comb latch 问题
- ✅ 修复 `conv_core_lowbit.sv` always_comb latch 问题  
- ✅ 修复 `feature_line_buffer.sv` always_comb latch 问题

**已知问题**:
- 完整系统仿真因设计复杂度高需要较长时间
- 建议小规模测试 (W=4, H=4, IC=8, OC=8) 用于调试

---

## 📝 使用示例

### 配置并运行一层卷积

```systemverilog
// 1. 复位
rst_n = 0; #100;
rst_n = 1;

// 2. 发送配置
cfg_valid = 1;
cfg_W = 8; cfg_H = 8;
cfg_IC = 16; cfg_OC = 16;
cfg_stride = 0;      // stride=1
cfg_act_bits = 2;    // 2-bit activation
cfg_wgt_bits = 2;    // 2-bit weight
wait(cfg_ready);
cfg_valid = 0;

// 3. 启动
start = 1; #10;
start = 0;

// 4. 发送权重 (通过 wgt_in_* 接口)
// 5. 发送特征图 (通过 act_in_* 接口)
// 6. 接收结果 (通过 out_* 接口)
// 7. 等待 done
wait(done);
```

---

## 📚 参考文献

1. AGENTS.md - 本项目详细设计规格
2. REPORT.md - 实现详细报告
3. VERIFICATION_REPORT.md - 验证报告

---

## 📄 许可

MIT License

---

## 🤝 贡献

欢迎 Issue 和 PR！

---

**项目状态**: 🚧 MVP 阶段 | **最后更新**: 2026-02-13

### 最近更新
- **2026-02-13**: 修复所有 always_comb 块中的 latch 问题，确保组合逻辑完整性
