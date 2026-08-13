//==============================================================================
// Simulation Main for CORDIC Accelerator
// Verilator C++ test harness - drives SystemVerilog testbench
//==============================================================================

#include <verilated.h>
#include <verilated_vcd_c.h>
#include <iostream>
#include <cstdint>

// Include generated model header
#include "Vcordic_top.h"

// Simulation time
vluint64_t sim_time = 0;
const vluint64_t MAX_SIM_TIME = 100000;

// VCD trace
VerilatedVcdC* tfp = nullptr;

// Clock period
const int CLK_PERIOD = 10;

// Clock generator
void toggle_clock(Vcordic_top* dut) {
    dut->clk = 0;
    dut->eval();
    tfp->dump(sim_time);
    sim_time += CLK_PERIOD / 2;
    
    dut->clk = 1;
    dut->eval();
    tfp->dump(sim_time);
    sim_time += CLK_PERIOD / 2;
}

// Reset sequence
void reset_dut(Vcordic_top* dut) {
    dut->rst_n = 0;
    dut->valid_in = 0;
    dut->ready_in = 1;
    dut->config_valid = 0;
    dut->x_in = 0;
    dut->y_in = 0;
    dut->z_in = 0;
    dut->cfg_iterations = 8;
    dut->cfg_saturate = 1;
    
    for (int i = 0; i < 5; i++) {
        toggle_clock(dut);
    }
    
    dut->rst_n = 1;
    for (int i = 0; i < 2; i++) {
        toggle_clock(dut);
    }
}

// Send config
void send_config(Vcordic_top* dut, uint8_t iterations, uint8_t saturate) {
    dut->cfg_iterations = iterations;
    dut->cfg_saturate = saturate;
    dut->config_valid = 1;
    toggle_clock(dut);
    dut->config_valid = 0;
    toggle_clock(dut);
    toggle_clock(dut);
}

// Send data vector
void send_vector(Vcordic_top* dut, int16_t x, int16_t y, int16_t z) {
    dut->x_in = x;
    dut->y_in = y;
    dut->z_in = z;
    dut->valid_in = 1;
    toggle_clock(dut);
    dut->valid_in = 0;
}

// Wait for valid_out
void wait_for_output(Vcordic_top* dut, int max_cycles = 50) {
    for (int i = 0; i < max_cycles; i++) {
        if (dut->valid_out) {
            return;
        }
        toggle_clock(dut);
    }
    std::cerr << "WARNING: Timeout waiting for valid_out" << std::endl;
}

// Print output
void print_output(Vcordic_top* dut, const char* test_name) {
    std::cout << test_name 
              << ": x=" << dut->x_out
              << ", y=" << dut->y_out
              << ", z=" << dut->z_out
              << ", ovf=" << dut->overflow
              << ", irq=" << dut->irq
              << std::endl;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);
    
    Vcordic_top* dut = new Vcordic_top;
    
    // Initialize VCD tracing
    tfp = new VerilatedVcdC;
    dut->trace(tfp, 99);
    tfp->open("waveform.vcd");
    
    std::cout << "=== CORDIC Accelerator Simulation ===" << std::endl;
    
    // Reset
    reset_dut(dut);
    
    // Default config
    send_config(dut, 8, 1);
    
    // Test 1: 45 degrees
    std::cout << "\n--- Test 1: Sin/Cos 45 deg ---" << std::endl;
    send_vector(dut, 2488, 0, 3217);  // x=1/K, z=45 deg
    wait_for_output(dut);
    print_output(dut, "TEST 1");
    
    // Test 2: 90 degrees
    std::cout << "\n--- Test 2: Sin/Cos 90 deg ---" << std::endl;
    send_vector(dut, 2488, 0, 6433);  // z=90 deg
    wait_for_output(dut);
    print_output(dut, "TEST 2");
    
    // Test 3: Back-to-back
    std::cout << "\n--- Test 3: Back-to-back vectors ---" << std::endl;
    for (int i = 0; i < 5; i++) {
        send_vector(dut, 2488, 0, 3217 + i * 100);
        toggle_clock(dut);
    }
    // Wait for all outputs
    for (int i = 0; i < 5; i++) {
        wait_for_output(dut, 20);
        print_output(dut, "BACK-TO-BACK");
    }
    
    // Test 4: Backpressure
    std::cout << "\n--- Test 4: Backpressure ---" << std::endl;
    dut->ready_in = 0;
    for (int i = 0; i < 3; i++) {
        send_vector(dut, 2488, 0, 3217);
        toggle_clock(dut);
    }
    for (int i = 0; i < 3; i++) toggle_clock(dut);
    
    dut->ready_in = 1;
    for (int i = 0; i < 3; i++) {
        wait_for_output(dut, 30);
        print_output(dut, "BACKPRESSURE");
    }
    
    // Test 5: Config change
    std::cout << "\n--- Test 5: Config Change ---" << std::endl;
    send_config(dut, 4, 0);  // 4 iterations, wrap mode
    send_vector(dut, 2488, 0, 3217);
    wait_for_output(dut);
    print_output(dut, "CONFIG CHANGE");
    
    // Final cycles
    for (int i = 0; i < 10; i++) {
        toggle_clock(dut);
    }
    
    // Cleanup
    tfp->close();
    delete dut;
    
    std::cout << "\n=== Simulation Complete ===" << std::endl;
    return 0;
}