//==============================================================================
// Testbench: cordic_top_tb.v
// Description: Top-level regression testbench for cordic_top module
// Owner: Integration Agent
// Dependencies: cordic_top.v, cordic_pkg.v
// Wave: 4
//==============================================================================

module cordic_top_tb;

  `include "cordic_pkg.v"

  // Parameters
  parameter integer WIDTH       = 16;
  parameter integer FRACT_W     = 12;
  parameter integer ITERATIONS  = 8;

  // Signals
  reg                       clk;
  reg                       rst_n;
  reg  signed [WIDTH-1:0]   x_in, y_in, z_in;
  reg                       valid_in;
  wire                      ready_out;
  reg  [3:0]                cfg_iterations;
  reg                       cfg_saturate;
  reg                       config_valid;
  wire                      config_ready;
  wire signed [WIDTH-1:0]   x_out, y_out, z_out;
  wire                      valid_out;
  reg                       ready_in;
  wire                      overflow;
  wire                      irq;

  // Clock generation
  initial clk = 0;
  always #5 clk = ~clk;

  // DUT instance
  cordic_top #(
    .WIDTH(WIDTH),
    .FRACT_W(FRACT_W),
    .ITERATIONS(ITERATIONS)
  ) dut (
    .clk             (clk),
    .rst_n           (rst_n),
    .x_in            (x_in),
    .y_in            (y_in),
    .z_in            (z_in),
    .valid_in        (valid_in),
    .ready_out       (ready_out),
    .cfg_iterations  (cfg_iterations),
    .cfg_saturate    (cfg_saturate),
    .config_valid    (config_valid),
    .config_ready    (config_ready),
    .x_out           (x_out),
    .y_out           (y_out),
    .z_out           (z_out),
    .valid_out       (valid_out),
    .ready_in        (ready_in),
    .overflow        (overflow),
    .irq             (irq)
  );

  // ---------------------------------------------------------------------------
  // TEST SEQUENCE
  // ---------------------------------------------------------------------------
  initial begin
    $display("=== cordic_top Regression Testbench ===");
    
    // Initialize
    rst_n = 0;
    valid_in = 0;
    ready_in = 1;
    config_valid = 0;
    cfg_iterations = ITERATIONS;
    cfg_saturate = 1;
    x_in = 0; y_in = 0; z_in = 0;
    
    // Reset sequence
    repeat (3) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);
    
    // Test 1: Basic rotation at 45 degrees
    $display("\n--- TEST 1: Rotation 45 deg ---");
    cfg_iterations = 8;
    cfg_saturate = 1;
    config_valid = 1;
    @(posedge clk);
    config_valid = 0;
    @(posedge clk);
    
    x_in = 16'sd2488;  // 1/K in Q12.3
    y_in = 16'sd0;
    z_in = 16'sd3217;  // 45 deg
    valid_in = 1;
    @(posedge clk);
    valid_in = 0;
    
    repeat (ITERATIONS + 5) @(posedge clk);
    
    $display("TEST 1: x_out=%d, y_out=%d, z_out=%d, valid=%b, ovf=%b", 
             x_out, y_out, z_out, valid_out, overflow);
    
    // Test 2: Rotation at 90 degrees
    $display("\n--- TEST 2: Rotation 90 deg ---");
    x_in = 16'sd2488;
    y_in = 16'sd0;
    z_in = 16'sd6433;  // 90 deg
    valid_in = 1;
    @(posedge clk);
    valid_in = 0;
    repeat (ITERATIONS + 5) @(posedge clk);
    
    $display("TEST 2: x_out=%d, y_out=%d, z_out=%d, valid=%b, ovf=%b", 
             x_out, y_out, z_out, valid_out, overflow);
    
    // Test 3: Config change
    $display("\n--- TEST 3: Config change (4 iter, wrap mode) ---");
    cfg_iterations = 4;
    cfg_saturate = 0;
    config_valid = 1;
    @(posedge clk);
    config_valid = 0;
    @(posedge clk);
    
    x_in = 16'sd2488;
    y_in = 16'sd0;
    z_in = 16'sd3217;
    valid_in = 1;
    @(posedge clk);
    valid_in = 0;
    repeat (6) @(posedge clk);
    
    $display("TEST 3: x_out=%d, y_out=%d, z_out=%d, valid=%b, ovf=%b", 
             x_out, y_out, z_out, valid_out, overflow);
    
    $display("\n=== All Top-Level Tests Complete ===");
    $finish;
  end

endmodule
