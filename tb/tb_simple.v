//=============================================================================
// Simple testbench for basic verification
//=============================================================================
`timescale 1ns/1ps

// Simplified muladd2_lut using standard Verilog
module muladd2_lut_v (
    input [7:0] in_data,
    output [4:0] out_data
);
    wire [1:0] a0 = in_data[1:0];
    wire [1:0] w0 = in_data[3:2];
    wire [1:0] a1 = in_data[5:4];
    wire [1:0] w1 = in_data[7:6];

    reg signed [2:0] da0, dw0, da1, dw1;
    
    always @(*) begin
        case (a0)
            2'b00: da0 = -3;
            2'b01: da0 = -1;
            2'b10: da0 = 1;
            2'b11: da0 = 3;
        endcase
        case (w0)
            2'b00: dw0 = -3;
            2'b01: dw0 = -1;
            2'b10: dw0 = 1;
            2'b11: dw0 = 3;
        endcase
        case (a1)
            2'b00: da1 = -3;
            2'b01: da1 = -1;
            2'b10: da1 = 1;
            2'b11: da1 = 3;
        endcase
        case (w1)
            2'b00: dw1 = -3;
            2'b01: dw1 = -1;
            2'b10: dw1 = 1;
            2'b11: dw1 = 3;
        endcase
    end
    
    wire signed [5:0] prod_sum = (da0 * dw0) + (da1 * dw1);
    wire [5:0] offset_sum = prod_sum + 6'd18;
    assign out_data = offset_sum[5:1];
endmodule

module tb_simple;
    reg [7:0] in_data;
    wire [4:0] out_data;
    
    muladd2_lut_v dut (.in_data(in_data), .out_data(out_data));
    
    integer i;
    integer error_count;
    reg [1:0] a0, w0, a1, w1;
    integer da0, dw0, da1, dw1;
    integer prod_sum;
    integer expected;
    
    // decode2 function
    function [31:0] decode2;
        input [1:0] code;
        begin
            case (code)
                2'b00: decode2 = -3;
                2'b01: decode2 = -1;
                2'b10: decode2 = 1;
                2'b11: decode2 = 3;
            endcase
        end
    endfunction
    
    initial begin
        $display("========================================");
        $display(" muladd2_lut Verification Test");
        $display("========================================");
        
        error_count = 0;
        
        // Test all 256 combinations
        for (i = 0; i < 256; i = i + 1) begin
            in_data = i[7:0];
            #1;
            
            a0 = in_data[1:0];
            w0 = in_data[3:2];
            a1 = in_data[5:4];
            w1 = in_data[7:6];
            
            da0 = decode2(a0);
            dw0 = decode2(w0);
            da1 = decode2(a1);
            dw1 = decode2(w1);
            
            prod_sum = (da0 * dw0) + (da1 * dw1);
            expected = (prod_sum + 18) >>> 1;
            
            if (out_data !== expected[4:0]) begin
                $display("FAIL: i=%3d | a0=%0d,w0=%0d,a1=%0d,w1=%0d | prod=%3d | got=%2d, exp=%2d",
                    i, da0, dw0, da1, dw1, prod_sum, out_data, expected[4:0]);
                error_count = error_count + 1;
            end
        end
        
        $display("----------------------------------------");
        
        // Display some sample cases
        $display("Sample cases:");
        
        // Case: all -3
        in_data = 8'b00_00_00_00; #1;
        $display("(-3)*(-3) + (-3)*(-3) = 9+9=18 -> out=%0d (exp=18)", out_data);
        
        // Case: all 3
        in_data = 8'b11_11_11_11; #1;
        $display("(3)*(3) + (3)*(3) = 9+9=18 -> out=%0d (exp=18)", out_data);
        
        // Case: all 1
        in_data = 8'b10_10_10_10; #1;
        $display("(1)*(1) + (1)*(1) = 1+1=2 -> out=%0d (exp=10)", out_data);
        
        // Case: mixed
        in_data = 8'b10_10_11_00; #1;
        $display("(1)*(1) + (3)*(-3) = 1-9=-8 -> out=%0d (exp=5)", out_data);
        
        $display("========================================");
        if (error_count == 0) begin
            $display("✅ ALL TESTS PASSED (256/256)");
        end else begin
            $display("❌ FAILED: %0d errors", error_count);
        end
        $display("========================================");
        
        $finish;
    end
endmodule
