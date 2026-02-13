//============================================================================
// Feature Line Buffer - 3x3 Convolution Window Generator
// 
// Supports:
// - Variable input dimensions (W, H, IC)
// - Variable activation bitwidth (2/4/8/16)
// - Stride 1 or 2
// - 2-bit slice lane mapping for high-bitwidth activations
// - Backpressure handling
//============================================================================

module feature_line_buffer #(
    parameter int MAX_W        = 256,
    parameter int MAX_H        = 256,
    parameter int MAX_IC       = 256,
    parameter int BUS_W        = 128,
    parameter int IC2_LANES    = 16
)(
    // Clock and reset
    input  logic        clk,
    input  logic        rst_n,

    // Configuration interface (layer-wise)
    input  logic [15:0] cfg_W,
    input  logic [15:0] cfg_H,
    input  logic [15:0] cfg_IC,
    input  logic [4:0]  cfg_act_bits,   // 2, 4, 8, 16
    input  logic        cfg_stride,     // 0=1, 1=2
    input  logic        cfg_valid,
    output logic        cfg_ready,

    // Activation input stream
    input  logic        act_in_valid,
    output logic        act_in_ready,
    input  logic [BUS_W-1:0] act_in_data,
    input  logic        act_in_last,

    // Output to conv_core
    output logic        win_valid,
    input  logic        win_ready,
    output logic [15:0] win_y,
    output logic [15:0] win_x,
    output logic [7:0]  win_ic_grp,
    output logic [1:0]  win_act2 [0:2][0:2][0:IC2_LANES-1],

    // Status outputs
    output logic        linebuf_ready,
    output logic        layer_done
);

    //========================================================================
    // Local Parameters
    //========================================================================
    
    localparam int MAX_ROW_ELEMS = MAX_W * MAX_IC;
    localparam int MAX_ACT_BITS  = 16;
    localparam int ROW_BITS      = MAX_ACT_BITS;
    localparam int ELEM_CNT_W    = $clog2(MAX_ROW_ELEMS + 1);
    
    //========================================================================
    // FSM States
    //========================================================================
    
    typedef enum logic [2:0] {
        ST_IDLE,
        ST_FILL_ROWS,       // Fill initial 3 rows
        ST_PROCESS_WIN,     // Process windows
        ST_DRAIN,           // Drain remaining windows
        ST_DONE
    } state_t;
    
    state_t state, next_state;

    //========================================================================
    // Configuration Registers
    //========================================================================
    
    logic [15:0] r_W, r_H, r_IC;
    logic [4:0]  r_act_bits;
    logic        r_stride;
    logic [15:0] r_OH, r_OW;
    
    logic [2:0]  r_act_slices;
    logic [4:0]  r_IC_CH_PER_CYCLE;
    logic [7:0]  r_num_ic_grp;
    logic [ELEM_CNT_W-1:0] r_elems_per_row;
    
    // Configuration valid flag
    logic cfg_loaded;

    //========================================================================
    // Helper Functions
    //========================================================================
    
    function automatic logic [2:0] calc_slices(input logic [4:0] bits);
        case (bits)
            5'd2:  return 3'd1;
            5'd4:  return 3'd2;
            5'd8:  return 3'd4;
            5'd16: return 3'd8;
            default: return 3'd1;
        endcase
    endfunction
    
    function automatic logic [15:0] calc_out_dim(input logic [15:0] in_dim, input logic stride);
        if (in_dim < 16'd3)
            return 16'd0;
        else if (stride)
            return ((in_dim - 16'd3) >> 1) + 16'd1;
        else
            return (in_dim - 16'd3) + 16'd1;
    endfunction

    //========================================================================
    // Configuration Loading
    //========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_W <= 16'd0;
            r_H <= 16'd0;
            r_IC <= 16'd0;
            r_act_bits <= 5'd0;
            r_stride <= 1'b0;
            r_OH <= 16'd0;
            r_OW <= 16'd0;
            r_act_slices <= 3'd0;
            r_IC_CH_PER_CYCLE <= 5'd0;
            r_num_ic_grp <= 8'd0;
            r_elems_per_row <= '0;
            cfg_loaded <= 1'b0;
        end else if (cfg_valid && cfg_ready) begin
            r_W <= cfg_W;
            r_H <= cfg_H;
            r_IC <= cfg_IC;
            r_act_bits <= cfg_act_bits;
            r_stride <= cfg_stride;
            
            r_act_slices <= calc_slices(cfg_act_bits);
            r_IC_CH_PER_CYCLE <= IC2_LANES[4:0] / calc_slices(cfg_act_bits);
            r_num_ic_grp <= cfg_IC[7:0] / (IC2_LANES[7:0] / {5'd0, calc_slices(cfg_act_bits)});
            r_elems_per_row <= cfg_W * cfg_IC;
            
            r_OH <= calc_out_dim(cfg_H, cfg_stride);
            r_OW <= calc_out_dim(cfg_W, cfg_stride);
            cfg_loaded <= 1'b1;
        end else if (state == ST_DONE) begin
            cfg_loaded <= 1'b0;
        end
    end
    
    assign cfg_ready = (state == ST_IDLE);

    //========================================================================
    // Line Buffer Storage (3 rows)
    //========================================================================
    
    logic [ROW_BITS-1:0] row_mem [0:2][0:MAX_ROW_ELEMS-1];
    
    // Write control
    logic [1:0]  wr_row_idx;
    logic [ELEM_CNT_W-1:0] wr_elem_idx;
    logic [15:0] wr_y_pos;
    
    // Row status - tracks which rows have been filled
    logic [2:0] row_filled;
    
    //========================================================================
    // Input Buffer and Element Extraction
    //========================================================================
    
    // Accumulate input bits and extract elements
    localparam int INBUF_BITS = BUS_W * 2;  // Buffer up to 2 beats
    localparam int INBUF_CNT_W = $clog2(INBUF_BITS + 1);
    
    logic [INBUF_BITS-1:0] inbuf;
    logic [INBUF_CNT_W-1:0] inbuf_valid;
    
    logic [4:0] bits_per_elem;
    assign bits_per_elem = r_act_bits;
    
    wire can_extract = (inbuf_valid >= { {(INBUF_CNT_W-5){1'b0}}, bits_per_elem }) && 
                       cfg_loaded && (bits_per_elem > 0);
    wire can_accept = (inbuf_valid <= (INBUF_BITS[INBUF_CNT_W-1:0] - BUS_W[INBUF_CNT_W-1:0]));
    
    // Extract element from LSB of buffer
    logic [MAX_ACT_BITS-1:0] extract_elem;
    assign extract_elem = inbuf[MAX_ACT_BITS-1:0] & 
                          ({MAX_ACT_BITS{1'b1}} >> (MAX_ACT_BITS - bits_per_elem));

    //========================================================================
    // Input Stream Handling
    //========================================================================
    
    assign act_in_ready = ((state == ST_FILL_ROWS) || (state == ST_PROCESS_WIN)) && 
                          can_accept && (wr_y_pos < r_H) && cfg_loaded;
    
    // Buffer update logic
    logic do_extract, do_shift_in;
    assign do_extract = can_extract && (wr_elem_idx < r_elems_per_row) && (wr_y_pos < r_H);
    assign do_shift_in = act_in_valid && act_in_ready;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            inbuf <= '0;
            inbuf_valid <= '0;
        end else begin
            case ({do_shift_in, do_extract})
                2'b00: ; // No operation
                
                2'b01: begin // Extract only
                    inbuf <= inbuf >> bits_per_elem;
                    inbuf_valid <= inbuf_valid - { {(INBUF_CNT_W-5){1'b0}}, bits_per_elem };
                end
                
                2'b10: begin // Shift in only
                    // Append new data at MSB side
                    inbuf <= (act_in_data << inbuf_valid) | inbuf;
                    inbuf_valid <= inbuf_valid + BUS_W[INBUF_CNT_W-1:0];
                end
                
                2'b11: begin // Both extract and shift in
                    // First extract (shift right), then append new data
                    logic [INBUF_BITS-1:0] after_extract;
                    after_extract = inbuf >> bits_per_elem;
                    inbuf <= (act_in_data << (inbuf_valid - { {(INBUF_CNT_W-5){1'b0}}, bits_per_elem })) | 
                             after_extract;
                    inbuf_valid <= inbuf_valid - { {(INBUF_CNT_W-5){1'b0}}, bits_per_elem } + 
                                   BUS_W[INBUF_CNT_W-1:0];
                end
            endcase
        end
    end

    //========================================================================
    // Write Logic - Store elements into row buffers
    //========================================================================
    
    logic input_complete;
    assign input_complete = (wr_y_pos >= r_H) || 
                            (act_in_last && act_in_valid && act_in_ready);
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_row_idx <= 2'd0;
            wr_elem_idx <= '0;
            wr_y_pos <= 16'd0;
            row_filled <= 3'b000;
        end else begin
            case (state)
                ST_IDLE: begin
                    wr_row_idx <= 2'd0;
                    wr_elem_idx <= '0;
                    wr_y_pos <= 16'd0;
                    row_filled <= 3'b000;
                end
                
                ST_FILL_ROWS, ST_PROCESS_WIN: begin
                    if (do_extract) begin
                        // Write element to current row
                        row_mem[wr_row_idx][wr_elem_idx] <= extract_elem;
                        
                        // Update write pointers
                        if (wr_elem_idx + 1 >= r_elems_per_row) begin
                            // Row complete
                            wr_elem_idx <= '0;
                            row_filled[wr_row_idx] <= 1'b1;
                            
                            if (wr_y_pos + 1 < r_H) begin
                                wr_y_pos <= wr_y_pos + 16'd1;
                                // Move to next row (circular)
                                wr_row_idx <= (wr_row_idx == 2'd2) ? 2'd0 : wr_row_idx + 2'd1;
                            end else begin
                                wr_y_pos <= wr_y_pos + 16'd1;
                            end
                        end else begin
                            wr_elem_idx <= wr_elem_idx + 1'b1;
                        end
                    end
                end
                
                default: ; // Hold values
            endcase
        end
    end

    //========================================================================
    // FSM State Machine
    //========================================================================
    
    logic all_rows_ready;
    assign all_rows_ready = (row_filled[0] & row_filled[1] & row_filled[2]);
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= ST_IDLE;
        else
            state <= next_state;
    end
    
    always_comb begin
        next_state = state;
        
        case (state)
            ST_IDLE: begin
                if (cfg_valid)
                    next_state = ST_FILL_ROWS;
            end
            
            ST_FILL_ROWS: begin
                if (all_rows_ready)
                    next_state = ST_PROCESS_WIN;
                else if (input_complete && !all_rows_ready)
                    next_state = ST_DONE;
            end
            
            ST_PROCESS_WIN: begin
                if (input_complete && win_valid && win_ready && 
                    (win_y >= r_OH - 1) && (win_x >= r_OW - 1) && (win_ic_grp >= r_num_ic_grp - 1))
                    next_state = ST_DRAIN;
            end
            
            ST_DRAIN: begin
                if (win_valid && win_ready && 
                    (win_y >= r_OH - 1) && (win_x >= r_OW - 1) && (win_ic_grp >= r_num_ic_grp - 1))
                    next_state = ST_DONE;
            end
            
            ST_DONE: begin
                next_state = ST_IDLE;
            end
            
            default: next_state = ST_IDLE;
        endcase
    end

    //========================================================================
    // Window Generation - Output position tracking
    //========================================================================
    
    logic [15:0] out_y, out_x;
    logic [7:0]  out_ic_grp;
    logic [1:0] rd_base_row;
    
    // Calculate input base coordinates
    logic [15:0] in_y_base, in_x_base;
    
    always_comb begin
        in_y_base = r_stride ? (out_y << 1) : out_y;
        in_x_base = r_stride ? (out_x << 1) : out_x;
    end
    
    // Window advancement
    logic win_advancing;
    logic ic_grp_done, x_done, y_done;
    
    assign win_advancing = win_valid && win_ready;
    assign ic_grp_done = (out_ic_grp + 8'd1 >= r_num_ic_grp);
    assign x_done = (out_x + 16'd1 >= r_OW);
    assign y_done = (out_y + 16'd1 >= r_OH);
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_y <= 16'd0;
            out_x <= 16'd0;
            out_ic_grp <= 8'd0;
            rd_base_row <= 2'd0;
        end else begin
            case (state)
                ST_IDLE: begin
                    out_y <= 16'd0;
                    out_x <= 16'd0;
                    out_ic_grp <= 8'd0;
                    rd_base_row <= 2'd0;
                end
                
                ST_FILL_ROWS: begin
                    if (all_rows_ready) begin
                        out_y <= 16'd0;
                        out_x <= 16'd0;
                        out_ic_grp <= 8'd0;
                        rd_base_row <= 2'd0;
                    end
                end
                
                ST_PROCESS_WIN, ST_DRAIN: begin
                    if (win_advancing) begin
                        if (!ic_grp_done) begin
                            out_ic_grp <= out_ic_grp + 8'd1;
                        end else begin
                            out_ic_grp <= 8'd0;
                            
                            if (!x_done) begin
                                out_x <= out_x + 16'd1;
                            end else begin
                                out_x <= 16'd0;
                                
                                if (!y_done) begin
                                    out_y <= out_y + 16'd1;
                                    // Advance base row by stride (modulo 3)
                                    case ({r_stride, rd_base_row})
                                        3'b0_00: rd_base_row <= 2'd1;
                                        3'b0_01: rd_base_row <= 2'd2;
                                        3'b0_10: rd_base_row <= 2'd0;
                                        3'b1_00: rd_base_row <= 2'd2;
                                        3'b1_01: rd_base_row <= 2'd0;
                                        3'b1_10: rd_base_row <= 2'd1;
                                        default: rd_base_row <= 2'd0;
                                    endcase
                                end
                            end
                        end
                    end
                end
                
                default: ; // Hold values
            endcase
        end
    end

    //========================================================================
    // Window Data Reading from Row Buffers
    //========================================================================
    
    // Row indices for 3x3 window (circular buffer addressing)
    logic [1:0] rd_row_idx [0:2];
    always_comb begin
        case (rd_base_row)
            2'd0: begin rd_row_idx[0] = 2'd0; rd_row_idx[1] = 2'd1; rd_row_idx[2] = 2'd2; end
            2'd1: begin rd_row_idx[0] = 2'd1; rd_row_idx[1] = 2'd2; rd_row_idx[2] = 2'd0; end
            2'd2: begin rd_row_idx[0] = 2'd2; rd_row_idx[1] = 2'd0; rd_row_idx[2] = 2'd1; end
            default: begin rd_row_idx[0] = 2'd0; rd_row_idx[1] = 2'd1; rd_row_idx[2] = 2'd2; end
        endcase
    end
    
    // Raw window data - registered output
    logic [ROW_BITS-1:0] raw_win [0:2][0:2][0:15];  // [kh][kw][ch]
    
    // Window position in input feature map
    logic [15:0] win_y_pos [0:2];
    logic [15:0] win_x_pos [0:2];
    
    genvar kh_g, kw_g;
    generate
        for (kh_g = 0; kh_g < 3; kh_g++) begin : gen_win_y
            always_comb win_y_pos[kh_g] = in_y_base + kh_g[15:0];
        end
        for (kw_g = 0; kw_g < 3; kw_g++) begin : gen_win_x
            always_comb win_x_pos[kw_g] = in_x_base + kw_g[15:0];
        end
    endgenerate
    
    // Address calculation: addr = ((y * W) + x) * IC + ic
    // Pre-calculate (y*W + x)*IC part for each window position
    logic [ELEM_CNT_W-1:0] addr_base [0:2][0:2];
    
    integer kh_i, kw_i;
    always_comb begin
        for (kh_i = 0; kh_i < 3; kh_i++) begin
            for (kw_i = 0; kw_i < 3; kw_i++) begin
                logic [31:0] full_addr;
                full_addr = ((win_y_pos[kh_i] * r_W + win_x_pos[kw_i]) * r_IC);
                addr_base[kh_i][kw_i] = full_addr[ELEM_CNT_W-1:0];
            end
        end
    end
    
    // Sequential read from row memories
    integer ch_i;
    logic [ELEM_CNT_W-1:0] read_addr;
    logic [15:0] abs_ic;
    
    always_ff @(posedge clk) begin
        for (kh_i = 0; kh_i < 3; kh_i++) begin
            for (kw_i = 0; kw_i < 3; kw_i++) begin
                for (ch_i = 0; ch_i < 16; ch_i++) begin
                    if (ch_i < r_IC_CH_PER_CYCLE) begin
                        abs_ic = out_ic_grp * r_IC_CH_PER_CYCLE + ch_i[15:0];
                        read_addr = addr_base[kh_i][kw_i] + abs_ic[ELEM_CNT_W-1:0];
                        
                        if (read_addr < r_elems_per_row)
                            raw_win[kh_i][kw_i][ch_i] <= row_mem[rd_row_idx[kh_i]][read_addr];
                        else
                            raw_win[kh_i][kw_i][ch_i] <= '0;
                    end else begin
                        raw_win[kh_i][kw_i][ch_i] <= '0;
                    end
                end
            end
        end
    end

    //========================================================================
    // 2-bit Slice Lane Mapping
    // Maps raw data to win_act2 according to slice-major order
    // Formula: lane = slice * IC_CH_PER_CYCLE + channel
    //========================================================================
    
    always_comb begin
        // Default assignment
        for (int y = 0; y < 3; y++) begin
            for (int x = 0; x < 3; x++) begin
                for (int lane = 0; lane < IC2_LANES; lane++) begin
                    win_act2[y][x][lane] = 2'b00;
                end
            end
        end
        
        // Map slices: slice-major order
        for (int y = 0; y < 3; y++) begin
            for (int x = 0; x < 3; x++) begin
                for (int slice = 0; slice < 8; slice++) begin
                    if (slice < r_act_slices) begin
                        for (int ch = 0; ch < 16; ch++) begin
                            if (ch < r_IC_CH_PER_CYCLE) begin
                                int lane_idx = slice * r_IC_CH_PER_CYCLE + ch;
                                if (lane_idx < IC2_LANES) begin
                                    win_act2[y][x][lane_idx] = raw_win[y][x][ch][2*slice +: 2];
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    //========================================================================
    // Output Control
    //========================================================================
    
    // Valid when in processing state and have valid window coordinates
    assign win_valid = ((state == ST_PROCESS_WIN) || (state == ST_DRAIN)) && 
                       (out_y < r_OH) && (r_OH > 16'd0);
    
    // Output coordinates
    assign win_y = out_y;
    assign win_x = out_x;
    assign win_ic_grp = out_ic_grp;
    
    // Status outputs
    assign linebuf_ready = (state == ST_PROCESS_WIN) || (state == ST_DRAIN);
    assign layer_done = (state == ST_DONE);

    //========================================================================
    // Simulation Assertions
    //========================================================================
    
`ifdef SIMULATION
    always @(posedge clk) begin
        if (cfg_valid && cfg_ready) begin
            assert (cfg_act_bits == 5'd2 || cfg_act_bits == 5'd4 || 
                    cfg_act_bits == 5'd8 || cfg_act_bits == 5'd16)
                else $error("[feature_line_buffer] Invalid act_bits: %d", cfg_act_bits);
            
            assert (cfg_W > 0 && cfg_W <= MAX_W)
                else $error("[feature_line_buffer] Invalid W: %d (max %d)", cfg_W, MAX_W);
            
            assert (cfg_H > 0 && cfg_H <= MAX_H)
                else $error("[feature_line_buffer] Invalid H: %d (max %d)", cfg_H, MAX_H);
            
            assert (cfg_IC > 0 && cfg_IC <= MAX_IC)
                else $error("[feature_line_buffer] Invalid IC: %d (max %d)", cfg_IC, MAX_IC);
                
            assert ((IC2_LANES % calc_slices(cfg_act_bits)) == 0)
                else $error("[feature_line_buffer] IC2_LANES (%d) not divisible by act_slices (%d)", 
                           IC2_LANES, calc_slices(cfg_act_bits));
        end
    end
`endif

endmodule
