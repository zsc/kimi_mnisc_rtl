//=============================================================================
// tb_top.cpp - Verilator testbench for conv3x3_accel_top
//=============================================================================

#include <verilated.h>
#include <verilated_vcd_c.h>
#include "Vconv3x3_accel_top.h"
#include <cstdio>
#include <cstdlib>
#include <ctime>

vluint64_t main_time = 0;

double sc_time_stamp() {
    return main_time;
}

// decode2 function from AGENTS.md
int decode2(int code) {
    switch (code & 0x3) {
        case 0: return -3;
        case 1: return -1;
        case 2: return 1;
        case 3: return 3;
    }
    return 0;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);
    
    Vconv3x3_accel_top* top = new Vconv3x3_accel_top;
    
    // Enable tracing
    VerilatedVcdC* tfp = new VerilatedVcdC;
    top->trace(tfp, 99);
    tfp->open("waveform.vcd");
    
    printf("========================================\n");
    printf(" Conv3x3 Accelerator Top-Level Test\n");
    printf("========================================\n");
    
    // Reset
    top->rst_n = 0;
    top->clk = 0;
    
    // Initialize inputs
    top->cfg_valid = 0;
    top->cfg_W = 0;
    top->cfg_H = 0;
    top->cfg_IC = 0;
    top->cfg_OC = 0;
    top->cfg_stride = 0;
    top->cfg_act_bits = 0;
    top->cfg_wgt_bits = 0;
    top->cfg_mode_raw_out = 0;
    top->start = 0;
    top->wgt_in_valid = 0;
    top->wgt_in_last = 0;
    top->act_in_valid = 0;
    top->act_in_last = 0;
    top->out_ready = 1;
    
    // Initialize wide data signals
    for (int i = 0; i < 4; i++) {
        top->wgt_in_data[i] = 0;
        top->act_in_data[i] = 0;
    }
    
    // Run reset for 10 cycles
    for (int i = 0; i < 20; i++) {
        top->clk = !top->clk;
        top->eval();
        tfp->dump(main_time);
        main_time++;
    }
    top->rst_n = 1;
    printf("Reset complete\n");
    
    // Test configuration
    int W = 8, H = 8, IC = 16, OC = 16;
    int stride = 0;  // stride=1
    int act_bits = 2, wgt_bits = 2;
    int OH = (H - 3) / (stride + 1) + 1;
    int OW = (W - 3) / (stride + 1) + 1;
    
    printf("Test config: W=%d H=%d IC=%d OC=%d stride=%d act_bits=%d wgt_bits=%d\n",
           W, H, IC, OC, stride + 1, act_bits, wgt_bits);
    printf("Output size: OH=%d OW=%d\n", OH, OW);
    
    // Send configuration
    top->cfg_valid = 1;
    top->cfg_W = W;
    top->cfg_H = H;
    top->cfg_IC = IC;
    top->cfg_OC = OC;
    top->cfg_stride = stride;
    top->cfg_act_bits = act_bits;
    top->cfg_wgt_bits = wgt_bits;
    top->cfg_mode_raw_out = 1;
    
    while (!top->cfg_ready) {
        top->clk = !top->clk;
        top->eval();
        tfp->dump(main_time);
        main_time++;
    }
    
    top->cfg_valid = 0;
    top->start = 1;
    top->clk = !top->clk;
    top->eval();
    tfp->dump(main_time);
    main_time++;
    top->start = 0;
    
    printf("Configuration sent, start asserted\n");
    
    // Generate and send weights
    int wgt_elements = OC * IC * 9;
    int wgt_beats = (wgt_elements * wgt_bits + 127) / 128;
    printf("Sending %d weights in %d beats...\n", wgt_elements, wgt_beats);
    
    srand(time(NULL));
    int wgt_sent = 0;
    int beat_count = 0;
    
    while (wgt_sent < wgt_elements) {
        if (top->wgt_in_ready) {
            top->wgt_in_valid = 1;
            // Pack 2-bit weights into 128-bit beat (4 x 32-bit words)
            for (int i = 0; i < 4; i++) {
                unsigned int word = 0;
                for (int j = 0; j < 16 && wgt_sent < wgt_elements; j++) {
                    int w = rand() & 0x3;  // Random 2-bit weight
                    word |= (w << (j * 2));
                    wgt_sent++;
                }
                top->wgt_in_data[i] = word;
            }
            top->wgt_in_last = (wgt_sent >= wgt_elements) ? 1 : 0;
            beat_count++;
        }
        
        top->clk = !top->clk;
        top->eval();
        tfp->dump(main_time);
        main_time++;
        
        if (top->wgt_in_ready && top->wgt_in_valid) {
            top->wgt_in_valid = 0;
        }
    }
    top->wgt_in_valid = 0;
    printf("Weights sent: %d elements in %d beats\n", wgt_sent, beat_count);
    
    // Generate and send activations
    int act_elements = H * W * IC;
    int act_beats = (act_elements * act_bits + 127) / 128;
    printf("Sending %d activations in %d beats...\n", act_elements, act_beats);
    
    int act_sent = 0;
    beat_count = 0;
    
    while (act_sent < act_elements) {
        if (top->act_in_ready) {
            top->act_in_valid = 1;
            for (int i = 0; i < 4; i++) {
                unsigned int word = 0;
                for (int j = 0; j < 16 && act_sent < act_elements; j++) {
                    int a = rand() & 0x3;  // Random 2-bit activation
                    word |= (a << (j * 2));
                    act_sent++;
                }
                top->act_in_data[i] = word;
            }
            top->act_in_last = (act_sent >= act_elements) ? 1 : 0;
            beat_count++;
        }
        
        top->clk = !top->clk;
        top->eval();
        tfp->dump(main_time);
        main_time++;
        
        if (top->act_in_ready && top->act_in_valid) {
            top->act_in_valid = 0;
        }
    }
    top->act_in_valid = 0;
    printf("Activations sent: %d elements in %d beats\n", act_sent, beat_count);
    
    // Wait for computation and output
    printf("Waiting for computation and output...\n");
    
    int out_received = 0;
    int out_elements = OH * OW * OC;
    int max_cycles = 100000;
    int cycles = 0;
    
    while (cycles < max_cycles && out_received < out_elements) {
        top->clk = !top->clk;
        top->eval();
        tfp->dump(main_time);
        main_time++;
        cycles++;
        
        if (top->out_valid && top->out_ready) {
            // Each beat has 4 x 32-bit outputs
            out_received += 4;
            if (top->out_last) {
                printf("Output last beat received\n");
                break;
            }
        }
        
        if (top->done) {
            printf("Done signal received after %d cycles\n", cycles);
            break;
        }
    }
    
    printf("Output received: %d elements\n", out_received);
    printf("Total simulation cycles: %d\n", cycles);
    
    // Check error code
    if (top->error_code != 0) {
        printf("❌ ERROR: error_code = %d\n", top->error_code);
    } else {
        printf("✅ No error detected\n");
    }
    
    printf("========================================\n");
    printf(" Simulation Complete\n");
    printf("========================================\n");
    
    tfp->close();
    delete tfp;
    delete top;
    
    return 0;
}
