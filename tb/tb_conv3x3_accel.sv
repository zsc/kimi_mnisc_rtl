//============================================================================
// Testbench: tb_conv3x3_accel.sv
// Description: Comprehensive testbench for Conv3x3 Low-bit Accelerator
// Based on AGENTS.md §8
//============================================================================

`timescale 1ns/1ps

module tb_conv3x3_accel;

    //========================================================================
    // Parameters
    //========================================================================
    localparam int CLK_PERIOD = 10;  // 100MHz
    localparam int BUS_W = 128;
    localparam int IC2_LANES = 16;
    localparam int OC2_LANES = 16;
    localparam int ACC_W = 32;
    localparam int KH = 3;
    localparam int KW = 3;
    
    // Test configuration
    localparam int MAX_TEST_SIZE = 256 * 256 * 256;  // Max elements for arrays

    //========================================================================
    // Clock and Reset
    //========================================================================
    logic clk = 0;
    logic rst_n;
    
    always #(CLK_PERIOD/2) clk = ~clk;

    //========================================================================
    // DUT Signals - Top Level Integration
    //========================================================================
    
    // Configuration interface
    logic [15:0] cfg_W, cfg_H, cfg_IC, cfg_OC;
    logic [4:0]  cfg_act_bits, cfg_wgt_bits;
    logic        cfg_stride;
    logic        cfg_valid;
    logic        cfg_ready;
    
    // Control
    logic        start;
    logic        done;
    logic [3:0]  error_code;
    
    // Weight input stream
    logic        wgt_in_valid;
    logic        wgt_in_ready;
    logic [BUS_W-1:0] wgt_in_data;
    logic        wgt_in_last;
    
    // Activation input stream
    logic        act_in_valid;
    logic        act_in_ready;
    logic [BUS_W-1:0] act_in_data;
    logic        act_in_last;
    
    // Output stream
    logic        out_valid;
    logic        out_ready;
    logic [BUS_W-1:0] out_data;
    logic        out_last;

    //========================================================================
    // Internal Connections Between Modules
    //========================================================================
    
    // Feature Line Buffer -> Conv Core
    logic        win_valid;
    logic        win_ready;
    logic [15:0] win_y, win_x;
    logic [7:0]  win_ic_grp;
    logic [1:0]  win_act2 [0:KH-1][0:KW-1][0:IC2_LANES-1];
    logic        linebuf_ready;
    logic        linebuf_done;
    
    // Weight Buffer <-> Controller
    logic [7:0]  req_oc_grp;
    logic [7:0]  req_ic_grp;
    logic        req_valid;
    logic        req_ready;
    logic        wgt_load_done;
    
    // Weight Buffer -> Conv Core
    logic [1:0]  wgt2 [0:OC2_LANES-1][0:KH-1][0:KW-1][0:IC2_LANES-1];
    logic        wgt_valid;
    logic        wgt_ready;
    
    // Conv Core -> Inter-cycle Accumulator -> Output Packer
    logic        core_out_valid;
    logic        core_out_ready;
    logic signed [ACC_W-1:0] partial [0:OC2_LANES-1];
    
    // Accumulator signals
    logic signed [ACC_W-1:0] acc_out_data;
    logic        acc_out_valid;
    logic        acc_out_ready;
    logic        acc_out_last;

    //========================================================================
    // DUT Instances
    //========================================================================
    
    // Feature Line Buffer
    feature_line_buffer #(
        .MAX_W(256),
        .MAX_H(256),
        .MAX_IC(256),
        .BUS_W(BUS_W),
        .IC2_LANES(IC2_LANES)
    ) u_linebuf (
        .clk(clk),
        .rst_n(rst_n),
        .cfg_W(cfg_W),
        .cfg_H(cfg_H),
        .cfg_IC(cfg_IC),
        .cfg_act_bits(cfg_act_bits),
        .cfg_stride(cfg_stride),
        .cfg_valid(cfg_valid),
        .cfg_ready(cfg_ready),
        .act_in_valid(act_in_valid),
        .act_in_ready(act_in_ready),
        .act_in_data(act_in_data),
        .act_in_last(act_in_last),
        .win_valid(win_valid),
        .win_ready(win_ready),
        .win_y(win_y),
        .win_x(win_x),
        .win_ic_grp(win_ic_grp),
        .win_act2(win_act2),
        .linebuf_ready(linebuf_ready),
        .layer_done(linebuf_done)
    );
    
    // Weight Buffer
    weight_buffer #(
        .MAX_IC(256),
        .MAX_OC(256),
        .BUS_W(BUS_W),
        .IC2_LANES(IC2_LANES),
        .OC2_LANES(OC2_LANES)
    ) u_weightbuf (
        .clk(clk),
        .rst_n(rst_n),
        .cfg_IC(cfg_IC),
        .cfg_OC(cfg_OC),
        .cfg_wgt_bits(cfg_wgt_bits),
        .cfg_valid(cfg_valid && cfg_ready),
        .cfg_ready(),
        .wgt_in_valid(wgt_in_valid),
        .wgt_in_ready(wgt_in_ready),
        .wgt_in_data(wgt_in_data),
        .wgt_in_last(wgt_in_last),
        .wgt_load_done(wgt_load_done),
        .req_oc_grp(req_oc_grp),
        .req_ic_grp(req_ic_grp),
        .req_valid(req_valid),
        .req_ready(req_ready),
        .wgt2(wgt2),
        .wgt_valid(wgt_valid),
        .wgt_ready(wgt_ready)
    );
    
    // Convolution Core
    conv_core_lowbit #(
        .IC2_LANES(IC2_LANES),
        .OC2_LANES(OC2_LANES),
        .KH(KH),
        .KW(KW),
        .ACC_W(ACC_W)
    ) u_convcore (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(win_valid && wgt_valid),
        .in_ready(win_ready),
        .act2(win_act2),
        .wgt2(wgt2),
        .act_bits(cfg_act_bits),
        .wgt_bits(cfg_wgt_bits),
        .out_valid(core_out_valid),
        .out_ready(core_out_ready),
        .partial(partial)
    );
    assign wgt_ready = win_ready;
    
    // Output Packer
    output_packer #(
        .ACC_W(ACC_W),
        .BUS_W(BUS_W)
    ) u_outpacker (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(acc_out_valid),
        .in_ready(acc_out_ready),
        .in_data(acc_out_data),
        .in_last(acc_out_last),
        .out_valid(out_valid),
        .out_ready(out_ready),
        .out_data(out_data),
        .out_last(out_last)
    );

    //========================================================================
    // Controller State Machine
    //========================================================================
    
    typedef enum logic [3:0] {
        ST_IDLE,
        ST_CONFIG,
        ST_LOAD_WGT,
        ST_WAIT_WGT_DONE,
        ST_PROCESS,
        ST_DRAIN_ACC,
        ST_DONE
    } state_t;
    
    state_t state, next_state;
    
    // Control registers
    logic [15:0] r_OH, r_OW;
    logic [7:0]  num_ic_grp, num_oc_grp;
    logic [7:0]  cur_oc_grp, cur_ic_grp;
    logic [15:0] cur_oy, cur_ox;
    logic [4:0]  r_act_slices, r_wgt_slices;
    logic [7:0]  r_OC_CH_PER_CYCLE;
    logic [7:0]  r_IC_CH_PER_CYCLE;
    
    // Accumulator
    logic signed [ACC_W-1:0] acc_reg [0:15];
    logic [4:0]  acc_cnt;
    logic        acc_busy;
    
    // Output counter
    logic [31:0] out_elem_cnt;
    logic [31:0] total_out_elems;
    
    // Calculate derived parameters
    function automatic logic [15:0] calc_out_dim(input logic [15:0] in_dim, input logic stride);
        if (in_dim < 16'd3)
            return 16'd0;
        else if (stride)
            return ((in_dim - 16'd3) >> 1) + 16'd1;
        else
            return (in_dim - 16'd3) + 16'd1;
    endfunction
    
    function automatic logic [2:0] calc_slices(input logic [4:0] bits);
        case (bits)
            5'd2:  return 3'd1;
            5'd4:  return 3'd2;
            5'd8:  return 3'd4;
            5'd16: return 3'd8;
            default: return 3'd1;
        endcase
    endfunction
    
    // State machine - sequential
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            cur_oy <= '0;
            cur_ox <= '0;
            cur_oc_grp <= '0;
            cur_ic_grp <= '0;
            acc_busy <= 1'b0;
            out_elem_cnt <= '0;
            done <= 1'b0;
            error_code <= '0;
        end else begin
            state <= next_state;
            done <= 1'b0;
            
            case (state)
                ST_IDLE: begin
                    if (start) begin
                        r_OH <= calc_out_dim(cfg_H, cfg_stride);
                        r_OW <= calc_out_dim(cfg_W, cfg_stride);
                        r_act_slices <= calc_slices(cfg_act_bits);
                        r_wgt_slices <= calc_slices(cfg_wgt_bits);
                        r_OC_CH_PER_CYCLE <= OC2_LANES / calc_slices(cfg_wgt_bits);
                        r_IC_CH_PER_CYCLE <= IC2_LANES / calc_slices(cfg_act_bits);
                        num_ic_grp <= cfg_IC[7:0] / (IC2_LANES[7:0] / {5'd0, calc_slices(cfg_act_bits)});
                        num_oc_grp <= cfg_OC[7:0] / (OC2_LANES[7:0] / {5'd0, calc_slices(cfg_wgt_bits)});
                        total_out_elems <= calc_out_dim(cfg_H, cfg_stride) * 
                                          calc_out_dim(cfg_W, cfg_stride) * cfg_OC;
                        cur_oy <= '0;
                        cur_ox <= '0;
                        cur_oc_grp <= '0;
                        cur_ic_grp <= '0;
                        out_elem_cnt <= '0;
                    end
                end
                
                ST_PROCESS: begin
                    if (core_out_valid && core_out_ready) begin
                        // Accumulate partial results
                        if (cur_ic_grp == 0) begin
                            // First IC group - initialize accumulator
                            for (int i = 0; i < 16; i++) begin
                                if (i < r_OC_CH_PER_CYCLE)
                                    acc_reg[i] <= partial[i];
                                else
                                    acc_reg[i] <= '0;
                            end
                        end else begin
                            // Accumulate
                            for (int i = 0; i < 16; i++) begin
                                if (i < r_OC_CH_PER_CYCLE)
                                    acc_reg[i] <= acc_reg[i] + partial[i];
                                else
                                    acc_reg[i] <= acc_reg[i];
                            end
                        end
                        
                        // Advance IC group
                        if (cur_ic_grp + 1 >= num_ic_grp) begin
                            cur_ic_grp <= '0;
                            acc_busy <= 1'b1;
                        end else begin
                            cur_ic_grp <= cur_ic_grp + 1'b1;
                        end
                    end
                    
                    // Send accumulated result to output packer
                    if (acc_busy && acc_out_ready) begin
                        acc_busy <= 1'b0;
                        out_elem_cnt <= out_elem_cnt + r_OC_CH_PER_CYCLE;
                        
                        // Advance OC group
                        if (cur_oc_grp + 1 >= num_oc_grp) begin
                            cur_oc_grp <= '0;
                            // Advance spatial position
                            if (cur_ox + 1 >= r_OW) begin
                                cur_ox <= '0;
                                if (cur_oy + 1 >= r_OH) begin
                                    cur_oy <= cur_oy;  // Done
                                end else begin
                                    cur_oy <= cur_oy + 1'b1;
                                end
                            end else begin
                                cur_ox <= cur_ox + 1'b1;
                            end
                        end else begin
                            cur_oc_grp <= cur_oc_grp + 1'b1;
                        end
                    end
                end
                
                ST_DONE: begin
                    done <= 1'b1;
                end
                
                default: ;
            endcase
        end
    end
    
    // State machine - combinational
    always_comb begin
        next_state = state;
        
        case (state)
            ST_IDLE: begin
                if (start) next_state = ST_CONFIG;
            end
            
            ST_CONFIG: begin
                if (cfg_valid && cfg_ready) next_state = ST_LOAD_WGT;
            end
            
            ST_LOAD_WGT: begin
                if (wgt_in_last && wgt_in_valid && wgt_in_ready) 
                    next_state = ST_WAIT_WGT_DONE;
            end
            
            ST_WAIT_WGT_DONE: begin
                if (wgt_load_done) next_state = ST_PROCESS;
            end
            
            ST_PROCESS: begin
                if (linebuf_done && !acc_busy && (out_elem_cnt >= total_out_elems))
                    next_state = ST_DRAIN_ACC;
            end
            
            ST_DRAIN_ACC: begin
                if (!acc_busy && acc_out_ready && (out_elem_cnt >= total_out_elems))
                    next_state = ST_DONE;
            end
            
            ST_DONE: begin
                next_state = ST_IDLE;
            end
            
            default: next_state = ST_IDLE;
        endcase
    end
    
    // Output to conv_core
    assign req_oc_grp = cur_oc_grp;
    assign req_ic_grp = cur_ic_grp;
    assign req_valid = (state == ST_PROCESS) && !acc_busy;
    assign win_ready = (state == ST_PROCESS) && req_ready && !acc_busy;
    assign core_out_ready = (state == ST_PROCESS) && !acc_busy;
    
    // Output from accumulator
    assign acc_out_valid = acc_busy;
    assign acc_out_data = acc_reg[acc_cnt];
    assign acc_out_last = (out_elem_cnt + r_OC_CH_PER_CYCLE >= total_out_elems) && 
                          (acc_cnt + 1 >= r_OC_CH_PER_CYCLE);
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_cnt <= '0;
        end else begin
            if (acc_out_valid && acc_out_ready) begin
                if (acc_cnt + 1 >= r_OC_CH_PER_CYCLE)
                    acc_cnt <= '0;
                else
                    acc_cnt <= acc_cnt + 1'b1;
            end
        end
    end

    //========================================================================
    // Golden Model Functions
    //========================================================================
    
    // decode2: 2-bit code -> signed int
    function automatic int decode2(input logic [1:0] code);
        case (code)
            2'b00: decode2 = -3;
            2'b01: decode2 = -1;
            2'b10: decode2 = 1;
            2'b11: decode2 = 3;
        endcase
    endfunction
    
    // Encode signed int -> 2-bit code (for test data generation)
    function automatic logic [1:0] encode2(input int val);
        case (val)
            -3: encode2 = 2'b00;
            -1: encode2 = 2'b01;
            1:  encode2 = 2'b10;
            3:  encode2 = 2'b11;
            default: encode2 = 2'b00;
        endcase
    endfunction
    
    // Reconstruct N-bit value from 2-bit slices
    function automatic int reconstruct_val(input logic [15:0] val, input int num_slices);
        int result = 0;
        for (int s = 0; s < num_slices; s++) begin
            logic [1:0] slice;
            slice = val[s*2 +: 2];
            result += decode2(slice) * (1 << (2*s));
        end
        reconstruct_val = result;
    endfunction
    
    // Compute golden reference for convolution
    task automatic compute_golden_ref(
        input int H, W, IC, OC, stride, act_bits, wgt_bits,
        input int act_arr[],  // [H][W][IC]
        input int wgt_arr[],  // [KH][KW][OC][IC]
        output int out_arr[]  // [OH][OW][OC]
    );
        int OH, OW;
        int act_val, wgt_val;
        int sum;
        
        OH = (H - 3) / (stride == 0 ? 1 : 2) + 1;
        OW = (W - 3) / (stride == 0 ? 1 : 2) + 1;
        
        $display("[Golden] Computing: H=%0d W=%0d IC=%0d OC=%0d stride=%0d -> OH=%0d OW=%0d", 
                 H, W, IC, OC, stride, OH, OW);
        
        for (int oy = 0; oy < OH; oy++) begin
            for (int ox = 0; ox < OW; ox++) begin
                for (int oc = 0; oc < OC; oc++) begin
                    sum = 0;
                    for (int ic = 0; ic < IC; ic++) begin
                        for (int kh = 0; kh < 3; kh++) begin
                            for (int kw = 0; kw < 3; kw++) begin
                                int iy = oy * (stride == 0 ? 1 : 2) + kh;
                                int ix = ox * (stride == 0 ? 1 : 2) + kw;
                                int act_idx = ((iy * W) + ix) * IC + ic;
                                int wgt_idx = ((kh * 3 + kw) * OC + oc) * IC + ic;
                                
                                act_val = act_arr[act_idx];
                                wgt_val = wgt_arr[wgt_idx];
                                
                                sum += act_val * wgt_val;
                            end
                        end
                    end
                    // Apply >> 1 (right shift by 1) as per MVP spec
                    out_arr[(oy * OW + ox) * OC + oc] = sum >>> 1;
                end
            end
        end
    endtask

    //========================================================================
    // Utility Tasks
    //========================================================================
    
    // Reset DUT
    task automatic reset_dut();
        rst_n = 0;
        cfg_valid = 0;
        start = 0;
        wgt_in_valid = 0;
        wgt_in_data = 0;
        wgt_in_last = 0;
        act_in_valid = 0;
        act_in_data = 0;
        act_in_last = 0;
        out_ready = 0;
        
        repeat(5) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);
    endtask
    
    // Send configuration
    task automatic send_cfg(
        input int w, h, ic, oc, stride, act_bits, wgt_bits
    );
        cfg_W = w[15:0];
        cfg_H = h[15:0];
        cfg_IC = ic[15:0];
        cfg_OC = oc[15:0];
        cfg_stride = stride[0];
        cfg_act_bits = act_bits[4:0];
        cfg_wgt_bits = wgt_bits[4:0];
        cfg_valid = 1;
        
        @(posedge clk);
        while (!cfg_ready) @(posedge clk);
        cfg_valid = 0;
        
        $display("[TB] Config sent: W=%0d H=%0d IC=%0d OC=%0d stride=%0d act_bits=%0d wgt_bits=%0d",
                 w, h, ic, oc, stride, act_bits, wgt_bits);
    endtask
    
    // Pack int array into bitstream according to bitwidth
    // Using task instead of function for output array compatibility
    task automatic pack_data(
        input int data[],
        input int num_elems,
        input int bits_per_elem,
        output logic [BUS_W-1:0] beats[$]
    );
        logic [BUS_W-1:0] current_beat;
        int bit_pos;
        int elems_per_beat;
        
        elems_per_beat = BUS_W / bits_per_elem;
        current_beat = 0;
        bit_pos = 0;
        beats = {};
        
        for (int i = 0; i < num_elems; i++) begin
            // Pack element at current position
            for (int b = 0; b < bits_per_elem; b++) begin
                current_beat[bit_pos + b] = data[i][b];
            end
            bit_pos += bits_per_elem;
            
            // Beat is full
            if (bit_pos >= BUS_W) begin
                beats.push_back(current_beat);
                current_beat = 0;
                bit_pos = 0;
            end
        end
        
        // Push final partial beat if any
        if (bit_pos > 0 || num_elems == 0) begin
            beats.push_back(current_beat);
        end
    endtask
    
    // Send weight stream
    task automatic send_weight_stream(
        input int wgt_arr[],
        input int num_elements,
        input int wgt_bits
    );
        logic [BUS_W-1:0] beats[$];
        
        pack_data(wgt_arr, num_elements, wgt_bits, beats);
        
        $display("[TB] Sending %0d weights in %0d beats (bits=%0d)", 
                 num_elements, beats.size(), wgt_bits);
        
        for (int i = 0; i < beats.size(); i++) begin
            wgt_in_valid = 1;
            wgt_in_data = beats[i];
            wgt_in_last = (i == beats.size() - 1);
            
            @(posedge clk);
            while (!wgt_in_ready) @(posedge clk);
        end
        wgt_in_valid = 0;
        wgt_in_last = 0;
        
        // Wait for load done
        while (!wgt_load_done) @(posedge clk);
        $display("[TB] Weight loading complete");
    endtask
    
    // Send activation stream
    task automatic send_act_stream(
        input int act_arr[],
        input int num_elements,
        input int act_bits
    );
        logic [BUS_W-1:0] beats[$];
        
        pack_data(act_arr, num_elements, act_bits, beats);
        
        $display("[TB] Sending %0d activations in %0d beats (bits=%0d)", 
                 num_elements, beats.size(), act_bits);
        
        for (int i = 0; i < beats.size(); i++) begin
            act_in_valid = 1;
            act_in_data = beats[i];
            act_in_last = (i == beats.size() - 1);
            
            @(posedge clk);
            while (!act_in_ready) @(posedge clk);
        end
        act_in_valid = 0;
        act_in_last = 0;
        
        $display("[TB] Activation streaming complete");
    endtask
    
    // Receive output
    task automatic receive_output(
        output int out_arr[],
        input int num_elements
    );
        int elem_cnt;
        int beat_cnt;
        logic [ACC_W-1:0] received_data[$];
        
        elem_cnt = 0;
        beat_cnt = 0;
        received_data = {};
        out_ready = 1;
        
        $display("[TB] Receiving %0d output elements...", num_elements);
        
        while (elem_cnt < num_elements) begin
            @(posedge clk);
            
            if (out_valid && out_ready) begin
                // Unpack beat
                for (int i = 0; i < BUS_W/ACC_W; i++) begin
                    if (elem_cnt < num_elements) begin
                        logic [ACC_W-1:0] elem;
                        elem = out_data[i*ACC_W +: ACC_W];
                        received_data.push_back(elem);
                        out_arr[elem_cnt] = elem;
                        elem_cnt++;
                    end
                end
                beat_cnt++;
                
                if (out_last) begin
                    $display("[TB] Received out_last at beat %0d", beat_cnt);
                end
            end
        end
        
        out_ready = 0;
        $display("[TB] Received %0d elements in %0d beats", elem_cnt, beat_cnt);
    endtask
    
    // Receive output with backpressure
    task automatic receive_output_backpressure(
        output int out_arr[],
        input int num_elements,
        input int ready_high_cycles,
        input int ready_low_cycles
    );
        int elem_cnt;
        int cycle_cnt;
        
        elem_cnt = 0;
        cycle_cnt = 0;
        out_ready = 0;
        
        $display("[TB] Receiving %0d output elements with backpressure (high=%0d, low=%0d)...", 
                 num_elements, ready_high_cycles, ready_low_cycles);
        
        while (elem_cnt < num_elements) begin
            // Toggle ready based on pattern
            if (cycle_cnt % (ready_high_cycles + ready_low_cycles) < ready_high_cycles)
                out_ready = 1;
            else
                out_ready = 0;
            
            @(posedge clk);
            cycle_cnt++;
            
            if (out_valid && out_ready) begin
                // Unpack beat
                for (int i = 0; i < BUS_W/ACC_W; i++) begin
                    if (elem_cnt < num_elements) begin
                        logic [ACC_W-1:0] elem;
                        elem = out_data[i*ACC_W +: ACC_W];
                        out_arr[elem_cnt] = elem;
                        elem_cnt++;
                    end
                end
            end
        end
        
        out_ready = 0;
        $display("[TB] Backpressure receive complete. Total cycles: %0d", cycle_cnt);
    endtask
    
    // Check output against golden
    task automatic check_output(
        input int dut_out[],
        input int golden[],
        input int num_elements,
        output int error_cnt
    );
        error_cnt = 0;
        
        for (int i = 0; i < num_elements; i++) begin
            if (dut_out[i] !== golden[i]) begin
                if (error_cnt < 10) begin  // Limit error messages
                    $display("[ERROR] Mismatch at idx %0d: DUT=%0d (0x%h), Golden=%0d (0x%h)",
                             i, dut_out[i], dut_out[i], golden[i], golden[i]);
                end
                error_cnt++;
            end
        end
        
        if (error_cnt == 0) begin
            $display("[PASS] All %0d elements match!", num_elements);
        end else begin
            $display("[FAIL] %0d mismatches out of %0d elements", error_cnt, num_elements);
        end
    endtask

    //========================================================================
    // Test Data Generation
    //========================================================================
    
    // Generate random 2-bit activation data
    task automatic gen_random_act_2bit(
        output int act_arr[],
        input int H, W, IC
    );
        int num_elems = H * W * IC;
        act_arr = new[num_elems];
        for (int i = 0; i < num_elems; i++) begin
            // Random value: -3, -1, 1, 3
            int r = $urandom_range(0, 3);
            case (r)
                0: act_arr[i] = -3;
                1: act_arr[i] = -1;
                2: act_arr[i] = 1;
                3: act_arr[i] = 3;
            endcase
        end
    endtask
    
    // Generate random 2-bit weight data
    task automatic gen_random_wgt_2bit(
        output int wgt_arr[],
        input int OC, IC
    );
        int num_elems = 9 * OC * IC;
        wgt_arr = new[num_elems];
        for (int i = 0; i < num_elems; i++) begin
            int r = $urandom_range(0, 3);
            case (r)
                0: wgt_arr[i] = -3;
                1: wgt_arr[i] = -1;
                2: wgt_arr[i] = 1;
                3: wgt_arr[i] = 3;
            endcase
        end
    endtask
    
    // Generate random N-bit data (N=4,8,16)
    task automatic gen_random_data_nbit(
        output int arr[],
        input int num_elems,
        input int bits
    );
        int max_val;
        arr = new[num_elems];
        max_val = (1 << bits) - 1;
        for (int i = 0; i < num_elems; i++) begin
            // Generate signed values in valid range based on encoding
            // For 4-bit: decode2 range is -3 to +3, shifted by 2*s
            // Max value when all slices are 3: sum(3 * 4^s)
            // Simplification: just use -3,-1,1,3 for each slice
            int val = 0;
            int num_slices = bits / 2;
            for (int s = 0; s < num_slices; s++) begin
                int r = $urandom_range(0, 3);
                int slice_val;
                case (r)
                    0: slice_val = -3;
                    1: slice_val = -1;
                    2: slice_val = 1;
                    3: slice_val = 3;
                endcase
                val += slice_val * (1 << (2*s));
            end
            arr[i] = val;
        end
    endtask

    //========================================================================
    // Test Cases
    //========================================================================
    
    int test_passed;
    int test_failed;
    int total_tests;
    
    // TEST 1: Basic 2-bit test, stride=1
    task automatic test_1_basic_2bit_stride1();
        int H=8, W=8, IC=16, OC=16;
        int act_bits=2, wgt_bits=2, stride=0;
        int act_arr[];
        int wgt_arr[];
        int dut_out[];
        int golden[];
        int OH, OW;
        int num_act, num_wgt, num_out;
        int error_cnt;
        
        $display("\n========================================");
        $display("TEST 1: Basic 2-bit, stride=1, IC=16, OC=16");
        $display("========================================");
        
        OH = (H - 3) + 1;
        OW = (W - 3) + 1;
        num_act = H * W * IC;
        num_wgt = 9 * OC * IC;
        num_out = OH * OW * OC;
        
        dut_out = new[num_out];
        golden = new[num_out];
        
        // Generate test data
        gen_random_act_2bit(act_arr, H, W, IC);
        gen_random_wgt_2bit(wgt_arr, OC, IC);
        
        // Compute golden
        compute_golden_ref(H, W, IC, OC, stride, act_bits, wgt_bits, act_arr, wgt_arr, golden);
        
        // Reset and configure
        reset_dut();
        send_cfg(W, H, IC, OC, stride, act_bits, wgt_bits);
        
        // Load weights
        send_weight_stream(wgt_arr, num_wgt, wgt_bits);
        
        // Start processing
        start = 1;
        @(posedge clk);
        start = 0;
        
        // Send activations (in parallel with processing)
        fork
            send_act_stream(act_arr, num_act, act_bits);
        join_none
        
        // Receive output
        receive_output(dut_out, num_out);
        
        // Wait for done
        while (!done) @(posedge clk);
        repeat(5) @(posedge clk);
        
        // Check results
        check_output(dut_out, golden, num_out, error_cnt);
        
        if (error_cnt == 0) test_passed++;
        else test_failed++;
        total_tests++;
    endtask
    
    // TEST 2: Basic 2-bit test, stride=2
    task automatic test_2_basic_2bit_stride2();
        int H=8, W=8, IC=16, OC=16;
        int act_bits=2, wgt_bits=2, stride=1;  // stride=1 means stride=2 in hardware
        int act_arr[];
        int wgt_arr[];
        int dut_out[];
        int golden[];
        int OH, OW;
        int num_act, num_wgt, num_out;
        int error_cnt;
        
        $display("\n========================================");
        $display("TEST 2: Basic 2-bit, stride=2, IC=16, OC=16");
        $display("========================================");
        
        OH = ((H - 3) >> 1) + 1;
        OW = ((W - 3) >> 1) + 1;
        num_act = H * W * IC;
        num_wgt = 9 * OC * IC;
        num_out = OH * OW * OC;
        
        dut_out = new[num_out];
        golden = new[num_out];
        
        gen_random_act_2bit(act_arr, H, W, IC);
        gen_random_wgt_2bit(wgt_arr, OC, IC);
        
        compute_golden_ref(H, W, IC, OC, stride, act_bits, wgt_bits, act_arr, wgt_arr, golden);
        
        reset_dut();
        send_cfg(W, H, IC, OC, stride, act_bits, wgt_bits);
        send_weight_stream(wgt_arr, num_wgt, wgt_bits);
        
        start = 1;
        @(posedge clk);
        start = 0;
        
        fork
            send_act_stream(act_arr, num_act, act_bits);
        join_none
        
        receive_output(dut_out, num_out);
        
        while (!done) @(posedge clk);
        repeat(5) @(posedge clk);
        
        check_output(dut_out, golden, num_out, error_cnt);
        
        if (error_cnt == 0) test_passed++;
        else test_failed++;
        total_tests++;
    endtask
    
    // TEST 3: 4-bit activation, 2-bit weight
    task automatic test_3_act4_wgt2();
        int H=8, W=8, IC=32, OC=16;
        int act_bits=4, wgt_bits=2, stride=0;
        int act_arr[];
        int wgt_arr[];
        int dut_out[];
        int golden[];
        int OH, OW;
        int num_act, num_wgt, num_out;
        int error_cnt;
        
        $display("\n========================================");
        $display("TEST 3: act_bits=4, wgt_bits=2, IC=32, OC=16");
        $display("========================================");
        
        OH = (H - 3) + 1;
        OW = (W - 3) + 1;
        num_act = H * W * IC;
        num_wgt = 9 * OC * IC;
        num_out = OH * OW * OC;
        
        dut_out = new[num_out];
        golden = new[num_out];
        
        gen_random_data_nbit(act_arr, num_act, act_bits);
        gen_random_wgt_2bit(wgt_arr, OC, IC);
        
        compute_golden_ref(H, W, IC, OC, stride, act_bits, wgt_bits, act_arr, wgt_arr, golden);
        
        reset_dut();
        send_cfg(W, H, IC, OC, stride, act_bits, wgt_bits);
        send_weight_stream(wgt_arr, num_wgt, wgt_bits);
        
        start = 1;
        @(posedge clk);
        start = 0;
        
        fork
            send_act_stream(act_arr, num_act, act_bits);
        join_none
        
        receive_output(dut_out, num_out);
        
        while (!done) @(posedge clk);
        repeat(5) @(posedge clk);
        
        check_output(dut_out, golden, num_out, error_cnt);
        
        if (error_cnt == 0) test_passed++;
        else test_failed++;
        total_tests++;
    endtask
    
    // TEST 4: 2-bit activation, 4-bit weight
    task automatic test_4_act2_wgt4();
        int H=8, W=8, IC=16, OC=32;
        int act_bits=2, wgt_bits=4, stride=0;
        int act_arr[];
        int wgt_arr[];
        int dut_out[];
        int golden[];
        int OH, OW;
        int num_act, num_wgt, num_out;
        int error_cnt;
        
        $display("\n========================================");
        $display("TEST 4: act_bits=2, wgt_bits=4, IC=16, OC=32");
        $display("========================================");
        
        OH = (H - 3) + 1;
        OW = (W - 3) + 1;
        num_act = H * W * IC;
        num_wgt = 9 * OC * IC;
        num_out = OH * OW * OC;
        
        dut_out = new[num_out];
        golden = new[num_out];
        
        gen_random_act_2bit(act_arr, H, W, IC);
        gen_random_data_nbit(wgt_arr, num_wgt, wgt_bits);
        
        compute_golden_ref(H, W, IC, OC, stride, act_bits, wgt_bits, act_arr, wgt_arr, golden);
        
        reset_dut();
        send_cfg(W, H, IC, OC, stride, act_bits, wgt_bits);
        send_weight_stream(wgt_arr, num_wgt, wgt_bits);
        
        start = 1;
        @(posedge clk);
        start = 0;
        
        fork
            send_act_stream(act_arr, num_act, act_bits);
        join_none
        
        receive_output(dut_out, num_out);
        
        while (!done) @(posedge clk);
        repeat(5) @(posedge clk);
        
        check_output(dut_out, golden, num_out, error_cnt);
        
        if (error_cnt == 0) test_passed++;
        else test_failed++;
        total_tests++;
    endtask
    
    // TEST 5: Large IC/OC (multiple groups)
    task automatic test_5_large_ic_oc();
        int H=16, W=16, IC=64, OC=64;
        int act_bits=2, wgt_bits=2, stride=0;
        int act_arr[];
        int wgt_arr[];
        int dut_out[];
        int golden[];
        int OH, OW;
        int num_act, num_wgt, num_out;
        int error_cnt;
        
        $display("\n========================================");
        $display("TEST 5: Large IC=64, OC=64, W=16, H=16");
        $display("========================================");
        
        OH = (H - 3) + 1;
        OW = (W - 3) + 1;
        num_act = H * W * IC;
        num_wgt = 9 * OC * IC;
        num_out = OH * OW * OC;
        
        dut_out = new[num_out];
        golden = new[num_out];
        
        gen_random_act_2bit(act_arr, H, W, IC);
        gen_random_wgt_2bit(wgt_arr, OC, IC);
        
        compute_golden_ref(H, W, IC, OC, stride, act_bits, wgt_bits, act_arr, wgt_arr, golden);
        
        reset_dut();
        send_cfg(W, H, IC, OC, stride, act_bits, wgt_bits);
        send_weight_stream(wgt_arr, num_wgt, wgt_bits);
        
        start = 1;
        @(posedge clk);
        start = 0;
        
        fork
            send_act_stream(act_arr, num_act, act_bits);
        join_none
        
        receive_output(dut_out, num_out);
        
        while (!done) @(posedge clk);
        repeat(5) @(posedge clk);
        
        check_output(dut_out, golden, num_out, error_cnt);
        
        if (error_cnt == 0) test_passed++;
        else test_failed++;
        total_tests++;
    endtask
    
    // TEST 6: Backpressure test
    task automatic test_6_backpressure();
        int H=8, W=8, IC=16, OC=16;
        int act_bits=2, wgt_bits=2, stride=0;
        int act_arr[];
        int wgt_arr[];
        int dut_out[];
        int golden[];
        int OH, OW;
        int num_act, num_wgt, num_out;
        int error_cnt;
        
        $display("\n========================================");
        $display("TEST 6: Backpressure test (ready toggles)");
        $display("========================================");
        
        OH = (H - 3) + 1;
        OW = (W - 3) + 1;
        num_act = H * W * IC;
        num_wgt = 9 * OC * IC;
        num_out = OH * OW * OC;
        
        dut_out = new[num_out];
        golden = new[num_out];
        
        gen_random_act_2bit(act_arr, H, W, IC);
        gen_random_wgt_2bit(wgt_arr, OC, IC);
        
        compute_golden_ref(H, W, IC, OC, stride, act_bits, wgt_bits, act_arr, wgt_arr, golden);
        
        reset_dut();
        send_cfg(W, H, IC, OC, stride, act_bits, wgt_bits);
        send_weight_stream(wgt_arr, num_wgt, wgt_bits);
        
        start = 1;
        @(posedge clk);
        start = 0;
        
        fork
            send_act_stream(act_arr, num_act, act_bits);
        join_none
        
        // Receive with backpressure
        receive_output_backpressure(dut_out, num_out, 2, 3);  // 2 high, 3 low cycles
        
        while (!done) @(posedge clk);
        repeat(5) @(posedge clk);
        
        check_output(dut_out, golden, num_out, error_cnt);
        
        if (error_cnt == 0) test_passed++;
        else test_failed++;
        total_tests++;
    endtask

    //========================================================================
    // Main Test Sequence
    //========================================================================
    
    initial begin
        $display("========================================");
        $display("Conv3x3 Low-bit Accelerator Testbench");
        $display("========================================");
        
        test_passed = 0;
        test_failed = 0;
        total_tests = 0;
        
        // Run all tests
        test_1_basic_2bit_stride1();
        test_2_basic_2bit_stride2();
        test_3_act4_wgt2();
        test_4_act2_wgt4();
        test_5_large_ic_oc();
        test_6_backpressure();
        
        // Final report
        $display("\n========================================");
        $display("Test Summary");
        $display("========================================");
        $display("Total Tests: %0d", total_tests);
        $display("Passed: %0d", test_passed);
        $display("Failed: %0d", test_failed);
        
        if (test_failed == 0) begin
            $display("\n*** ALL TESTS PASSED ***");
        end else begin
            $display("\n*** SOME TESTS FAILED ***");
        end
        
        $display("========================================");
        
        $finish;
    end
    
    // Timeout watchdog
    initial begin
        #10000000;  // 10ms timeout
        $error("[TIMEOUT] Simulation timeout!");
        $finish;
    end
    
    // Waveform dump (for VCS/Verilator)
    initial begin
        $dumpfile("tb_conv3x3_accel.vcd");
        $dumpvars(0, tb_conv3x3_accel);
    end

endmodule
