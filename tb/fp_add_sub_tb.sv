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

    // --- MIN_NEG directed regression (bugfix coverage) ---
    // The original RTL computed `b_eff = op ? -b : b` at WIDTH-bit precision
    // BEFORE sign-extending. Negating b==MIN_NEG (the most negative
    // representable value, e.g. -32768 @ WIDTH=16) overflows within WIDTH
    // bits and silently wraps back to MIN_NEG itself, which corrupted every
    // `a - MIN_NEG` computation (the true result a+32768 was silently
    // replaced by a+MIN_NEG, and overflow detection was lost). These vectors
    // specifically put MIN_NEG in the `b` (subtrahend) position, which the
    // pre-fix test suite never exercised.

    // 0 - MIN_NEG = -MIN_NEG = 32768 -> saturates to MAX_POS in sat mode.
    a = 16'sd0; b = MIN_NEG; op = 1'b1; sat = 1'b1; #1;
    sat_sub(a, b, sat, exp_r, exp_o); chk("sub(0,MIN_NEG) sat [negate MIN_NEG]");
    if (exp_o !== 1'b1 || exp_r !== MAX_POS) begin
      $error("[fp_add_sub] reference model sanity: sub(0,MIN_NEG) sat expected MAX_POS/ovf=1, got %0d/%0b", exp_r, exp_o);
      errors++;
    end

    // Same operation, wrap mode: 32768 mod 65536 wraps back to MIN_NEG.
    a = 16'sd0; b = MIN_NEG; op = 1'b1; sat = 1'b0; #1;
    sat_sub(a, b, sat, exp_r, exp_o); chk("sub(0,MIN_NEG) wrap [negate MIN_NEG]");

    // MIN_NEG - MIN_NEG = 0 (both operands MIN_NEG).
    a = MIN_NEG; b = MIN_NEG; op = 1'b1; sat = 1'b1; #1;
    sat_sub(a, b, sat, exp_r, exp_o); chk("sub(MIN_NEG,MIN_NEG) sat");
    if (exp_r !== 16'sd0 || exp_o !== 1'b0) begin
      $error("[fp_add_sub] reference model sanity: sub(MIN_NEG,MIN_NEG) expected 0/ovf=0, got %0d/%0b", exp_r, exp_o);
      errors++;
    end

    // Nonzero a with b=MIN_NEG, sat mode: a - MIN_NEG must saturate for any
    // a > -1 (since a+32768 > 32767 for a >= 0, and also for small negative a).
    a = 16'sd100; b = MIN_NEG; op = 1'b1; sat = 1'b1; #1;
    sat_sub(a, b, sat, exp_r, exp_o); chk("sub(100,MIN_NEG) sat");

    // Wrap mode, nonzero a.
    a = 16'sd100; b = MIN_NEG; op = 1'b1; sat = 1'b0; #1;
    sat_sub(a, b, sat, exp_r, exp_o); chk("sub(100,MIN_NEG) wrap");

    // b=MIN_NEG under ADD (op=0): a + MIN_NEG never overflows for in-range a
    // (no negation of b occurs on the add path), included for symmetry.
    a = 16'sd1; b = MIN_NEG; op = 1'b0; sat = 1'b1; #1;
    sat_add(a, b, sat, exp_r, exp_o); chk("add(1,MIN_NEG) sat");

    if (errors != 0) $fatal(1, "FAIL: fp_add_sub — %0d error(s)", errors);
    else        $display("PASS: fp_add_sub");
  end

endmodule
