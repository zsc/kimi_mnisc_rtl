//=============================================================================
// conv_core_lowbit.sv
// 低比特卷积核心计算模块
// 支持 2/4/8/16-bit activation 和 weight，使用 LUT 乘法 + 无符号加法树
//=============================================================================

module conv_core_lowbit #(
    parameter int IC2_LANES = 16,
    parameter int OC2_LANES = 16,
    parameter int KH = 3,
    parameter int KW = 3,
    parameter int ACC_W = 32
)(
    input  logic                      clk,
    input  logic                      rst_n,
    
    // 输入接口
    input  logic                      in_valid,
    output logic                      in_ready,
    input  logic [1:0]                act2 [0:KH-1][0:KW-1][0:IC2_LANES-1],
    input  logic [1:0]                wgt2 [0:OC2_LANES-1][0:KH-1][0:KW-1][0:IC2_LANES-1],
    input  logic [4:0]                act_bits,      // 2, 4, 8, 16
    input  logic [4:0]                wgt_bits,      // 2, 4, 8, 16
    
    // 输出接口
    output logic                      out_valid,
    input  logic                      out_ready,
    output logic signed [ACC_W-1:0]   partial [0:OC2_LANES-1]
);

    //=========================================================================
    // 常量和派生参数
    //=========================================================================
    localparam int MAX_ACT_SLICES = 8;   // 16-bit / 2 = 8 slices
    localparam int MAX_WGT_SLICES = 8;
    
    //=========================================================================
    // decode2 函数: 2-bit code -> signed int
    // 2'b00 -> -3, 2'b01 -> -1, 2'b10 -> +1, 2'b11 -> +3
    //=========================================================================
    function automatic signed [2:0] decode2(input logic [1:0] code);
        case (code)
            2'b00: decode2 = -3;
            2'b01: decode2 = -1;
            2'b10: decode2 = 1;
            2'b11: decode2 = 3;
            default: decode2 = 0;
        endcase
    endfunction

    //=========================================================================
    // 计算 slice 数量 (每 2-bit 一个 slice)
    //=========================================================================
    logic [3:0] act_slices, wgt_slices;
    logic [3:0] ic_lanes_per_slice;
    logic [3:0] oc_lanes_per_slice;
    
    always_comb begin
        act_slices = act_bits[4:1];  // act_bits / 2
        wgt_slices = wgt_bits[4:1];  // wgt_bits / 2
        ic_lanes_per_slice = IC2_LANES[4:0] / act_slices;
        oc_lanes_per_slice = OC2_LANES[4:0] / wgt_slices;
    end

    //=========================================================================
    // muladd2_lut 实例化 - 用于计算一对 (a0,w0) 和 (a1,w1) 的乘加
    // 每对产生一个 5-bit 无符号输出 (0-18)
    //=========================================================================
    
    // 计算每 slice 的 pair 数量
    // N_PAIRS = KH * KW * (ic_lanes_per_slice / 2)
    logic [7:0] n_pairs;
    always_comb begin
        n_pairs = (KH * KW * ic_lanes_per_slice) >> 1;
    end
    
    // LUT 输出数组
    // lut_out[oc_lane][kh][kw][pair_idx]
    localparam int MAX_PAIRS_PER_SLICE = (KH * KW * IC2_LANES) >> 1; // 3*3*8 = 72 max
    logic [4:0] lut_out [0:OC2_LANES-1][0:KH-1][0:KW-1][0:IC2_LANES/2-1];
    
    // 生成 muladd2_lut 实例
    generate
        genvar oc, kh, kw, pair;
        for (oc = 0; oc < OC2_LANES; oc++) begin : gen_oc
            for (kh = 0; kh < KH; kh++) begin : gen_kh
                for (kw = 0; kw < KW; kw++) begin : gen_kw
                    for (pair = 0; pair < IC2_LANES/2; pair++) begin : gen_pair
                        // 计算实际的 ic lane 索引 (基于 act_slices)
                        // 注意: 这里需要根据 act_slices 动态选择哪些 lane 有效
                        // 但硬件需要固定连接，所以我们在下面处理
                        
                        logic [7:0] lut_in;
                        logic [4:0] lut_out_wire;
                        
                        // 连接到 act2 和 wgt2
                        // ic lane 0,1 -> pair 0; ic lane 2,3 -> pair 1; ...
                        always_comb begin
                            lut_in[1:0] = act2[kh][kw][pair*2];      // a0
                            lut_in[3:2] = wgt2[oc][kh][kw][pair*2];  // w0
                            lut_in[5:4] = act2[kh][kw][pair*2+1];    // a1
                            lut_in[7:6] = wgt2[oc][kh][kw][pair*2+1];// w1
                        end
                        
                        muladd2_lut u_muladd2_lut (
                            .in_data(lut_in),
                            .out_data(lut_out_wire)
                        );
                        
                        assign lut_out[oc][kh][kw][pair] = lut_out_wire;
                    end
                end
            end
        end
    endgenerate

    //=========================================================================
    // unsigned reduction tree - 对每个 oc_lane、每个 slice 进行累加
    //=========================================================================
    
    // 中间结果: sum_u[oc_lane][act_slice] - 无符号累加结果
    logic [15:0] sum_u [0:OC2_LANES-1][0:MAX_ACT_SLICES-1];
    
    // 有符号结果 (去除 offset 后): sum_s[oc_lane][act_slice]
    logic signed [ACC_W-1:0] sum_s [0:OC2_LANES-1][0:MAX_ACT_SLICES-1];
    
    always_comb begin
        // 初始化 - 所有元素清零
        for (int oc_idx = 0; oc_idx < OC2_LANES; oc_idx++) begin
            for (int s = 0; s < MAX_ACT_SLICES; s++) begin
                sum_u[oc_idx][s] = '0;
                sum_s[oc_idx][s] = '0;
            end
        end
        
        // 对每个 oc_lane
        for (int oc_idx = 0; oc_idx < OC2_LANES; oc_idx++) begin
            // 局部变量声明并初始化
            logic [15:0] temp_sum;
            int pair_start;
            temp_sum = '0;
            pair_start = 0;
            
            // 情况1: act_bits == 2 (单个 slice)
            if (act_slices == 1) begin
                // 累加所有 pairs
                for (int kh_idx = 0; kh_idx < KH; kh_idx++) begin
                    for (int kw_idx = 0; kw_idx < KW; kw_idx++) begin
                        for (int p = 0; p < ic_lanes_per_slice/2; p++) begin
                            temp_sum = temp_sum + lut_out[oc_idx][kh_idx][kw_idx][p];
                        end
                    end
                end
                sum_u[oc_idx][0] = temp_sum;
                // 去除 offset: sum_s = sum_u - (N_PAIRS * 9)
                sum_s[oc_idx][0] = signed'(temp_sum) - signed'(n_pairs * 9);
            end
            // 情况2: act_bits > 2 (多个 slices)
            else begin
                for (int s = 0; s < act_slices; s++) begin
                    temp_sum = '0;
                    pair_start = 0;
                    
                    // 该 slice 对应的 ic lane 范围: [s*ic_lanes_per_slice, (s+1)*ic_lanes_per_slice-1]
                    // 转换为 pair 索引: pair = lane/2
                    pair_start = (s * ic_lanes_per_slice) >> 1;
                    
                    for (int kh_idx = 0; kh_idx < KH; kh_idx++) begin
                        for (int kw_idx = 0; kw_idx < KW; kw_idx++) begin
                            for (int p = 0; p < ic_lanes_per_slice/2; p++) begin
                                temp_sum = temp_sum + lut_out[oc_idx][kh_idx][kw_idx][pair_start + p];
                            end
                        end
                    end
                    sum_u[oc_idx][s] = temp_sum;
                    sum_s[oc_idx][s] = signed'(temp_sum) - signed'(n_pairs * 9);
                end
            end
        end
    end

    //=========================================================================
    // slice 合并逻辑
    //=========================================================================
    
    // 第一步: 合并 act_slices (当 act_bits > 2 时)
    // result_after_act_merge[oc_lane]
    logic signed [ACC_W-1:0] result_after_act_merge [0:OC2_LANES-1];
    
    always_comb begin
        for (int oc_idx = 0; oc_idx < OC2_LANES; oc_idx++) begin
            logic signed [ACC_W-1:0] temp;
            temp = '0;
            
            if (act_slices == 1) begin
                temp = sum_s[oc_idx][0];
            end else begin
                for (int s = 0; s < act_slices; s++) begin
                    // sum_s[s] <<< (2*s)
                    temp = temp + (sum_s[oc_idx][s] <<< (2*s));
                end
            end
            result_after_act_merge[oc_idx] = temp;
        end
    end
    
    // 第二步: 合并 wgt_slices (当 wgt_bits > 2 时)
    // 将 oc_lane 映射到物理通道和 slice
    // oc_lane = g * oc_lanes_per_slice + p
    logic signed [ACC_W-1:0] final_result [0:OC2_LANES-1];
    
    always_comb begin
        // 声明并初始化局部变量
        logic signed [ACC_W-1:0] temp;
        int oc_lane;
        temp = '0;
        oc_lane = 0;
        
        for (int i = 0; i < OC2_LANES; i++) begin
            final_result[i] = '0;
        end
        
        if (wgt_slices == 1) begin
            // wgt_bits == 2, 直接输出
            for (int oc_idx = 0; oc_idx < OC2_LANES; oc_idx++) begin
                final_result[oc_idx] = result_after_act_merge[oc_idx];
            end
        end else begin
            // wgt_bits > 2, 需要合并 slices
            // 对每个物理输出通道 p
            for (int p = 0; p < oc_lanes_per_slice; p++) begin
                temp = '0;
                
                for (int g = 0; g < wgt_slices; g++) begin
                    oc_lane = g * oc_lanes_per_slice + p;
                    temp = temp + (result_after_act_merge[oc_lane] <<< (2*g));
                end
                
                // 输出到第一个 slice 对应的 oc_lane
                final_result[p] = temp;
            end
        end
    end

    //=========================================================================
    // 输出寄存器 (打一拍提高时序)
    //=========================================================================
    logic signed [ACC_W-1:0] partial_reg [0:OC2_LANES-1];
    logic                    out_valid_reg;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid_reg <= 1'b0;
            for (int i = 0; i < OC2_LANES; i++) begin
                partial_reg[i] <= '0;
            end
        end else begin
            if (out_ready || !out_valid_reg) begin
                out_valid_reg <= in_valid;
                for (int i = 0; i < OC2_LANES; i++) begin
                    partial_reg[i] <= final_result[i];
                end
            end
        end
    end
    
    assign out_valid = out_valid_reg;
    assign in_ready = out_ready || !out_valid_reg;
    
    generate
        genvar out_idx;
        for (out_idx = 0; out_idx < OC2_LANES; out_idx++) begin : gen_out
            assign partial[out_idx] = partial_reg[out_idx];
        end
    endgenerate

endmodule

// Note: muladd2_lut is defined in separate file muladd2_lut.sv
