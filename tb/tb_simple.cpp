// Simple smoke test for Verilator
#include <verilated.h>
#include "Vconv3x3_accel_top.h"

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    
    printf("========================================\n");
    printf(" Conv3x3 Accelerator Smoke Test\n");
    printf("========================================\n");
    
    Vconv3x3_accel_top* top = new Vconv3x3_accel_top;
    
    // Reset
    top->rst_n = 0;
    top->clk = 0;
    
    // Toggle clock a few times
    for (int i = 0; i < 10; i++) {
        top->clk = !top->clk;
        top->eval();
    }
    
    top->rst_n = 1;
    top->eval();
    
    printf("✅ Design compiled and reset successfully!\n");
    printf("========================================\n");
    
    delete top;
    return 0;
}
