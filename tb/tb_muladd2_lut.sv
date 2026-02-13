//=============================================================================
// tb_muladd2_lut.sv
// Simple testbench for muladd2_lut module
//=============================================================================
`timescale 1ns/1ps

module tb_muladd2_lut;

    reg [7:0] in_data;
    wire [4:0] out_data;

    // Instantiate DUT
    muladd2_lut dut (
        .in_data(in_data),
        .out_data(out_data)
    );

    // decode2 function for reference
    function [31:0] decode2;
        input [1:0] code;
        begin
            case (code)
                2'b00: decode2 = -3;
                2'b01: decode2 = -1;
                2'b10: decode2 = 1;
                2'b11: decode2 = 3;
                default: decode2 = 0;
            endcase
        end
    endfunction

    integer i;
    integer error_count;
    reg [1:0] a0, w0, a1, w1;
    integer da0, dw0, da1, dw1;
    integer prod_sum;
    integer expected;

    // Test stimulus
    initial begin
        $display("============================================");
        $display(" muladd2_lut Module Test");
        $display("============================================");
        
        error_count = 0;
        
        // Test specific cases
        // Case 1: a0=0(-3), w0=0(-3), a1=0(-3), w1=0(-3)
        // prod_sum = 9 + 9 = 18, expected = (18+18)>>1 = 18
        in_data = 8'b00_00_00_00;
        #1;
        if (out_data !== 5'd18) begin
            $display("ERROR: Case 1, got=%0d, expected=18", out_data);
            error_count = error_count + 1;
        end
        
        // Case 2: a0=3(3), w0=3(3), a1=3(3), w1=3(3)
        // prod_sum = 9 + 9 = 18, expected = 18
        in_data = 8'b11_11_11_11;
        #1;
        if (out_data !== 5'd18) begin
            $display("ERROR: Case 2, got=%0d, expected=18", out_data);
            error_count = error_count + 1;
        end
        
        // Case 3: a0=0(-3), w0=3(3), a1=2(1), w1=2(1)
        // prod_sum = -9 + 1 = -8, expected = (-8+18)>>1 = 5
        in_data = 8'b10_10_11_00;
        #1;
        if (out_data !== 5'd5) begin
            $display("ERROR: Case 3, got=%0d, expected=5", out_data);
            error_count = error_count + 1;
        end
        
        // Case 4: a0=2(1), w0=2(1), a1=2(1), w1=2(1)
        // prod_sum = 1 + 1 = 2, expected = (2+18)>>1 = 10
        in_data = 8'b10_10_10_10;
        #1;
        if (out_data !== 5'd10) begin
            $display("ERROR: Case 4, got=%0d, expected=10", out_data);
            error_count = error_count + 1;
        end
        
        // Case 5: a0=1(-1), w0=1(-1), a1=1(-1), w1=1(-1)
        // prod_sum = 1 + 1 = 2, expected = 10
        in_data = 8'b01_01_01_01;
        #1;
        if (out_data !== 5'd10) begin
            $display("ERROR: Case 5, got=%0d, expected=10", out_data);
            error_count = error_count + 1;
        end
        
        // Case 6: a0=0(-3), w0=0(-3), a1=3(3), w1=0(-3)
        // prod_sum = 9 + (-9) = 0, expected = (0+18)>>1 = 9
        in_data = 8'b11_00_00_00;
        #1;
        if (out_data !== 5'd9) begin
            $display("ERROR: Case 6, got=%0d, expected=9", out_data);
            error_count = error_count + 1;
        end
        
        // Random test cases using loop
        $display("Testing all 256 combinations...");
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
                $display("ERROR: i=%0d, in=%b, got=%0d, expected=%0d", i, in_data, out_data, expected[4:0]);
                error_count = error_count + 1;
            end
        end
        
        $display("============================================");
        if (error_count == 0) begin
            $display("✅ All tests PASSED!");
        end else begin
            $display("❌ %0d tests FAILED", error_count);
        end
        $display("============================================");
        
        $finish;
    end

endmodule
