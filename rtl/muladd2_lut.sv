//=============================================================================
// muladd2_lut.sv
// 2-bit LUT multiplier-add unit
// Computes: pair_sum = decode2(a0)*decode2(w0) + decode2(a1)*decode2(w1)
// Output: (pair_sum + 18) >> 1, range [0, 18]
//
// Based on AGENTS.md §6.3.3 - Uses pure combinational logic, no DSP
//=============================================================================

module muladd2_lut (
    input  logic [7:0] in_data,   // {a1[1:0], w1[1:0], a0[1:0], w0[1:0]}
    output logic [4:0] out_data   // 0-18 unsigned
);

    // Extract inputs
    logic [1:0] a0, w0, a1, w1;
    assign a0 = in_data[1:0];
    assign w0 = in_data[3:2];
    assign a1 = in_data[5:4];
    assign w1 = in_data[7:6];

    // decode2 function: 2-bit code to signed int
    // 2'b00 -> -3, 2'b01 -> -1, 2'b10 -> +1, 2'b11 -> +3
    function automatic signed [2:0] decode2(input logic [1:0] code);
        case (code)
            2'b00: decode2 = -3;
            2'b01: decode2 = -1;
            2'b10: decode2 = 1;
            2'b11: decode2 = 3;
            default: decode2 = 0;
        endcase
    endfunction

    // Compute products and sum
    logic signed [3:0] prod0, prod1;  // Range: [-9, 9]
    logic signed [4:0] pair_sum;      // Range: [-18, 18]
    
    assign prod0 = decode2(a0) * decode2(w0);
    assign prod1 = decode2(a1) * decode2(w1);
    assign pair_sum = prod0 + prod1;

    // Apply offset and shift: (pair_sum + 18) >> 1
    // pair_sum range [-18, 18], so pair_sum + 18 range [0, 36]
    // After >> 1: range [0, 18]
    logic [5:0] offset_sum;
    assign offset_sum = pair_sum + 6'd18;
    assign out_data = offset_sum[5:1];  // Divide by 2

endmodule
