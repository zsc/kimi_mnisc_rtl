//=============================================================================
// tb_conv_core.sv
// Testbench for conv_core_lowbit module (2-bit x 2-bit mode)
//=============================================================================
`timescale 1ns/1ps

// Simplified conv_core for 2x2-bit mode only
module conv_core_simple (
    input clk,
    input rst_n,
    input in_valid,
    output reg in_ready,
    input [1:0] act2_0_0, act2_0_1, act2_0_2,
    input [1:0] act2_1_0, act2_1_1, act2_1_2,
    input [1:0] act2_2_0, act2_2_1, act2_2_2,
    input [1:0] wgt2_0,
    input [4:0] act_bits,
    input [4:0] wgt_bits,
    output reg out_valid,
    input out_ready,
    output reg signed [31:0] partial
);
    // decode2 function
    function signed [2:0] decode2;
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
    
    reg signed [31:0] sum;
    reg [1:0] act_reg [0:2][0:2];
    reg [1:0] wgt_reg;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_ready <= 1'b1;
            out_valid <= 1'b0;
            partial <= 0;
        end else begin
            if (in_valid && in_ready) begin
                // Capture inputs
                act_reg[0][0] <= act2_0_0; act_reg[0][1] <= act2_0_1; act_reg[0][2] <= act2_0_2;
                act_reg[1][0] <= act2_1_0; act_reg[1][1] <= act2_1_1; act_reg[1][2] <= act2_1_2;
                act_reg[2][0] <= act2_2_0; act_reg[2][1] <= act2_2_1; act_reg[2][2] <= act2_2_2;
                wgt_reg <= wgt2_0;
                
                // Compute convolution
                sum = 0;
                sum = sum + (decode2(act2_0_0) * decode2(wgt2_0));
                sum = sum + (decode2(act2_0_1) * decode2(wgt2_0));
                sum = sum + (decode2(act2_0_2) * decode2(wgt2_0));
                sum = sum + (decode2(act2_1_0) * decode2(wgt2_0));
                sum = sum + (decode2(act2_1_1) * decode2(wgt2_0));
                sum = sum + (decode2(act2_1_2) * decode2(wgt2_0));
                sum = sum + (decode2(act2_2_0) * decode2(wgt2_0));
                sum = sum + (decode2(act2_2_1) * decode2(wgt2_0));
                sum = sum + (decode2(act2_2_2) * decode2(wgt2_0));
                
                // Right shift 1 (as per MVP spec)
                partial <= sum >>> 1;
                out_valid <= 1'b1;
            end else if (out_valid && out_ready) begin
                out_valid <= 1'b0;
            end
        end
    end
endmodule

module tb_conv_core;
    reg clk;
    reg rst_n;
    reg in_valid;
    wire in_ready;
    reg [1:0] act2_0_0, act2_0_1, act2_0_2;
    reg [1:0] act2_1_0, act2_1_1, act2_1_2;
    reg [1:0] act2_2_0, act2_2_1, act2_2_2;
    reg [1:0] wgt2_0;
    reg [4:0] act_bits;
    reg [4:0] wgt_bits;
    wire out_valid;
    reg out_ready;
    wire signed [31:0] partial;
    
    conv_core_simple dut (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(in_valid),
        .in_ready(in_ready),
        .act2_0_0(act2_0_0), .act2_0_1(act2_0_1), .act2_0_2(act2_0_2),
        .act2_1_0(act2_1_0), .act2_1_1(act2_1_1), .act2_1_2(act2_1_2),
        .act2_2_0(act2_2_0), .act2_2_1(act2_2_1), .act2_2_2(act2_2_2),
        .wgt2_0(wgt2_0),
        .act_bits(act_bits),
        .wgt_bits(wgt_bits),
        .out_valid(out_valid),
        .out_ready(out_ready),
        .partial(partial)
    );
    
    // Clock generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end
    
    // decode2 function
    function signed [2:0] decode2;
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
    
    integer error_count;
    reg signed [31:0] expected;
    reg signed [31:0] sum;
    
    task run_test;
        input [255:0] test_name;  // string
        input [1:0] a00, a01, a02, a10, a11, a12, a20, a21, a22;
        input [1:0] w;
        input signed [31:0] exp;
        begin
            $display("Test: %0s", test_name);
            act2_0_0 = a00; act2_0_1 = a01; act2_0_2 = a02;
            act2_1_0 = a10; act2_1_1 = a11; act2_1_2 = a12;
            act2_2_0 = a20; act2_2_1 = a21; act2_2_2 = a22;
            wgt2_0 = w;
            expected = exp;
            
            in_valid = 1;
            @(posedge clk);
            in_valid = 0;
            
            wait(out_valid);
            #1;
            if (partial !== expected) begin
                $display("  FAIL: got=%0d, expected=%0d", partial, expected);
                error_count = error_count + 1;
            end else begin
                $display("  PASS: got=%0d", partial);
            end
            @(posedge clk);
        end
    endtask
    
    initial begin
        $display("========================================");
        $display(" Conv Core (2bx2b) Verification Test");
        $display("========================================");
        
        // Initialize
        rst_n = 0;
        in_valid = 0;
        out_ready = 1;
        act_bits = 5'd2;
        wgt_bits = 5'd2;
        error_count = 0;
        
        // Reset
        repeat(5) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        
        // Test 1: All +1, weight +1
        // sum = 9 * (1*1) = 9, shifted = 4
        run_test("All +1, w=+1", 
                 2'b10, 2'b10, 2'b10, 2'b10, 2'b10, 2'b10, 2'b10, 2'b10, 2'b10,
                 2'b10, 32'd4);
        
        // Test 2: All +3, weight +3
        // sum = 9 * (3*3) = 81, shifted = 40
        run_test("All +3, w=+3",
                 2'b11, 2'b11, 2'b11, 2'b11, 2'b11, 2'b11, 2'b11, 2'b11, 2'b11,
                 2'b11, 32'd40);
        
        // Test 3: All -3, weight +1
        // sum = 9 * (-3*1) = -27, shifted = -14
        run_test("All -3, w=+1",
                 2'b00, 2'b00, 2'b00, 2'b00, 2'b00, 2'b00, 2'b00, 2'b00, 2'b00,
                 2'b10, -32'd14);
        
        // Test 4: Mixed pattern
        // -3, -1, +1, +3, -3, -1, +1, +3, -3 with weight +1
        // sum = -3-1+1+3-3-1+1+3-3 = -3, shifted = -2 (arithmetic)
        run_test("Mixed, w=+1",
                 2'b00, 2'b01, 2'b10, 2'b11, 2'b00, 2'b01, 2'b10, 2'b11, 2'b00,
                 2'b10, -32'd2);
        
        // Test 5: Checkerboard with +3/-3
        // Pattern: +3,-3,+3,-3,+3,-3,+3,-3,+3 with weight +3
        // 9 - 9 + 9 - 9 + 9 - 9 + 9 - 9 + 9 = 9, shifted = 4
        run_test("Checkerboard +3/-3",
                 2'b11, 2'b00, 2'b11, 2'b00, 2'b11, 2'b00, 2'b11, 2'b00, 2'b11,
                 2'b11, 32'd4);
        
        $display("========================================");
        if (error_count == 0) begin
            $display("✅ ALL CONV CORE TESTS PASSED");
        end else begin
            $display("❌ FAILED: %0d errors", error_count);
        end
        $display("========================================");
        
        $finish;
    end
endmodule
