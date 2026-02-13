# Low-bit Conv3x3 FPGA Accelerator (Megvii-style v1) — RTL SPEC (Vendor-agnostic)

> 目的：把你贴的设计（layer-wise、Conv3x3、Feature Line Buffer + 全层 Weight Buffer、低比特 LUT 乘加 + unsigned 加法树 + inter-cycle 累加、输出按原顺序写回）整理成可直接喂给 gemini-cli / codex 生成 SystemVerilog RTL 的 **明确规格**。  
> 本 SPEC **不依赖 Xilinx 专有 IP**（BRAM/DSP 只用综合推断），外部“DDR”先用 **ready/valid 流接口**模拟；后续你再换成 AXI/DMA 即可。

---

## 0. 总览

### 0.1 系统结构（对应原文图）
- Off-chip DRAM（此处用 stream 代替）
  - Activation 输入流 `act_in_*`
  - Weight 输入流 `wgt_in_*`
  - Output 输出流 `out_*`
- On-chip
  - `feature_line_buffer`：3 行 Line Buffer（支持 stride=1/2）
  - `weight_buffer`：一层所需全部 Weight 片上缓存（可选 ping-pong，MVP 可单 bank）
  - `conv_core_lowbit`：低比特卷积核（2-bit LUT + unsigned reduction + inter-cycle accumulate）
  - `other_ops_stub`：占位（MVP 直通，后续加 BN/ReLU/quant）

### 0.2 MVP 目标
- **Conv 3x3**
- **Stride = 1 或 2**
- **Layer-wise**：一层输入从外部流读入，计算完成后按相同 layout 写出
- 支持 bitwidth：
  - Activation `act_bits` ∈ {2,4,8,16}
  - Weight `wgt_bits` ∈ {2,4,8,16}
- **重要限制（MVP 版，匹配原文实现习惯）**
  - MVP **要求**：`act_bits>2` 与 `wgt_bits>2` 不同时出现  
    即：要么高 bit activation + 2-bit weight；要么 2-bit activation + 高 bit weight。
  - 原因：原文“分组+移位合并”描述的是单边高 bit 的高效实现；两边同时高 bit 会出现 cross-term（见 §3.4），MVP 不做。
  - 你后续要扩展：在控制层再加一层 slice 的双重循环（性能降），即可支持两边同时高 bit。

---

## 1. 术语与符号

- Kernel：固定 `KH=3`，`KW=3`
- 输入 feature map：尺寸 `[H][W][IC]`（注意：**通道是 innermost**）
- 输出 feature map：尺寸 `[OH][OW][OC]`
- Stride：`S ∈ {1,2}`
- Batch（硬件并行度，固定“2-bit slice lane”数量）：
  - `IC2_LANES = 16`：每周期并行处理的 **2-bit activation slice** 数
  - `OC2_LANES = 16`：每周期并行处理的 **2-bit weight slice** 数（也可理解为 output lane）
- bit-slice：
  - `act_slices = act_bits / 2`（2-bit 为 1 slice，4-bit 为 2 slices，以此类推）
  - `wgt_slices = wgt_bits / 2`
- 每周期处理的“物理通道数”：
  - 若 `act_slices>1`（且 `wgt_slices==1`）：  
    `IC_CH_PER_CYCLE = IC2_LANES / act_slices`
  - 若 `wgt_slices>1`（且 `act_slices==1`）：  
    `OC_CH_PER_CYCLE = OC2_LANES / wgt_slices`
  - 2-bit/2-bit 情况：`IC_CH_PER_CYCLE=16`，`OC_CH_PER_CYCLE=16`

---

## 2. 数据布局与打包（外部 DRAM/stream 等价）

### 2.1 Activation layout（与原文“channel-width-height 顺序”一致）
**低地址到高地址的线性顺序：**
1. channel（c）变化最快（innermost）
2. width（x）
3. height（y）

等价 index：
- `idx_act = ((y * W) + x) * IC + c`

> 这意味着：同一个像素 `(y,x)` 的所有通道 `c=0..IC-1` 在地址上是连续的，这也是 line buffer 计算一行大小 `IC*W*bits` 的前提。

### 2.2 Weight layout（与原文维度一致）
原文写 Weight 4 维为 `[input-ch, output-ch, kernel-w, kernel-h]`。本 SPEC 固定存储顺序为：
1. input channel（ic）innermost
2. output channel（oc）
3. kernel x（kw）
4. kernel y（kh）outermost

等价 index：
- `idx_wgt = (((kh * KW) + kw) * OC + oc) * IC + ic`

> 注：你也可以换成更常见的 `[oc][ic][kh][kw]`，但要同步改 weight_buffer 的装载和寻址。MVP 用上式即可。

### 2.3 Output layout
输出仍按与 activation 相同的 layout 写出（c innermost）：
- `idx_out = ((oy * OW) + ox) * OC + oc`

### 2.4 bit packing（stream 传输单位）
外部流以 `BUS_W` 位传输（默认 128b），按 **小端地址顺序**拼接：
- `data[7:0]` 对应最低地址 byte
- 在每个 byte 内，低 bit 对应更低 index 的元素

打包规则（对任意 tensor：act/wgt/out）：
- `bits=2`：1 byte 放 4 个元素  
  - byte[1:0]=elem0，[3:2]=elem1，[5:4]=elem2，[7:6]=elem3
- `bits=4`：1 byte 放 2 个元素  
  - byte[3:0]=elem0，[7:4]=elem1
- `bits=8`：1 byte 放 1 个元素
- `bits=16`：2 byte 放 1 个元素（little-endian）

**要求：**stream 输入数据必须严格按 §2.1/§2.2/§2.3 的线性顺序排列并连续输出。

---

## 3. 数值编码与卷积数学定义

### 3.1 2-bit 数值 decode（固定，来自原文）
2-bit code → signed int：
- `2'b00 -> -3`
- `2'b01 -> -1`
- `2'b10 -> +1`
- `2'b11 -> +3`

记作 `decode2(u2)`。

### 3.2 4/8/16-bit 的 slice 解释（MVP 用于“单边高 bit”）
把 `N-bit (N∈{4,8,16})` 拆成 `N/2` 个 2-bit slice：
- `slice_s = bits[2*s+1 : 2*s]`（s=0 是最低 2 bits）
- 数值定义（线性组合）：
  - `valN = Σ_{s=0..(N/2-1)} decode2(slice_s) << (2*s)`

> 这与原文“高位 2-bit 结果左移 2 再加低位结果”的方式一致。

### 3.3 卷积定义（Valid conv，无 padding，MVP）
- 输出尺寸：
  - `OH = floor((H - 3)/S) + 1`
  - `OW = floor((W - 3)/S) + 1`
- 数学卷积（理想全精度版本）：
  - `out_full[oy,ox,oc] = Σ_{ic,kh,kw} act[oy*S+kh, ox*S+kw, ic] * wgt[kh,kw,oc,ic]`

### 3.4 **MVP 的输出标定（对应原文“右移一位”技巧）**
原文利用奇数乘奇数为奇数、偶数个奇数相加为偶数，做了“>>1”节省位宽。

因此 MVP 默认输出为：
- `out_mvp = out_full >> 1`  （**精确整除**，不丢信息，因为内部保证和为偶数）

并且内部用 offset 把大量 signed 累加变成 unsigned reduction（见 §6.3）。

> 若你想输出 `out_full`（不右移），可以在 `SHIFT1_EN=0` 的增强模式下实现，但那会迫使 reduction tree/累加链路走 signed，加法资源/时序更差；本 SPEC MVP 默认 `SHIFT1_EN=1`。

### 3.5 单边高 bit 的合并公式（MVP）
- 若 `act_bits>2` 且 `wgt_bits==2`：
  - `out_full = Σ_s ( conv( act_slice_s , wgt_2b ) << (2*s) )`
- 若 `act_bits==2` 且 `wgt_bits>2`：
  - `out_full = Σ_g ( conv( act_2b , wgt_slice_g ) << (2*g) )`

---

## 4. 顶层接口（ready/valid streaming）

### 4.1 顶层模块名
`conv3x3_accel_top`

### 4.2 参数（综合期常量）
- `BUS_W`（默认 128）
- `IC2_LANES`（默认 16，固定）
- `OC2_LANES`（默认 16，固定）
- `MAX_W, MAX_H, MAX_IC, MAX_OC`（用于片上 RAM 定容，MVP 可固定为你目标网络上限）
- `ACC_W`（输出累加位宽，默认 32）
- `SHIFT1_EN`（默认 1）

### 4.3 配置端口（简单寄存器口）
- `cfg_valid` / `cfg_ready`：一次性下发本层配置
- `start`：启动脉冲（或 level）
- `done`：本层完成

配置字段（`cfg_*`）：
- `W, H, IC, OC`（16-bit）
- `stride`（1bit：0->1，1->2）
- `act_bits`（5-bit：2/4/8/16）
- `wgt_bits`（5-bit：2/4/8/16）
- `mode_raw_out`（1bit：1 输出 `ACC_W` signed；0 走 `other_ops_stub` 的量化口，MVP 可先固定 raw）

**约束检查（必须在硬件中 assert/报错/置 done_error）：**
- `KH=KW=3` 固定，不可配
- `stride ∈ {1,2}`
- `act_bits ∈ {2,4,8,16}`，`wgt_bits ∈ {2,4,8,16}`
- MVP 限制：不能同时 `act_bits>2 && wgt_bits>2`
- `IC % IC_CH_PER_CYCLE == 0`
- `OC % OC_CH_PER_CYCLE == 0`
- `W<=MAX_W, H<=MAX_H, IC<=MAX_IC, OC<=MAX_OC`

### 4.4 输入输出流接口（AXI-stream 风格子集）
#### Weight 输入（先送完一层 weight，再送 activation；MVP 顺序固定）
- `wgt_in_valid`
- `wgt_in_ready`
- `wgt_in_data[BUS_W-1:0]`
- `wgt_in_last`：本层 weight 最后一个 beat 置 1（用于边界）

#### Activation 输入
- `act_in_valid`
- `act_in_ready`
- `act_in_data[BUS_W-1:0]`
- `act_in_last`：本层 activation 最后一个 beat 置 1（用于边界）

#### Output 输出
- `out_valid`
- `out_ready`
- `out_data[BUS_W-1:0]`
- `out_last`：本层 output 最后一个 beat 置 1

**强制时序/握手语义：**
- `*_valid` 由上游驱动，保持到 `*_ready` 为 1 且拍到数据为止
- 本加速器可随时拉低 `*_ready` 进行 backpressure
- `*_last` 与对应最后一个 beat 同拍有效

---

## 5. 控制流程（layer-wise，MVP）

状态机（建议）：
1. `IDLE`：等待 `cfg_valid` + `start`
2. `LOAD_WGT`：接收 `wgt_in_*`，写入 `weight_buffer`（直到 `wgt_in_last` 被成功握手）
3. `LOAD_ACT_AND_CONV`：
   - 接收 `act_in_*`，填充 `feature_line_buffer`
   - 一旦 line buffer 准备好一个输出窗口，就驱动 `conv_core_lowbit` 计算
   - 对每个输出像素 `(oy,ox)`：
     - 对每个 output channel group `c`（大小 `OC_CH_PER_CYCLE`）：
       - 对每个 input channel group `n`（大小 `IC_CH_PER_CYCLE`）：
         - 取 3x3 window（对应 `n` 这组输入通道）
         - 取 weight block（对应 `c,n`）
         - `conv_core` 产出 partial，做 inter-cycle accumulate
       - 完成 n 循环后，得到该 `c` 组 output channels 的最终值，写入输出 packer
4. `DRAIN_OUT`：把 output packer 最后不满 BUS_W 的残留 beat 发完，置 `out_last`
5. `DONE`：拉高 `done`，回到 `IDLE`

> 说明：在 `n/c` 循环期间，同一个空间窗口需要重复读取 line buffer（原文说“内部重复 line buffer 地址”），但 **不会回滚/重读 act_in**。

---

## 6. 模块规格

### 6.1 `feature_line_buffer`（3 行 buffer + 窗口发生器）

#### 6.1.1 输入输出
输入：
- `act_in_*`（见 §4.4）
- 配置：`W,H,IC,stride,act_bits`
- 控制：来自 controller 的 `consume_enable`（可选）

输出到 `conv_core`：
- `win_valid` / `win_ready`
- `win_y, win_x`（当前输出像素坐标，可选用于 debug）
- `win_ic_grp`（当前 input channel group index n）
- `win_act2[KH][KW][IC2_LANES]`：每周期输出给 core 的 2-bit slice 数据（不含 oc 维，core 内部 broadcast）

#### 6.1.2 行缓存存储
- 需要 3 行循环 buffer：row0,row1,row2
- 每行存 `W * IC` 个元素，每个元素存 `act_bits`（原始 bitwidth），便于后续 slice 抽取
- 写入顺序严格按 stream 顺序（§2.1）：
  - 接收 `(y,x,c)` 顺序的元素
  - 填满一行后 y++，循环覆盖最旧行

#### 6.1.3 输出窗口生成（valid conv）
当已缓存到足够数据时，输出窗口对应输入坐标：
- `in_y0 = oy*stride`
- `in_x0 = ox*stride`
窗口覆盖：
- `in_y = in_y0 + kh`，`kh=0..2`
- `in_x = in_x0 + kw`，`kw=0..2`

输出扫描顺序（必须）：
- `oy=0..OH-1` 外层
- `ox=0..OW-1`
- `ic_grp=0..(IC/IC_CH_PER_CYCLE-1)`（n 循环）

#### 6.1.4 2-bit slice lane 排布（匹配原文“分组”思想）
令 `act_slices = act_bits/2`，`IC_CH_PER_CYCLE = IC2_LANES / act_slices`（要求整除）

对某个 output window、某个 `ic_grp`：
- 物理通道号：`c_phys = ic_grp*IC_CH_PER_CYCLE + i`，`i=0..IC_CH_PER_CYCLE-1`
- 对 slice `s=0..act_slices-1`：
  - 取该通道元素的 2-bit：`u2 = act_bits_value[c_phys][2*s+1:2*s]`
  - 放到 lane：`lane = s*IC_CH_PER_CYCLE + i`

因此 `win_act2[kh][kw][lane]` 的 lane 含义是：
- **slice-major**：先 slice0 的一组通道，再 slice1 的一组通道，再 slice2...

> 对 `act_bits=4`：`IC_CH_PER_CYCLE=8`  
> lane0..7 为 low2b（ic0..ic7），lane8..15 为 high2b（ic0..ic7），与原文示意一致。

#### 6.1.5 backpressure
- 当 `win_valid=1` 且 `win_ready=0` 时：
  - `feature_line_buffer` 必须保持当前 window 输出稳定，不推进 `ox/oy/ic_grp`
  - 同时可以拉低 `act_in_ready` 暂停继续接收输入（允许上游停）

---

### 6.2 `weight_buffer`（整层 weight 片上缓存）

#### 6.2.1 输入输出
输入：
- `wgt_in_*`（见 §4.4）
- 配置：`IC,OC,wgt_bits`

输出到 `conv_core`（按 controller 给的 group index）：
- `wgt_valid` / `wgt_ready`（可简化为跟随 `win_valid/win_ready`）
- `wgt_oc_grp`（c index）
- `wgt_ic_grp`（n index）
- `wgt2[OC2_LANES][KH][KW][IC2_LANES]`：2-bit weight slice

#### 6.2.2 存储组织
- 存储原始 `wgt_bits`，便于 slice 抽取
- 总元素数：`OC * IC * 9`
- 建议地址映射（与 §2.2 一致）：
  - `addr = (((kh*3)+kw)*OC + oc)*IC + ic`

#### 6.2.3 2-bit slice lane 排布（匹配原文“oc-batch 分组”）
令 `wgt_slices = wgt_bits/2`，`OC_CH_PER_CYCLE = OC2_LANES / wgt_slices`（要求整除）

对某个 group `(oc_grp, ic_grp)`：
- 物理输出通道：`oc_phys = oc_grp*OC_CH_PER_CYCLE + p`，`p=0..OC_CH_PER_CYCLE-1`
- 物理输入通道：`ic_phys = ic_grp*IC_CH_PER_CYCLE + i`（注意：MVP 要求 act_bits==2 或 wgt_bits==2，见 §0.2）
- 对 weight slice `g=0..wgt_slices-1`：
  - 取 2-bit：`u2 = wgt_bits_value[2*g+1:2*g]`
  - 放到 oc2_lane：`oc_lane = g*OC_CH_PER_CYCLE + p`
- 对 ic2_lane：
  - 若 `act_bits==2`：`IC_CH_PER_CYCLE = 16`，直接 `ic_lane=i`
  - 若 `act_bits>2`（MVP 不允许与 wgt_bits>2 同时）：此分支不会出现

最终输出：
- `wgt2[oc_lane][kh][kw][ic_lane]`

---

### 6.3 `conv_core_lowbit`（低比特卷积核）

#### 6.3.1 输入输出
输入（与 linebuf/weightbuf 对接）：
- `in_valid` / `in_ready`
- `act2[KH][KW][IC2_LANES]`（2-bit）
- `wgt2[OC2_LANES][KH][KW][IC2_LANES]`（2-bit）
- 配置影子：`act_bits,wgt_bits,IC,OC`（也可由 controller 提供 slices 信息）

输出（对 controller）：
- `out_valid` / `out_ready`
- `partial_oc_lane[OC2_LANES]`：signed `ACC_W`（每个 oc2_lane 一个 partial）
- 或者输出已合并的 `phys_oc[OC_CH_PER_CYCLE]`（二选一，推荐直接输出 phys_oc，减少 controller 复杂度）

#### 6.3.2 核心计算（2-bit slice dot-product）
对每个 `oc2_lane = 0..OC2_LANES-1`，计算：
- `sum_products = Σ_{kh,kw,ic2_lane} decode2(act2[kh][kw][ic2_lane]) * decode2(wgt2[oc2_lane][kh][kw][ic2_lane])`

MVP 默认输出 **右移一位**版本（SHIFT1_EN=1）：
- `sum_shift = sum_products >>> 1`（这里应为精确整除）

#### 6.3.3 LUT instead of DSP：`muladd2_lut`（强制）
为了匹配原文“加号都不用的真查找表 + unsigned reduction”：
- 把 `ic2_lane` 两两配对：`(0,1),(2,3)...(14,15)`
- 对每个 pair，定义：
  - `p0 = decode2(a0)*decode2(w0)`
  - `p1 = decode2(a1)*decode2(w1)`
  - `pair_sum = p0 + p1`（一定为偶数）
- 选定 offset：
  - `pair_sum` 范围 [-18, +18]
  - 取 `OFFSET_PAIR = 18`，则 `(pair_sum + 18)` ∈ [0,36] 且为偶数
  - 右移 1：`u = (pair_sum + 18) >> 1`，范围 [0..18]，**无符号**
- 因此 `muladd2_lut` 实现一个 8-bit address ROM：
  - 输入：`a0(2b), w0(2b), a1(2b), w1(2b)` 共 8bits
  - 输出：`u`（至少 5 bits）

> 要求：`muladd2_lut` 必须用组合逻辑（case/ROM）实现，不实例化 DSP。

#### 6.3.4 unsigned reduction tree
对每个 oc2_lane、对每个 slice-group（见下一节）：
- 对每个 `(kh,kw)` 有 `IC_LANES_PER_SLICE/2` 个 `muladd2_lut` 输出
- 总 LUT 输出个数：
  - `N_PAIRS = KH*KW*(IC_LANES_PER_SLICE/2)`
- reduction 得到：
  - `sum_u = Σ u_i`（无符号）

offset 去除（把结果还原到 signed、且仍然是“>>1”的标定）：
- 因为 `u_i = (pair_sum_i + 18)>>1 = pair_sum_i/2 + 9`
- 所以 `sum_u = (Σ pair_sum_i)/2 + N_PAIRS*9 = sum_products/2 + N_PAIRS*9`
- 得：
  - `sum_s = signed(sum_u) - (N_PAIRS*9)`  
  - `sum_s` 即 `sum_products >> 1`（精确）

> `N_PAIRS` 在 act_bits 改变时会变（因为每个 slice 的 ic lane 数变了），见 §6.3.5。

#### 6.3.5 支持 `act_bits>2`（wgt_bits 必须 ==2，MVP）
- `act_slices = act_bits/2`
- `IC_LANES_PER_SLICE = IC2_LANES / act_slices`

对每个 `slice s`：
- 只使用该 slice 对应的 ic lane 区间：
  - `ic_lane ∈ [s*IC_LANES_PER_SLICE , (s+1)*IC_LANES_PER_SLICE - 1]`
- 在该子集内做配对、muladd2_lut、unsigned reduction：
  - `N_PAIRS_s = KH*KW*(IC_LANES_PER_SLICE/2)`
  - `sum_s[s] = signed(sum_u[s]) - (N_PAIRS_s*9)`
- slice 合并（恢复 full precision 的线性组合，但仍保留整体 >>1 的标定）：
  - `sum_combined = Σ_{s} ( sum_s[s] <<< (2*s) )`

> 注意：这里合并逻辑仅做移位+加法；原文强调“分组主要是 assign，MUX 只在组结果后做移位”，本实现遵循该原则。

#### 6.3.6 支持 `wgt_bits>2`（act_bits 必须 ==2，MVP）
- `wgt_slices = wgt_bits/2`
- `OC_LANES_PER_SLICE = OC2_LANES / wgt_slices`
- 对每个物理输出通道 `p=0..OC_LANES_PER_SLICE-1`，对应 oc2_lane：
  - `lane(g,p) = g*OC_LANES_PER_SLICE + p`

对每个 slice g：
- 用 oc2_lane = lane(g,p) 计算 `sum_lane(g,p)`（同 §6.3.2~6.3.4）

合并物理输出通道：
- `sum_phys[p] = Σ_{g} ( sum_lane(g,p) <<< (2*g) )`

#### 6.3.7 inter-cycle accumulation（对应原文 inter-cycle）
controller 会对同一 `(oy,ox,oc_grp)` 迭代多个 `ic_grp`：
- 每次 `conv_core` 输出的是本 `ic_grp` 的 partial
- controller 累加：
  - `acc[p] += partial[p]`
- 完成所有 `ic_grp` 后，`acc[p]` 成为最终输出（仍然是整体 >>1 标定）

---

### 6.4 `output_packer`（把 `ACC_W` signed 打包成 BUS_W beat）
- 输入：按 output layout（§2.3）顺序，逐元素喂入
- 输出：`out_*` stream
- MVP：先输出 raw `ACC_W`（例如 32-bit little-endian），每个元素占 `ACC_W/8` bytes  
  - 若 `ACC_W` 不是 8 的倍数，必须在 spec 中禁止（建议 ACC_W=32）

---

### 6.5 `other_ops_stub`（占位）
MVP 可实现为：
- `pass-through`：直接把 `acc` 输出给 packer  
后续扩展（不在 MVP）：
- bias add、BN fold、ReLU、低比特量化回写（2-bit/4-bit）等

---

## 7. 时序与吞吐（必须可推断）

### 7.1 时钟与复位
- 单时钟 `clk`
- 复位 `rst_n`（低有效）
- 所有状态机、RAM 写指针、输出寄存器在复位后回到初始态

### 7.2 一致性要求（仿真/综合）
- 所有 RAM 用可综合推断的方式描述（`logic [..] mem [0:DEPTH-1]` 或者 `always_ff` 的同步读写）
- `muladd2_lut` 必须纯组合
- 所有 ready/valid 必须无组合环（建议：ready 只由下游寄存/状态决定）

---

## 8. 校验/验证（强制交付自测 TB）

### 8.1 参考模型（TB 内）
TB 必须实现一个 bit-accurate golden：
- 按 §3.1 decode2 / §3.2 slice 组合得到 `act_full` 与 `wgt_full`
- 计算 `out_full`
- 若 `SHIFT1_EN=1`：比较 `out_full>>1`
- 输出 layout 与打包按 §2.3/§2.4

### 8.2 覆盖用例（至少）
1. act_bits=2, wgt_bits=2，stride=1，IC=16，OC=16，W/H 小尺寸（如 8x8）
2. act_bits=2, wgt_bits=2，stride=2
3. act_bits=4, wgt_bits=2（MVP 单边高 bit），IC=8*k，OC=16
4. act_bits=2, wgt_bits=4，IC=16，OC=8*k
5. 多 ic_grp、多 oc_grp（例如 IC=64、OC=64），随机数据
6. backpressure：在 out_ready 周期性拉低，确保内部不会丢数据/乱序

### 8.3 断言（建议）
- 输入流元素计数必须恰好等于：
  - act 元素数：`H*W*IC`
  - wgt 元素数：`OC*IC*9`
  - out 元素数：`OH*OW*OC`
- `*_last` 出现在预期最后 beat
- 若配置非法，必须进入 error done（可用 `done` + `error_code`）

---

## 9. 交付物（建议文件组织）

```

rtl/
conv3x3_accel_top.sv
feature_line_buffer.sv
weight_buffer.sv
conv_core_lowbit.sv
muladd2_lut.sv
output_packer.sv
other_ops_stub.sv

tb/
tb_conv3x3_accel.sv
tb_golden_model.sv (或直接写在 tb 中)

```

---

## 10. 关键实现备注（避免 codex 走偏）

1. **layout 一定要 c innermost**（§2.1），否则 line buffer 行大小公式和原文不一致。
2. **muladd2_lut 的 offset=18、输出右移 1、再在 reduction 后减去 `N_PAIRS*9`** 是核心技巧（§6.3.3~6.3.4）。
3. 支持高 bit 的“分组”必须是 **lane 重新布线 + 组结果移位合并**（§6.3.5/6.3.6），不要在 reduction tree 中间插入大规模 MUX。
4. MVP 禁止 `act_bits>2 && wgt_bits>2`，否则 cross-term 需要额外 slice 双循环（本 SPEC 不做）。
5. controller 的循环顺序固定：`oy -> ox -> oc_grp(c) -> ic_grp(n)`，并且同一像素窗口在 `c/n` 内重复读取 line buffer（不推进窗口），完成后再推进到下一个 `(ox,oy)`。

## Agents Added Memories
- 用 python 不用 python3
- The user's operating system is: darwin
- may use Apple Silicon MPS for acceleration
- [a meta request bout the working process] use `echo $'\a'` to notify the user when waiting for input
