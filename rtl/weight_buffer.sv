//============================================================================
// weight_buffer.sv
// 整层权重片上缓存模块
// 功能：
//   1. 从外部流加载整层权重 (OC x IC x 3 x 3)
//   2. 根据请求输出指定 (oc_grp, ic_grp) 的 weight block
//   3. 支持 2/4/8/16 bit 权重，输出统一为 2-bit slice 格式
//============================================================================

module weight_buffer #(
    parameter int MAX_IC      = 256,
    parameter int MAX_OC      = 256,
    parameter int BUS_W       = 128,
    parameter int IC2_LANES   = 16,
    parameter int OC2_LANES   = 16,
    parameter int KH          = 3,
    parameter int KW          = 3
)(
    // 时钟复位
    input  logic        clk,
    input  logic        rst_n,

    // 配置接口
    input  logic [15:0] cfg_IC,
    input  logic [15:0] cfg_OC,
    input  logic [4:0]  cfg_wgt_bits,   // 2,4,8,16
    input  logic        cfg_valid,
    output logic        cfg_ready,

    // Weight 输入流
    input  logic        wgt_in_valid,
    output logic        wgt_in_ready,
    input  logic [BUS_W-1:0] wgt_in_data,
    input  logic        wgt_in_last,
    output logic        wgt_load_done,

    // 输出到 conv_core 的请求接口
    input  logic [7:0]  req_oc_grp,
    input  logic [7:0]  req_ic_grp,
    input  logic        req_valid,
    output logic        req_ready,

    // 输出数据 (2-bit slice 格式)
    output logic [1:0]  wgt2 [0:OC2_LANES-1][0:KH-1][0:KW-1][0:IC2_LANES-1],
    output logic        wgt_valid,
    input  logic        wgt_ready
);

    //========================================================================
    // 本地参数和类型定义
    //========================================================================
    
    // 计算最大存储深度: MAX_OC * MAX_IC * 9
    localparam int MAX_ELEMENTS = MAX_OC * MAX_IC * KH * KW;
    localparam int ADDR_W       = $clog2(MAX_ELEMENTS);
    
    // 最大位宽
    localparam int MAX_WGT_BITS = 16;
    
    //========================================================================
    // 配置寄存器
    //========================================================================
    logic [15:0] reg_IC, reg_OC;
    logic [4:0]  reg_wgt_bits;
    logic [2:0]  reg_wgt_slices;      // wgt_bits / 2
    logic [7:0]  reg_OC_CH_PER_CYCLE; // OC2_LANES / wgt_slices
    logic [7:0]  reg_IC_CH_PER_CYCLE; // IC2_LANES (when act_bits==2)
    
    // 派生配置
    logic [31:0] total_elements;      // OC * IC * 9
    
    //========================================================================
    // RAM 存储 (inferred dual-port: 1 write, 1 read)
    //========================================================================
    logic [MAX_WGT_BITS-1:0] wgt_ram [0:MAX_ELEMENTS-1];
    
    //========================================================================
    // 加载状态机和逻辑
    //========================================================================
    typedef enum logic [2:0] {
        LOAD_IDLE,
        LOAD_ACTIVE,
        LOAD_DONE
    } load_state_t;
    
    load_state_t load_state;
    logic [ADDR_W-1:0] load_addr;        // 当前写入地址
    logic [31:0]       load_element_cnt; // 已加载元素计数
    logic [31:0]       beat_cnt;         // 当前 beat 计数
    
    // 计算配置派生值 (组合逻辑)
    always_comb begin
        reg_wgt_slices = reg_wgt_bits[4:1];  // div by 2
        reg_OC_CH_PER_CYCLE = OC2_LANES / reg_wgt_slices;
        reg_IC_CH_PER_CYCLE = IC2_LANES;
        total_elements = reg_OC * reg_IC * KH * KW;
    end
    
    // 配置接口处理
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_IC <= '0;
            reg_OC <= '0;
            reg_wgt_bits <= '0;
            cfg_ready <= 1'b1;
        end else begin
            if (cfg_valid && cfg_ready) begin
                reg_IC <= cfg_IC;
                reg_OC <= cfg_OC;
                reg_wgt_bits <= cfg_wgt_bits;
                cfg_ready <= 1'b0;
            end else if (load_state == LOAD_DONE) begin
                cfg_ready <= 1'b1;
            end
        end
    end
    
    // 位宽解析函数
    function automatic logic [MAX_WGT_BITS-1:0] extract_element(
        input logic [BUS_W-1:0] data,
        input logic [5:0]       idx,
        input logic [4:0]       bits
    );
        case (bits)
            5'd2:  return data[idx*2 +: 2];
            5'd4:  return data[idx*4 +: 4];
            5'd8:  return data[idx*8 +: 8];
            5'd16: return data[idx*16 +: 16];
            default: return '0;
        endcase
    endfunction
    
    // 计算每 beat 元素数
    function automatic logic [5:0] elems_per_beat(input logic [4:0] bits);
        return (BUS_W / bits);
    endfunction
    
    // 加载状态机
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            load_state <= LOAD_IDLE;
            load_addr <= '0;
            load_element_cnt <= '0;
            beat_cnt <= '0;
            wgt_load_done <= 1'b0;
        end else begin
            wgt_load_done <= 1'b0;
            
            case (load_state)
                LOAD_IDLE: begin
                    if (cfg_valid && !cfg_ready) begin
                        load_state <= LOAD_ACTIVE;
                        load_addr <= '0;
                        load_element_cnt <= '0;
                        beat_cnt <= '0;
                    end
                end
                
                LOAD_ACTIVE: begin
                    if (wgt_in_valid && wgt_in_ready) begin
                        beat_cnt <= beat_cnt + 1;
                        
                        // 解析并写入当前 beat 的数据
                        // 使用 generate 风格的循环展开
                        for (int i = 0; i < 64; i++) begin
                            if (i < elems_per_beat(reg_wgt_bits) && 
                                load_element_cnt + i < total_elements) begin
                                wgt_ram[load_addr + i] <= extract_element(
                                    wgt_in_data, i[5:0], reg_wgt_bits
                                );
                            end
                        end
                        
                        load_addr <= load_addr + elems_per_beat(reg_wgt_bits);
                        load_element_cnt <= load_element_cnt + elems_per_beat(reg_wgt_bits);
                        
                        if (wgt_in_last || 
                            load_element_cnt + elems_per_beat(reg_wgt_bits) >= total_elements) begin
                            load_state <= LOAD_DONE;
                        end
                    end
                end
                
                LOAD_DONE: begin
                    wgt_load_done <= 1'b1;
                    load_state <= LOAD_IDLE;
                end
                
                default: load_state <= LOAD_IDLE;
            endcase
        end
    end
    
    assign wgt_in_ready = (load_state == LOAD_ACTIVE);
    
    //========================================================================
    // 权重读取逻辑
    //========================================================================
    
    // 读取状态
    typedef enum logic [1:0] {
        READ_IDLE,
        READ_ACTIVE,
        READ_DONE
    } read_state_t;
    
    read_state_t read_state_reg;
    logic [7:0]  read_oc_grp_reg, read_ic_grp_reg;
    logic [7:0]  read_oc_base, read_ic_base;
    
    // 输出缓冲
    logic [1:0]  wgt2_reg [0:OC2_LANES-1][0:KH-1][0:KW-1][0:IC2_LANES-1];
    logic        wgt_valid_reg;
    
    // 地址计算函数
    // addr = (((kh*3)+kw)*OC + oc)*IC + ic
    function automatic logic [ADDR_W-1:0] calc_wgt_addr(
        input logic [15:0] oc,
        input logic [15:0] ic,
        input logic [1:0]  kh,
        input logic [1:0]  kw
    );
        return ((kh * 3 + kw) * reg_OC + oc) * reg_IC + ic;
    endfunction
    
    // 从存储值中提取指定 slice 的 2-bit
    function automatic logic [1:0] get_slice(
        input logic [MAX_WGT_BITS-1:0] value,
        input logic [2:0]              slice_idx
    );
        return value[slice_idx*2 +: 2];
    endfunction
    
    // 读取状态机
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_state_reg <= READ_IDLE;
            wgt_valid_reg <= 1'b0;
            read_oc_grp_reg <= '0;
            read_ic_grp_reg <= '0;
            read_oc_base <= '0;
            read_ic_base <= '0;
        end else begin
            wgt_valid_reg <= 1'b0;
            
            case (read_state_reg)
                READ_IDLE: begin
                    if (req_valid && req_ready) begin
                        read_state_reg <= READ_ACTIVE;
                        read_oc_grp_reg <= req_oc_grp;
                        read_ic_grp_reg <= req_ic_grp;
                        read_oc_base <= req_oc_grp * reg_OC_CH_PER_CYCLE;
                        read_ic_base <= req_ic_grp * IC2_LANES;
                    end
                end
                
                READ_ACTIVE: begin
                    read_state_reg <= READ_DONE;
                end
                
                READ_DONE: begin
                    wgt_valid_reg <= 1'b1;
                    if (wgt_ready) begin
                        read_state_reg <= READ_IDLE;
                    end
                end
                
                default: read_state_reg <= READ_IDLE;
            endcase
        end
    end
    
    // 组合逻辑：根据状态读取 RAM 并重组为 wgt2 格式
    // 在 READ_ACTIVE 或 READ_DONE 状态下保持输出稳定
    always_comb begin
        // 初始化局部变量
        logic [2:0]  wgt_slices_local;
        logic [7:0]  OC_CH_PER_CYCLE_local;
        logic [15:0] phys_oc, phys_ic;
        logic [ADDR_W-1:0] addr;
        logic [MAX_WGT_BITS-1:0] wgt_val;
        logic [7:0] oc_lane;
        
        // 默认值
        wgt_slices_local = reg_wgt_bits[4:1];
        OC_CH_PER_CYCLE_local = OC2_LANES / wgt_slices_local;
        phys_oc = '0;
        phys_ic = '0;
        addr = '0;
        wgt_val = '0;
        oc_lane = '0;
        
        // 默认清零
        for (int oc = 0; oc < OC2_LANES; oc++) begin
            for (int kh_i = 0; kh_i < KH; kh_i++) begin
                for (int kw_i = 0; kw_i < KW; kw_i++) begin
                    for (int ic = 0; ic < IC2_LANES; ic++) begin
                        wgt2_reg[oc][kh_i][kw_i][ic] = '0;
                    end
                end
            end
        end
        
        // 只在 READ_ACTIVE 或 READ_DONE 状态计算输出
        if (read_state_reg == READ_ACTIVE || read_state_reg == READ_DONE) begin
            
            // 遍历所有 slice group
            for (int g = 0; g < 8; g++) begin
                if (g < wgt_slices_local) begin
                    // 遍历当前 group 内的输出通道
                    for (int p = 0; p < 16; p++) begin
                        if (p < OC_CH_PER_CYCLE_local) begin
                            phys_oc = read_oc_base + p[15:0];
                            oc_lane = g[7:0] * OC_CH_PER_CYCLE_local + p[7:0];
                            
                            // 遍历输入通道 (固定 IC2_LANES=16)
                            for (int i = 0; i < IC2_LANES; i++) begin
                                phys_ic = read_ic_base + i[15:0];
                                
                                // 遍历 kernel 位置
                                for (int kh_i = 0; kh_i < KH; kh_i++) begin
                                    for (int kw_i = 0; kw_i < KW; kw_i++) begin
                                        // 边界检查
                                        if (phys_oc < reg_OC && phys_ic < reg_IC) begin
                                            addr = calc_wgt_addr(phys_oc, phys_ic, 
                                                                kh_i[1:0], kw_i[1:0]);
                                            wgt_val = wgt_ram[addr];
                                            
                                            // 提取对应 slice 的 2-bit
                                            wgt2_reg[oc_lane][kh_i][kw_i][i] = get_slice(wgt_val, g[2:0]);
                                        end else begin
                                            wgt2_reg[oc_lane][kh_i][kw_i][i] = '0;
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    
    // 输出连接
    assign req_ready = (read_state_reg == READ_IDLE);
    assign wgt_valid = wgt_valid_reg;
    
    // 输出 wgt2
    always_comb begin
        for (int oc = 0; oc < OC2_LANES; oc++) begin
            for (int kh_i = 0; kh_i < KH; kh_i++) begin
                for (int kw_i = 0; kw_i < KW; kw_i++) begin
                    for (int ic = 0; ic < IC2_LANES; ic++) begin
                        wgt2[oc][kh_i][kw_i][ic] = wgt2_reg[oc][kh_i][kw_i][ic];
                    end
                end
            end
        end
    end
    
    //========================================================================
    // 调试和验证断言
    //========================================================================
    `ifdef SIMULATION
        always @(posedge clk) begin
            if (cfg_valid && cfg_ready) begin
                if (!(cfg_wgt_bits == 2 || cfg_wgt_bits == 4 || 
                      cfg_wgt_bits == 8 || cfg_wgt_bits == 16)) begin
                    $error("[weight_buffer] Illegal cfg_wgt_bits: %d", cfg_wgt_bits);
                end
            end
        end
        
        always @(posedge clk) begin
            if (wgt_load_done) begin
                $display("[weight_buffer] Load done. Elements loaded: %0d, expected: %0d",
                         load_element_cnt, total_elements);
            end
        end
    `endif

endmodule
