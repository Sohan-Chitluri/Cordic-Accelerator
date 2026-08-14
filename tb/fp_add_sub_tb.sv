`timescale 1ns/1ps
//==============================================================================
// Testbench: fp_add_sub_tb
// Description: Self-checking unit testbench for fp_add_sub (combinational).
//              Expected values computed via cordic_pkg::sat_add / sat_sub.
// Owner: Verification Agent
// Wave: 1
//==============================================================================

module fp_add_sub_tb;
  import cordic_pkg::*;

  // DUT signals
  cordic_data_t a, b, result;
  logic         op;       // 0 = add, 1 = subtract
  logic         sat;
  logic         overflow;

  fp_add_sub dut (
    .a       (a),
    .b       (b),
    .op      (op),
    .sat     (sat),
    .result  (result),
    .overflow(overflow)
  );

  // ---------------------------------------------------------------------------
  // Checker
  // ---------------------------------------------------------------------------
  cordic_data_t exp_r;
  logic         exp_o;
  int           errors;

  task automatic chk(input string label);
    if (result !== exp_r || overflow !== exp_o) begin
      $error("[fp_add_sub] %s: got result=%0d ovf=%0b  expected=%0d ovf=%0b",
             label, result, overflow, exp_r, exp_o);
      errors++;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Test body
  // ---------------------------------------------------------------------------
  initial begin
    errors = 0;

    // --- ADD (op=0) ---

    // Basic add
    a = 16'sd100; b = 16'sd200; op = 1'b0; sat = 1'b1; #1;
    sat_add(a, b, sat, exp_r, exp_o); chk("add(100,200)");

    // Negative add
    a = -16'sd100; b = -16'sd200; op = 1'b0; sat = 1'b1; #1;
    sat_add(a, b, sat, exp_r, exp_o); chk("add(-100,-200)");

    // Positive saturation
    a = MAX_POS; b = 16'sd1; op = 1'b0; sat = 1'b1; #1;
    sat_add(a, b, sat, exp_r, exp_o); chk("add(MAX,1) sat");

    // Negative saturation
    a = MIN_NEG; b = -16'sd1; op = 1'b0; sat = 1'b1; #1;
    sat_add(a, b, sat, exp_r, exp_o); chk("add(MIN,-1) sat");

    // Positive wrap (sat=0)
    a = MAX_POS; b = 16'sd1; op = 1'b0; sat = 1'b0; #1;
    sat_add(a, b, sat, exp_r, exp_o); chk("add(MAX,1) wrap");

    // Negative wrap (sat=0)
    a = MIN_NEG; b = -16'sd1; op = 1'b0; sat = 1'b0; #1;
    sat_add(a, b, sat, exp_r, exp_o); chk("add(MIN,-1) wrap");

    // Zero
    a = 16'sd0; b = 16'sd0; op = 1'b0; sat = 1'b1; #1;
    sat_add(a, b, sat, exp_r, exp_o); chk("add(0,0)");

    // --- SUBTRACT (op=1) ---

    // Basic sub
    a = 16'sd500; b = 16'sd200; op = 1'b1; sat = 1'b1; #1;
    sat_sub(a, b, sat, exp_r, exp_o); chk("sub(500,200)");

    // Negative saturation: MIN_NEG - 1 → clamp
    a = MIN_NEG; b = 16'sd1; op = 1'b1; sat = 1'b1; #1;
    sat_sub(a, b, sat, exp_r, exp_o); chk("sub(MIN,1) sat");

    // Positive saturation: MAX_POS - (-1) → clamp
    a = MAX_POS; b = -16'sd1; op = 1'b1; sat = 1'b1; #1;
    sat_sub(a, b, sat, exp_r, exp_o); chk("sub(MAX,-1) sat");

    // Negative wrap: MIN_NEG - 1
    a = MIN_NEG; b = 16'sd1; op = 1'b1; sat = 1'b0; #1;
    sat_sub(a, b, sat, exp_r, exp_o); chk("sub(MIN,1) wrap");

    // Self (MAX - MAX = 0)
    a = MAX_POS; b = MAX_POS; op = 1'b1; sat = 1'b1; #1;
    sat_sub(a, b, sat, exp_r, exp_o); chk("sub(MAX,MAX)");

    // Q12 unit value round-trip
    a = ONE_FIX; b = ONE_FIX; op = 1'b1; sat = 1'b1; #1;
    sat_sub(a, b, sat, exp_r, exp_o); chk("sub(ONE,ONE)");

    if (errors != 0) $fatal(1, "FAIL: fp_add_sub — %0d error(s)", errors);
    else        $display("PASS: fp_add_sub");
  end

endmodule
