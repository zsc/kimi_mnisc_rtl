//=============================================================================
// Module: output_packer
// Description: Pack ACC_W signed results into BUS_W beats for stream output
//              Follows output layout (oy, ox, oc) with oc innermost
//
// Based on AGENTS.md §6.4
//=============================================================================

module output_packer #(
    parameter int ACC_W = 32,           // Accumulator bit width
    parameter int BUS_W = 128           // Output bus bit width
) (
    // Clock and reset
    input  logic        clk,
    input  logic        rst_n,

    // Input from conv_core / inter-cycle accumulator
    input  logic                        in_valid,
    output logic                        in_ready,
    input  logic signed [ACC_W-1:0]     in_data,        // Single element
    input  logic                        in_last,        // Last element of layer

    // Output to external stream
    output logic                        out_valid,
    input  logic                        out_ready,
    output logic [BUS_W-1:0]            out_data,
    output logic                        out_last
);

    //=============================================================================
    // Local parameters
    //=============================================================================
    localparam int ELEM_PER_BEAT = BUS_W / ACC_W;   // Elements per output beat
    localparam int CNT_W = $clog2(ELEM_PER_BEAT);   // Counter bit width

    //=============================================================================
    // Internal signals
    //=============================================================================
    // Packing buffer: holds elements until a full beat is formed
    logic [ACC_W-1:0] pack_buf [0:ELEM_PER_BEAT-1];
    
    // Element counter: how many elements currently in buffer
    logic [CNT_W-1:0] elem_cnt;
    
    // Flag indicating this is the final beat (in_last was received)
    logic             is_last_beat;
    
    // Internal state
    logic             buf_full;     // Buffer is full (ready to output)
    logic             flushing;     // In flush mode (sending final partial beat)

    //=============================================================================
    // Buffer full detection
    //=============================================================================
    assign buf_full = (elem_cnt == ELEM_PER_BEAT[CNT_W-1:0]);

    //=============================================================================
    // Input ready generation
    // Accept input when:
    // 1. Buffer is not full, OR
    // 2. Buffer is full but output is being accepted this cycle (out_valid & out_ready)
    // However, we need to be careful about backpressure during flushing
    //=============================================================================
    assign in_ready = !flushing && (!buf_full || (out_valid && out_ready));

    //=============================================================================
    // Output data construction (combinational)
    // Pack buffer elements into BUS_W output with little-endian ordering:
    // pack_buf[0] -> out_data[ACC_W-1:0] (lowest address)
    // pack_buf[1] -> out_data[2*ACC_W-1:ACC_W]
    // ...
    // pack_buf[ELEM_PER_BEAT-1] -> out_data[BUS_W-1:BUS_W-ACC_W] (highest address)
    //=============================================================================
    always_comb begin
        out_data = '0;  // Default to 0 (handles padding for final partial beat)
        for (int i = 0; i < ELEM_PER_BEAT; i++) begin
            out_data[i*ACC_W +: ACC_W] = pack_buf[i];
        end
    end

    //=============================================================================
    // Output valid and last generation
    //=============================================================================
    // Output is valid when:
    // 1. Buffer is full (normal operation), OR
    // 2. We're flushing the final partial beat
    assign out_valid = buf_full || flushing;
    
    // out_last is asserted on the final beat:
    // 1. Normal case: buffer full and this is the last beat
    // 2. Flush case: in the middle of flushing
    assign out_last = (buf_full && is_last_beat) || (flushing && is_last_beat);

    //=============================================================================
    // Sequential logic: buffer management
    //=============================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            elem_cnt <= '0;
            is_last_beat <= 1'b0;
            flushing <= 1'b0;
            for (int i = 0; i < ELEM_PER_BEAT; i++) begin
                pack_buf[i] <= '0;
            end
        end else begin
            // Handle output acceptance
            if (out_valid && out_ready) begin
                // Beat was accepted - clear buffer
                elem_cnt <= '0;
                if (flushing) begin
                    // Finished flushing, go back to normal
                    flushing <= 1'b0;
                    is_last_beat <= 1'b0;
                end
            end

            // Handle input acceptance
            if (in_valid && in_ready) begin
                // Store incoming data to current buffer position
                pack_buf[elem_cnt] <= $unsigned(in_data);
                
                // Increment counter
                elem_cnt <= elem_cnt + 1'b1;
                
                // Check if this is the last element
                if (in_last) begin
                    is_last_beat <= 1'b1;
                    // If buffer won't be full after this element, need to flush
                    if (elem_cnt != ELEM_PER_BEAT[CNT_W-1:0] - 1'b1) begin
                        flushing <= 1'b1;
                    end
                end
            end
        end
    end

    //=============================================================================
    // Assertions (for simulation/debugging)
    //=============================================================================
    `ifdef SIMULATION
        always @(posedge clk) begin
            if (rst_n) begin
                // Check that in_last is only asserted with valid data
                if (in_last && !in_valid)
                    $error("in_last asserted without in_valid");
                
                // Check that element count never exceeds capacity
                if (elem_cnt > ELEM_PER_BEAT)
                    $error("elem_cnt overflow");
                
                // Check that flushing state is consistent with is_last_beat
                if (flushing && !is_last_beat)
                    $error("flushing without is_last_beat");
            end
        end
    `endif

endmodule
