//============================================================================
// conv3x3_accel_top.sv
// Low-bit Conv3x3 FPGA Accelerator Top-Level Module
//
// Based on AGENTS.md specification §4, §5
// Features:
//   - Layer-wise processing
//   - 2/4/8/16 bit activation and weight support
//   - Stride 1 or 2
//   - Inter-cycle accumulation for input channel groups
//   - Constraint checking with error codes
//============================================================================

module conv3x3_accel_top #(
    parameter int BUS_W        = 128,       // Data bus width
    parameter int IC2_LANES    = 16,        // Fixed: 2-bit activation lanes
    parameter int OC2_LANES    = 16,        // Fixed: 2-bit weight lanes
    parameter int MAX_W        = 256,       // Max width
    parameter int MAX_H        = 256,       // Max height
    parameter int MAX_IC       = 256,       // Max input channels
    parameter int MAX_OC       = 256,       // Max output channels
    parameter int ACC_W        = 32,        // Accumulator width
    parameter int KH           = 3,         // Kernel height (fixed)
    parameter int KW           = 3          // Kernel width (fixed)
)(
    //========================================================================
    // Clock and Reset
    //========================================================================
    input  logic        clk,
    input  logic        rst_n,

    //========================================================================
    // Configuration Interface (§4.3)
    //========================================================================
    input  logic        cfg_valid,
    output logic        cfg_ready,
    input  logic [15:0] cfg_W, cfg_H,       // Input dimensions
    input  logic [15:0] cfg_IC, cfg_OC,     // Channel dimensions
    input  logic        cfg_stride,         // 0=stride1, 1=stride2
    input  logic [4:0]  cfg_act_bits,       // 2, 4, 8, 16
    input  logic [4:0]  cfg_wgt_bits,       // 2, 4, 8, 16
    input  logic        cfg_mode_raw_out,   // 1=raw ACC_W output (MVP)

    input  logic        start,              // Start pulse
    output logic        done,               // Layer done
    output logic [3:0]  error_code,         // Error code (0=none)

    //========================================================================
    // Weight Input Stream (§4.4)
    //========================================================================
    input  logic        wgt_in_valid,
    output logic        wgt_in_ready,
    input  logic [BUS_W-1:0] wgt_in_data,
    input  logic        wgt_in_last,

    //========================================================================
    // Activation Input Stream
    //========================================================================
    input  logic        act_in_valid,
    output logic        act_in_ready,
    input  logic [BUS_W-1:0] act_in_data,
    input  logic        act_in_last,

    //========================================================================
    // Output Stream
    //========================================================================
    output logic        out_valid,
    input  logic        out_ready,
    output logic [BUS_W-1:0] out_data,
    output logic        out_last
);

    //========================================================================
    // Local Parameters and Derived Values
    //========================================================================
    
    // Calculate slices from bitwidth
    function automatic logic [3:0] calc_slices(input logic [4:0] bits);
        case (bits)
            5'd2:  return 4'd1;
            5'd4:  return 4'd2;
            5'd8:  return 4'd4;
            5'd16: return 4'd8;
            default: return 4'd1;
        endcase
    endfunction
    
    // Calculate output dimensions
    function automatic logic [15:0] calc_out_dim(
        input logic [15:0] in_dim, 
        input logic stride
    );
        if (in_dim < 16'd3)
            return 16'd0;
        else if (stride)
            return ((in_dim - 16'd3) >> 1) + 16'd1;
        else
            return (in_dim - 16'd3) + 16'd1;
    endfunction

    //========================================================================
    // Configuration Registers
    //========================================================================
    logic [15:0] r_W, r_H, r_IC, r_OC;
    logic        r_stride;
    logic [4:0]  r_act_bits, r_wgt_bits;
    logic [3:0]  r_act_slices, r_wgt_slices;
    logic [4:0]  r_IC_CH_PER_CYCLE;     // Channels per cycle for input
    logic [4:0]  r_OC_CH_PER_CYCLE;     // Channels per cycle for output
    logic [7:0]  r_num_ic_grp;          // Number of input channel groups
    logic [7:0]  r_num_oc_grp;          // Number of output channel groups
    logic [15:0] r_OH, r_OW;            // Output dimensions
    
    // Config valid flag
    logic config_valid;
    logic config_error;
    logic [3:0] config_error_code;

    //========================================================================
    // Error Code Definitions (§4.3)
    //========================================================================
    localparam logic [3:0] ERR_NONE           = 4'd0;
    localparam logic [3:0] ERR_STRIDE         = 4'd1;
    localparam logic [3:0] ERR_ACT_BITS       = 4'd2;
    localparam logic [3:0] ERR_WGT_BITS       = 4'd3;
    localparam logic [3:0] ERR_MVP_RESTRICTION = 4'd4;
    localparam logic [3:0] ERR_IC_ALIGN       = 4'd5;
    localparam logic [3:0] ERR_OC_ALIGN       = 4'd6;
    localparam logic [3:0] ERR_SIZE_EXCEED    = 4'd7;

    //========================================================================
    // Constraint Checking (§4.3)
    //========================================================================
    logic [3:0] check_slices_act, check_slices_wgt;
    logic [4:0] check_ic_ch_per_cycle, check_oc_ch_per_cycle;
    logic       check_error;
    logic [3:0] check_error_code;
    
    always_comb begin
        check_slices_act = calc_slices(cfg_act_bits);
        check_slices_wgt = calc_slices(cfg_wgt_bits);
        check_ic_ch_per_cycle = IC2_LANES[4:0] / check_slices_act;
        check_oc_ch_per_cycle = OC2_LANES[4:0] / check_slices_wgt;
        
        check_error = 1'b0;
        check_error_code = ERR_NONE;
        
        // Check 1: stride ∈ {0,1}
        if (!check_error && (cfg_stride !== 1'b0 && cfg_stride !== 1'b1)) begin
            check_error = 1'b1;
            check_error_code = ERR_STRIDE;
        end
        
        // Check 2: act_bits ∈ {2,4,8,16}
        if (!check_error && 
            !(cfg_act_bits == 5'd2 || cfg_act_bits == 5'd4 || 
              cfg_act_bits == 5'd8 || cfg_act_bits == 5'd16)) begin
            check_error = 1'b1;
            check_error_code = ERR_ACT_BITS;
        end
        
        // Check 3: wgt_bits ∈ {2,4,8,16}
        if (!check_error && 
            !(cfg_wgt_bits == 5'd2 || cfg_wgt_bits == 5'd4 || 
              cfg_wgt_bits == 5'd8 || cfg_wgt_bits == 5'd16)) begin
            check_error = 1'b1;
            check_error_code = ERR_WGT_BITS;
        end
        
        // Check 4: MVP restriction - not both > 2
        if (!check_error && (cfg_act_bits > 5'd2 && cfg_wgt_bits > 5'd2)) begin
            check_error = 1'b1;
            check_error_code = ERR_MVP_RESTRICTION;
        end
        
        // Check 5: IC % IC_CH_PER_CYCLE == 0
        if (!check_error && (cfg_IC % check_ic_ch_per_cycle) != 16'd0) begin
            check_error = 1'b1;
            check_error_code = ERR_IC_ALIGN;
        end
        
        // Check 6: OC % OC_CH_PER_CYCLE == 0
        if (!check_error && (cfg_OC % check_oc_ch_per_cycle) != 16'd0) begin
            check_error = 1'b1;
            check_error_code = ERR_OC_ALIGN;
        end
        
        // Check 7: Size limits
        if (!check_error && 
            (cfg_W > MAX_W || cfg_H > MAX_H || cfg_IC > MAX_IC || cfg_OC > MAX_OC)) begin
            check_error = 1'b1;
            check_error_code = ERR_SIZE_EXCEED;
        end
    end

    //========================================================================
    // Configuration Loading
    //========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_W <= 16'd0;
            r_H <= 16'd0;
            r_IC <= 16'd0;
            r_OC <= 16'd0;
            r_stride <= 1'b0;
            r_act_bits <= 5'd0;
            r_wgt_bits <= 5'd0;
            r_act_slices <= 4'd0;
            r_wgt_slices <= 4'd0;
            r_IC_CH_PER_CYCLE <= 5'd0;
            r_OC_CH_PER_CYCLE <= 5'd0;
            r_num_ic_grp <= 8'd0;
            r_num_oc_grp <= 8'd0;
            r_OH <= 16'd0;
            r_OW <= 16'd0;
            config_valid <= 1'b0;
            config_error <= 1'b0;
            config_error_code <= ERR_NONE;
        end else begin
            if (cfg_valid && cfg_ready) begin
                if (check_error) begin
                    // Configuration error
                    config_error <= 1'b1;
                    config_error_code <= check_error_code;
                    config_valid <= 1'b0;
                end else begin
                    // Load valid configuration
                    r_W <= cfg_W;
                    r_H <= cfg_H;
                    r_IC <= cfg_IC;
                    r_OC <= cfg_OC;
                    r_stride <= cfg_stride;
                    r_act_bits <= cfg_act_bits;
                    r_wgt_bits <= cfg_wgt_bits;
                    
                    r_act_slices <= check_slices_act;
                    r_wgt_slices <= check_slices_wgt;
                    r_IC_CH_PER_CYCLE <= check_ic_ch_per_cycle;
                    r_OC_CH_PER_CYCLE <= check_oc_ch_per_cycle;
                    
                    r_num_ic_grp <= cfg_IC[7:0] / check_ic_ch_per_cycle[7:0];
                    r_num_oc_grp <= cfg_OC[7:0] / check_oc_ch_per_cycle[7:0];
                    
                    r_OH <= calc_out_dim(cfg_H, cfg_stride);
                    r_OW <= calc_out_dim(cfg_W, cfg_stride);
                    
                    config_valid <= 1'b1;
                    config_error <= 1'b0;
                    config_error_code <= ERR_NONE;
                end
            end else if (state == ST_DONE) begin
                // Clear config valid when done
                config_valid <= 1'b0;
                config_error <= 1'b0;
            end
        end
    end

    //========================================================================
    // Top-Level FSM States (§5)
    //========================================================================
    typedef enum logic [3:0] {
        ST_IDLE,            // Wait for config and start
        ST_CFG_ERROR,       // Configuration error state
        ST_LOAD_WGT,        // Load weights into weight_buffer
        ST_LOAD_ACT_AND_CONV, // Load activation and perform convolution
        ST_DRAIN_OUT,       // Drain output packer
        ST_DONE             // Layer complete
    } state_t;
    
    state_t state, next_state;

    //========================================================================
    // Weight Loading State
    //========================================================================
    logic wgt_load_done;
    
    //========================================================================
    // Convolution Control Variables
    //========================================================================
    // Loop indices: oy -> ox -> oc_grp -> ic_grp
    logic [15:0] loop_oy, loop_ox;
    logic [7:0]  loop_oc_grp, loop_ic_grp;
    
    // Loop control signals
    logic loop_advancing;
    logic ic_grp_done, oc_grp_done, ox_done, oy_done;
    logic last_window;
    
    // Line buffer status
    logic linebuf_ready;
    logic linebuf_done;
    
    //========================================================================
    // Inter-Cycle Accumulator (§5, accumulator in top)
    //========================================================================
    // Accumulator buffer for OC_CH_PER_CYCLE output channels
    // Stores partial sums across ic_grp iterations
    logic signed [ACC_W-1:0] acc_buf [0:15];  // Max 16 channels
    logic acc_valid;
    logic acc_last;
    
    //========================================================================
    // Submodule Connections
    //========================================================================
    
    // Feature Line Buffer connections
    logic        flb_cfg_ready;
    logic        flb_win_valid;
    logic        flb_win_ready;
    logic [15:0] flb_win_y, flb_win_x;
    logic [7:0]  flb_win_ic_grp;
    logic [1:0]  flb_win_act2 [0:2][0:2][0:IC2_LANES-1];
    
    // Weight Buffer connections
    logic        wbuf_cfg_ready;
    logic        wbuf_wgt_in_ready;
    logic        wbuf_load_done;
    logic [7:0]  wbuf_req_oc_grp;
    logic [7:0]  wbuf_req_ic_grp;
    logic        wbuf_req_valid;
    logic        wbuf_req_ready;
    logic [1:0]  wbuf_wgt2 [0:OC2_LANES-1][0:KH-1][0:KW-1][0:IC2_LANES-1];
    logic        wbuf_wgt_valid;
    logic        wbuf_wgt_ready;
    
    // Conv Core connections
    logic        core_in_valid;
    logic        core_in_ready;
    logic        core_out_valid;
    logic        core_out_ready;
    logic signed [ACC_W-1:0] core_partial [0:OC2_LANES-1];
    
    // Other Ops Stub connections
    logic        stub_in_valid;
    logic        stub_in_ready;
    logic signed [ACC_W-1:0] stub_in_data;
    logic        stub_in_last;
    logic        stub_out_valid;
    logic        stub_out_ready;
    logic signed [ACC_W-1:0] stub_out_data;
    logic        stub_out_last;
    
    // Output Packer connections
    logic        packer_in_valid;
    logic        packer_in_ready;
    logic signed [ACC_W-1:0] packer_in_data;
    logic        packer_in_last;

    //========================================================================
    // FSM State Transitions
    //========================================================================
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
                if (cfg_valid && cfg_ready) begin
                    if (check_error)
                        next_state = ST_CFG_ERROR;
                    else if (start)
                        next_state = ST_LOAD_WGT;
                end
            end
            
            ST_CFG_ERROR: begin
                if (start)
                    next_state = ST_DONE;  // Go to done to report error
            end
            
            ST_LOAD_WGT: begin
                // Wait for weight loading to complete
                if (wbuf_load_done)
                    next_state = ST_LOAD_ACT_AND_CONV;
            end
            
            ST_LOAD_ACT_AND_CONV: begin
                // Wait for line buffer to finish and all loops to complete
                if (linebuf_done && loop_oy >= r_OH)
                    next_state = ST_DRAIN_OUT;
            end
            
            ST_DRAIN_OUT: begin
                // Wait for output packer to drain
                if (packer_in_last && packer_in_valid && packer_in_ready)
                    next_state = ST_DONE;
            end
            
            ST_DONE: begin
                next_state = ST_IDLE;
            end
            
            default: next_state = ST_IDLE;
        endcase
    end

    //========================================================================
    // FSM Output Logic and Control
    //========================================================================
    
    // cfg_ready: Accept config only in IDLE
    assign cfg_ready = (state == ST_IDLE);
    
    // done: Assert in DONE state
    assign done = (state == ST_DONE);
    
    // error_code: Output current error
    assign error_code = config_error_code;
    
    //========================================================================
    // Weight Loading Control
    //========================================================================
    assign wgt_in_ready = (state == ST_LOAD_WGT) ? wbuf_wgt_in_ready : 1'b0;

    //========================================================================
    // Convolution Loop Control (§5)
    // Loop order: oy -> ox -> oc_grp -> ic_grp
    //========================================================================
    
    // Advance condition: current window processed by conv core
    assign loop_advancing = (state == ST_LOAD_ACT_AND_CONV) && 
                            flb_win_valid && wbuf_wgt_valid && 
                            core_in_valid && core_in_ready;
    
    // Done signals for each loop level
    assign ic_grp_done = (loop_ic_grp + 8'd1 >= r_num_ic_grp);
    assign oc_grp_done = (loop_oc_grp + 8'd1 >= r_num_oc_grp);
    assign ox_done = (loop_ox + 16'd1 >= r_OW);
    assign oy_done = (loop_oy + 16'd1 >= r_OH);
    assign last_window = oy_done && ox_done && oc_grp_done && ic_grp_done;
    
    // Loop counters
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            loop_oy <= 16'd0;
            loop_ox <= 16'd0;
            loop_oc_grp <= 8'd0;
            loop_ic_grp <= 8'd0;
        end else begin
            case (state)
                ST_IDLE, ST_LOAD_WGT: begin
                    loop_oy <= 16'd0;
                    loop_ox <= 16'd0;
                    loop_oc_grp <= 8'd0;
                    loop_ic_grp <= 8'd0;
                end
                
                ST_LOAD_ACT_AND_CONV: begin
                    if (loop_advancing) begin
                        // Advance ic_grp first
                        if (!ic_grp_done) begin
                            loop_ic_grp <= loop_ic_grp + 8'd1;
                        end else begin
                            loop_ic_grp <= 8'd0;
                            
                            // Then oc_grp
                            if (!oc_grp_done) begin
                                loop_oc_grp <= loop_oc_grp + 8'd1;
                            end else begin
                                loop_oc_grp <= 8'd0;
                                
                                // Then ox
                                if (!ox_done) begin
                                    loop_ox <= loop_ox + 16'd1;
                                end else begin
                                    loop_ox <= 16'd0;
                                    
                                    // Finally oy
                                    if (!oy_done) begin
                                        loop_oy <= loop_oy + 16'd1;
                                    end
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
    // Feature Line Buffer Interface
    //========================================================================
    assign flb_win_ready = (state == ST_LOAD_ACT_AND_CONV) && 
                           wbuf_wgt_valid && core_in_ready;

    //========================================================================
    // Weight Buffer Request Interface
    //========================================================================
    assign wbuf_req_oc_grp = loop_oc_grp;
    assign wbuf_req_ic_grp = loop_ic_grp;
    assign wbuf_req_valid = (state == ST_LOAD_ACT_AND_CONV) && flb_win_valid;
    assign wbuf_wgt_ready = (state == ST_LOAD_ACT_AND_CONV) && 
                            flb_win_valid && core_in_ready;

    //========================================================================
    // Conv Core Input Interface
    //========================================================================
    assign core_in_valid = (state == ST_LOAD_ACT_AND_CONV) && 
                           flb_win_valid && wbuf_wgt_valid;
    assign core_out_ready = 1'b1;  // Always ready to accept core output

    //========================================================================
    // Inter-Cycle Accumulator Logic (§5)
    // Accumulate partial results across ic_grp for same (oy, ox, oc_grp)
    //========================================================================
    
    // Determine if this is the first or last ic_grp for current window
    logic is_first_ic_grp;
    logic is_last_ic_grp;
    
    assign is_first_ic_grp = (loop_ic_grp == 8'd0);
    assign is_last_ic_grp = (loop_ic_grp + 8'd1 >= r_num_ic_grp);
    
    // Accumulator update
    logic signed [ACC_W-1:0] acc_result [0:15];
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 16; i++) begin
                acc_buf[i] <= '0;
            end
            acc_valid <= 1'b0;
            acc_last <= 1'b0;
        end else begin
            acc_valid <= 1'b0;
            
            if (core_out_valid) begin
                for (int i = 0; i < 16; i++) begin
                    if (i < r_OC_CH_PER_CYCLE) begin
                        if (is_first_ic_grp) begin
                            // First ic_grp: initialize accumulator
                            acc_buf[i] <= core_partial[i];
                        end else begin
                            // Subsequent ic_grp: accumulate
                            acc_buf[i] <= acc_buf[i] + core_partial[i];
                        end
                    end
                end
                
                // Output valid when last ic_grp is processed
                if (is_last_ic_grp) begin
                    acc_valid <= 1'b1;
                    acc_last <= last_window;
                end
            end
        end
    end
    
    // Output from accumulator (when is_last_ic_grp)
    always_comb begin
        for (int i = 0; i < 16; i++) begin
            if (i < r_OC_CH_PER_CYCLE) begin
                acc_result[i] = acc_buf[i];
            end else begin
                acc_result[i] = '0;
            end
        end
    end

    //========================================================================
    // Output Serialization (Convert parallel OC_CH_PER_CYCLE to serial)
    //========================================================================
    logic [3:0] out_serial_cnt;
    logic out_serial_active;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_serial_cnt <= 4'd0;
            out_serial_active <= 1'b0;
        end else begin
            if (acc_valid && !out_serial_active) begin
                // Start serialization
                out_serial_active <= 1'b1;
                out_serial_cnt <= 4'd0;
            end else if (out_serial_active && stub_in_ready) begin
                // Advance serialization
                if (out_serial_cnt + 4'd1 < r_OC_CH_PER_CYCLE) begin
                    out_serial_cnt <= out_serial_cnt + 4'd1;
                end else begin
                    out_serial_active <= 1'b0;
                end
            end
        end
    end
    
    // Stub input (serialized)
    assign stub_in_valid = out_serial_active;
    assign stub_in_data = acc_result[out_serial_cnt];
    assign stub_in_last = acc_last && out_serial_active && 
                          (out_serial_cnt + 4'd1 >= r_OC_CH_PER_CYCLE);

    //========================================================================
    // Other Ops Stub -> Output Packer
    //========================================================================
    assign stub_out_ready = packer_in_ready;
    assign packer_in_valid = stub_out_valid;
    assign packer_in_data = stub_out_data;
    assign packer_in_last = stub_out_last;

    //========================================================================
    // Submodule Instantiations
    //========================================================================

    //----------------------------------------------------------------------
    // Feature Line Buffer
    //----------------------------------------------------------------------
    feature_line_buffer #(
        .MAX_W(MAX_W),
        .MAX_H(MAX_H),
        .MAX_IC(MAX_IC),
        .BUS_W(BUS_W),
        .IC2_LANES(IC2_LANES)
    ) u_feature_line_buffer (
        .clk(clk),
        .rst_n(rst_n),
        
        // Config
        .cfg_W(r_W),
        .cfg_H(r_H),
        .cfg_IC(r_IC),
        .cfg_act_bits(r_act_bits),
        .cfg_stride(r_stride),
        .cfg_valid(config_valid && (state == ST_IDLE || state == ST_LOAD_WGT)),
        .cfg_ready(flb_cfg_ready),
        
        // Activation input stream
        .act_in_valid(act_in_valid),
        .act_in_ready(act_in_ready),
        .act_in_data(act_in_data),
        .act_in_last(act_in_last),
        
        // Window output
        .win_valid(flb_win_valid),
        .win_ready(flb_win_ready),
        .win_y(flb_win_y),
        .win_x(flb_win_x),
        .win_ic_grp(flb_win_ic_grp),
        .win_act2(flb_win_act2),
        
        // Status
        .linebuf_ready(linebuf_ready),
        .layer_done(linebuf_done)
    );

    //----------------------------------------------------------------------
    // Weight Buffer
    //----------------------------------------------------------------------
    weight_buffer #(
        .MAX_IC(MAX_IC),
        .MAX_OC(MAX_OC),
        .BUS_W(BUS_W),
        .IC2_LANES(IC2_LANES),
        .OC2_LANES(OC2_LANES),
        .KH(KH),
        .KW(KW)
    ) u_weight_buffer (
        .clk(clk),
        .rst_n(rst_n),
        
        // Config
        .cfg_IC(r_IC),
        .cfg_OC(r_OC),
        .cfg_wgt_bits(r_wgt_bits),
        .cfg_valid(config_valid && (state == ST_IDLE)),
        .cfg_ready(wbuf_cfg_ready),
        
        // Weight input stream
        .wgt_in_valid(wgt_in_valid),
        .wgt_in_ready(wbuf_wgt_in_ready),
        .wgt_in_data(wgt_in_data),
        .wgt_in_last(wgt_in_last),
        .wgt_load_done(wbuf_load_done),
        
        // Request interface
        .req_oc_grp(wbuf_req_oc_grp),
        .req_ic_grp(wbuf_req_ic_grp),
        .req_valid(wbuf_req_valid),
        .req_ready(wbuf_req_ready),
        
        // Weight output
        .wgt2(wbuf_wgt2),
        .wgt_valid(wbuf_wgt_valid),
        .wgt_ready(wbuf_wgt_ready)
    );

    //----------------------------------------------------------------------
    // Conv Core Lowbit
    //----------------------------------------------------------------------
    conv_core_lowbit #(
        .IC2_LANES(IC2_LANES),
        .OC2_LANES(OC2_LANES),
        .KH(KH),
        .KW(KW),
        .ACC_W(ACC_W)
    ) u_conv_core_lowbit (
        .clk(clk),
        .rst_n(rst_n),
        
        // Input
        .in_valid(core_in_valid),
        .in_ready(core_in_ready),
        .act2(flb_win_act2),
        .wgt2(wbuf_wgt2),
        .act_bits(r_act_bits),
        .wgt_bits(r_wgt_bits),
        
        // Output
        .out_valid(core_out_valid),
        .out_ready(core_out_ready),
        .partial(core_partial)
    );

    //----------------------------------------------------------------------
    // Other Ops Stub (MVP: pass-through)
    //----------------------------------------------------------------------
    other_ops_stub #(
        .ACC_W(ACC_W),
        .OUT_BITS(ACC_W)
    ) u_other_ops_stub (
        .clk(clk),
        .rst_n(rst_n),
        
        .in_valid(stub_in_valid),
        .in_ready(stub_in_ready),
        .in_data(stub_in_data),
        .in_last(stub_in_last),
        
        .out_valid(stub_out_valid),
        .out_ready(stub_out_ready),
        .out_data(stub_out_data),
        .out_last(stub_out_last)
    );

    //----------------------------------------------------------------------
    // Output Packer
    //----------------------------------------------------------------------
    output_packer #(
        .ACC_W(ACC_W),
        .BUS_W(BUS_W)
    ) u_output_packer (
        .clk(clk),
        .rst_n(rst_n),
        
        // Input from stub
        .in_valid(packer_in_valid),
        .in_ready(packer_in_ready),
        .in_data(packer_in_data),
        .in_last(packer_in_last),
        
        // Output to external stream
        .out_valid(out_valid),
        .out_ready(out_ready),
        .out_data(out_data),
        .out_last(out_last)
    );

    //========================================================================
    // Simulation Assertions
    //========================================================================
    `ifdef SIMULATION
        // Check state transitions
        always @(posedge clk) begin
            if (state == ST_CFG_ERROR) begin
                $display("[conv3x3_accel_top] Configuration error: code=%0d", error_code);
            end
        end
        
        // Check loop invariants
        always @(posedge clk) begin
            if (state == ST_LOAD_ACT_AND_CONV && loop_advancing) begin
                // Verify line buffer coordinates match loop counters
                if (flb_win_y != loop_oy || flb_win_x != loop_ox)
                    $error("[conv3x3_accel_top] Window coordinate mismatch! ");
            end
        end
    `endif

endmodule
