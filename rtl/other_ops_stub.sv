// other_ops_stub.sv
// MVP 占位模块：pass-through 直通
// 后续扩展：bias add、BN fold、ReLU、低比特量化等

module other_ops_stub #(
    parameter int ACC_W   = 32,
    parameter int OUT_BITS = 32
)(
    // 时钟复位
    input  logic        clk,
    input  logic        rst_n,

    // 输入
    input  logic                        in_valid,
    output logic                        in_ready,
    input  logic signed [ACC_W-1:0]     in_data,
    input  logic                        in_last,

    // 输出
    output logic                        out_valid,
    input  logic                        out_ready,
    output logic signed [OUT_BITS-1:0]  out_data,
    output logic                        out_last
);

    // MVP: 简单打一拍，保持 valid/ready 握手语义
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            out_data  <= '0;
            out_last  <= 1'b0;
        end else if (out_ready || !out_valid) begin
            // 下游可接收，或当前无有效数据
            out_valid <= in_valid;
            out_data  <= in_data;
            out_last  <= in_last;
        end
    end

    // 上游 ready：下游可接收且当前无有效数据，或下游直接 ready
    assign in_ready = out_ready || !out_valid;

endmodule
