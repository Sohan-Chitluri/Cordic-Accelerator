//==============================================================================
// Testbench: fp_add_sub_tb.v
// Description: Unit testbench for fp_add_sub module
// Owner: Arithmetic RTL Agent
// Dependencies: fp_add_sub.v, cordic_pkg.v
// Wave: 1
//==============================================================================

module fp_add_sub_tb;

  `include "cordic_pkg.v"

  // Parameters
  parameter integer WIDTH   = 16;
  parameter integer FRACT_W = 12;

  // Signals
  reg  signed [WIDTH-1:0] a, b;
  reg                     op;   // 0 = add, 1 = sub
  reg                     sat;  // 1 = saturate, 0 = wrap
  wire signed [WIDTH-1:0] result;
  wire                    overflow;

  // DUT instance
  fp_add_sub #(
    .WIDTH(WIDTH),
    .FRACT_W(FRACT_W),
    .USE_CARRY_SELECT(1)
  ) dut (
    .a      (a),
    .b      (b),
    .op     (op),
    .sat    (sat),
    .result (result),
    .overflow(overflow)
  );

  // ---------------------------------------------------------------------------
  // TEST VECTORS
  // ---------------------------------------------------------------------------
  initial begin
    $display("=== fp_add_sub Unit Testbench ===");
    
    // Test 1: Basic add
    a = 16'sd100;  b = 16'sd200;  op = 1'b0; sat = 1'b1;
    #10;
    $display("ADD: %d + %d = %d (ovf=%b) [expected 300]", a, b, result, overflow);
    
    // Test 2: Basic sub
    a = 16'sd500;  b = 16'sd200;  op = 1'b1; sat = 1'b1;
    #10;
    $display("SUB: %d - %d = %d (ovf=%b) [expected 300]", a, b, result, overflow);
    
    // Test 3: Saturation max
    a = 16'sh7FFF; b = 16'sd1;    op = 1'b0; sat = 1'b1;
    #10;
    $display("SAT MAX: %d + %d = %d (ovf=%b) [expected 32767]", a, b, result, overflow);
    
    // Test 4: Saturation min
    a = 16'sh8000; b = -16'sd1;   op = 1'b0; sat = 1'b1;
    #10;
    $display("SAT MIN: %d - %d = %d (ovf=%b) [expected -32768]", a, b, result, overflow);
    
    // Test 5: Wrap mode
    a = 16'sh7FFF; b = 16'sd1;    op = 1'b0; sat = 1'b0;
    #10;
    $display("WRAP: %d + %d = %d (ovf=%b) [expected -32768]", a, b, result, overflow);
    
    // Test 6: Zero operands
    a = 16'sd0;    b = 16'sd0;    op = 1'b0; sat = 1'b1;
    #10;
    $display("ZERO: %d + %d = %d (ovf=%b) [expected 0]", a, b, result, overflow);
    
    // Test 7: Negative add
    a = -16'sd100; b = -16'sd200; op = 1'b0; sat = 1'b1;
    #10;
    $display("NEG ADD: %d + %d = %d (ovf=%b) [expected -300]", a, b, result, overflow);
    
    // Test 8: Sign change
    a = 16'sh7FFF; b = 16'sh8000; op = 1'b0; sat = 1'b1;
    #10;
    $display("SIGN CHANGE: %d + %d = %d (ovf=%b) [expected -1]", a, b, result, overflow);

    $display("=== All Tests Complete ===");
    $finish;
  end

  // ---------------------------------------------------------------------------
  // ASSERTIONS
  // ---------------------------------------------------------------------------
`ifdef ASSERT_ON
  // Basic functionality assertions would go here
`endif

endmodule
