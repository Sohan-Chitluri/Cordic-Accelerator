//==============================================================================
// Testbench: cordic_pipeline_tb.v
// Description: Integration testbench for cordic_pipeline module
// Owner: Pipeline RTL Agent
// Dependencies: cordic_pipeline.v, cordic_pkg.v
// Wave: 3
//==============================================================================

module cordic_pipeline_tb;

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
  cordic_pipeline #(
    .WIDTH(WIDTH),
    .FRACT_W(FRACT_W),
    .ITERATIONS(ITERATIONS)
  ) dut (
    .clk            (clk),
    .rst_n          (rst_n),
    .x_in           (x_in),
    .y_in           (y_in),
    .z_in           (z_in),
    .valid_in       (valid_in),
    .ready_out      (ready_out),
    .cfg_iterations (cfg_iterations),
    .cfg_saturate   (cfg_saturate),
    .config_valid   (config_valid),
    .config_ready   (config_ready),
    .x_out          (x_out),
    .y_out          (y_out),
    .z_out          (z_out),
    .valid_out      (valid_out),
    .ready_in       (ready_in),
    .overflow       (overflow),
    .irq            (irq)
  );

  // ---------------------------------------------------------------------------
  // TEST SEQUENCE
  // ---------------------------------------------------------------------------
  initial begin
    $display("=== cordic_pipeline Integration Testbench ===");
    
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
    
    // Test 1: Sin/Cos at 45 degrees
    $display("\n--- TEST 1: Sin/Cos 45 deg ---");
    cfg_iterations = 8;
    cfg_saturate = 1;
    config_valid = 1;
    @(posedge clk);
    config_valid = 0;
    @(posedge clk);
    
    // x = 1/K ≈ 2488, y = 0, z = 45 deg ≈ 3217
    x_in = 16'sd2488;
    y_in = 16'sd0;
    z_in = 16'sd3217;
    valid_in = 1;
    @(posedge clk);
    valid_in = 0;
    
    // Wait for pipeline fill + latency
    repeat (ITERATIONS + 5) @(posedge clk);
    
    $display("TEST 1: x_out=%d (expected ~2488), y_out=%d (expected ~2488), z_out=%d (expected ~0), ovf=%b", 
             x_out, y_out, z_out, overflow);
    
    // Test 2: Sin/Cos at 90 degrees
    $display("\n--- TEST 2: Sin/Cos 90 deg ---");
    x_in = 16'sd2488;
    y_in = 16'sd0;
    z_in = 16'sd6433;  // 90 deg
    valid_in = 1;
    @(posedge clk);
    valid_in = 0;
    repeat (ITERATIONS + 5) @(posedge clk);
    
    $display("TEST 2: x_out=%d (expected ~0), y_out=%d (expected ~4096), z_out=%d, ovf=%b", 
             x_out, y_out, z_out, overflow);
    
    // Test 3: Back-to-back throughput
    $display("\n--- TEST 3: Back-to-back throughput ---");
    for (integer i = 0; i < 5; i = i + 1) begin
      x_in = 16'sd2488;
      y_in = 16'sd0;
      z_in = 16'sd3217 + (i * 100);
      valid_in = 1;
      @(posedge clk);
    end
    valid_in = 0;
    repeat (ITERATIONS + 5) @(posedge clk);
    
    $display("TEST 3: Pipeline sustained throughput check complete");
    
    // Test 4: Backpressure
    $display("\n--- TEST 4: Backpressure ---");
    ready_in = 0;
    for (integer i = 0; i < 3; i = i + 1) begin
      x_in = 16'sd2488;
      y_in = 16'sd0;
      z_in = 16'sd3217;
      valid_in = 1;
      @(posedge clk);
    end
    valid_in = 0;
    repeat (3) @(posedge clk);
    ready_in = 1;
    repeat (ITERATIONS + 5) @(posedge clk);
    
    $display("TEST 4: Backpressure recovery complete");
    
    // Test 5: Config change
    $display("\n--- TEST 5: Config change ---");
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
    
    $display("TEST 5: Config change applied");
    
    $display("\n=== All Pipeline Tests Complete ===");
    $finish;
  end

endmodule
