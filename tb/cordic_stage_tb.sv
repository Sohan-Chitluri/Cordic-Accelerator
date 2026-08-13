//==============================================================================
// Testbench: cordic_stage_tb.v
// Description: Unit testbench for cordic_stage module
// Owner: Datapath RTL Agent
// Dependencies: cordic_stage.v, cordic_pkg.v, fp_add_sub.v
// Wave: 2
//==============================================================================

module cordic_stage_tb;

  `include "cordic_pkg.v"

  // Parameters
  parameter integer WIDTH      = 16;
  parameter integer FRACT_W    = 12;
  parameter integer STAGE_IDX  = 0;

  // Signals
  reg                       clk;
  reg                       rst_n;
  reg  signed [WIDTH-1:0]   x_in, y_in, z_in;
  reg                       valid_in;
  reg                       sat;
  wire signed [WIDTH-1:0]   x_out, y_out, z_out;
  wire                      valid_out;
  wire                      overflow;

  // Clock generation
  initial clk = 0;
  always #5 clk = ~clk;

  // DUT instance
  cordic_stage #(
    .WIDTH(WIDTH),
    .FRACT_W(FRACT_W),
    .STAGE_IDX(STAGE_IDX)
  ) dut (
    .clk      (clk),
    .rst_n    (rst_n),
    .x_in     (x_in),
    .y_in     (y_in),
    .z_in     (z_in),
    .valid_in (valid_in),
    .sat      (sat),
    .x_out    (x_out),
    .y_out    (y_out),
    .z_out    (z_out),
    .valid_out(valid_out),
    .overflow (overflow)
  );

  // ---------------------------------------------------------------------------
  // TEST SEQUENCE
  // ---------------------------------------------------------------------------
  initial begin
    $display("=== cordic_stage Unit Testbench ===");
    
    // Reset
    rst_n = 0;
    valid_in = 0;
    sat = 1;
    x_in = 0; y_in = 0; z_in = 0;
    @(posedge clk);
    rst_n = 1;
    @(posedge clk);
    
    // Test 1: Stage 0 rotation by atan(1) = 45 deg
    // Input: x = 1/K ≈ 0.607, y = 0, z = 45 deg
    // After stage 0: x ≈ cos(45°), y ≈ sin(45°), z ≈ 0
    x_in = 16'sd2488;  // 0.607 in Q12.3
    y_in = 16'sd0;
    z_in = 16'sd3217;  // atan(1) = 45 deg
    valid_in = 1;
    @(posedge clk);
    valid_in = 0;
    @(posedge clk);
    @(posedge clk);  // Wait for latency
    
    $display("STAGE %0d TEST 1: x_out=%d, y_out=%d, z_out=%d, valid=%b, ovf=%b", 
             STAGE_IDX, x_out, y_out, z_out, valid_out, overflow);
    
    // Test 2: Negative angle
    x_in = 16'sd2488;
    y_in = 16'sd0;
    z_in = -16'sd3217;
    valid_in = 1;
    @(posedge clk);
    valid_in = 0;
    @(posedge clk);
    @(posedge clk);
    
    $display("STAGE %0d TEST 2: x_out=%d, y_out=%d, z_out=%d, valid=%b, ovf=%b", 
             STAGE_IDX, x_out, y_out, z_out, valid_out, overflow);
    
    // Test 3: Saturation
    x_in = 16'sh7FFF;
    y_in = 16'sh7FFF;
    z_in = 0;
    valid_in = 1;
    @(posedge clk);
    valid_in = 0;
    @(posedge clk);
    @(posedge clk);
    
    $display("STAGE %0d TEST 3 (SAT): x_out=%d, y_out=%d, z_out=%d, valid=%b, ovf=%b", 
             STAGE_IDX, x_out, y_out, z_out, valid_out, overflow);
    
    $display("=== All Tests Complete ===");
    $finish;
  end

endmodule
