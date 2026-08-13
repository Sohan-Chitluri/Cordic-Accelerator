//==============================================================================
// Testbench: cordic_lut_tb.v
// Description: Unit testbench for cordic_lut module
// Owner: Datapath RTL Agent
// Dependencies: cordic_lut.v, cordic_pkg.v
// Wave: 1
//==============================================================================

module cordic_lut_tb;

  `include "cordic_pkg.v"

  // Parameters
  parameter integer WIDTH       = 16;
  parameter integer FRACT_W     = 12;
  parameter integer ITERATIONS  = 8;

  // Signals
  reg  [$clog2(ITERATIONS):0] stage_idx;
  reg  [3:0]                  k_lut_idx;
  wire signed [WIDTH-1:0]     angle_out;
  wire signed [WIDTH-1:0]     k_prescale_x;
  wire signed [WIDTH-1:0]     k_prescale_y;

  // DUT instance
  cordic_lut #(
    .WIDTH(WIDTH),
    .FRACT_W(FRACT_W),
    .ITERATIONS(ITERATIONS)
  ) dut (
    .stage_idx     (stage_idx),
    .k_lut_idx     (k_lut_idx),
    .angle_out     (angle_out),
    .k_prescale_x  (k_prescale_x),
    .k_prescale_y  (k_prescale_y)
  );

  // ---------------------------------------------------------------------------
  // TEST SEQUENCE
  // ---------------------------------------------------------------------------
  initial begin
    $display("=== cordic_lut Unit Testbench ===");
    
    // Test all 8 angle entries
    for (integer i = 0; i < ITERATIONS; i = i + 1) begin
      stage_idx = i;
      #1;
      $display("ANGLE[%0d] = %d (0x%h)", i, angle_out, angle_out);
    end
    
    // Test all 16 K-prescale entries
    for (integer i = 0; i < 16; i = i + 1) begin
      k_lut_idx = i;
      #1;
      $display("K_LUT[%0d] = %d (0x%h)", i, k_prescale_x, k_prescale_x);
    end
    
    $display("=== All Tests Complete ===");
    $finish;
  end

endmodule
