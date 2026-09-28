//==============================================================================
// Module: cordic_stage
// Description: Single CORDIC iteration stage. Hardwired shift amount (no barrel
//              shifter). Per-stage angle constant embedded from package ATAN_LUT.
//              Datapath: fixed-shift → 2:1 MUX → 3× fp_add_sub → register.
//              1-cycle registered output.
//
// Owner: Datapath RTL Agent
// Parameters: WIDTH, FRACT_W, STAGE_IDX (hardwired per instance by cordic_pipeline)
// Dependencies: cordic_pkg, fp_add_sub
// Wave: 2 (Core Stage)
//==============================================================================

import cordic_pkg::*;

module cordic_stage #(
  parameter int WIDTH     = cordic_pkg::WIDTH,
  parameter int FRACT_W   = cordic_pkg::FRACT_W,
  parameter int STAGE_IDX = 0              // hardwired 0..ITERATIONS-1 per instance
) (
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic signed [WIDTH-1:0] x_in,
  input  logic signed [WIDTH-1:0] y_in,
  input  logic signed [WIDTH-1:0] z_in,
  input  logic                    valid_in,
  input  logic                    sat,     // 1 = saturate, 0 = wrap
  output logic signed [WIDTH-1:0] x_out,
  output logic signed [WIDTH-1:0] y_out,
  output logic signed [WIDTH-1:0] z_out,
  output logic                    valid_out,
  output logic                    overflow
);

  // ---------------------------------------------------------------------------
  // PARAMETER DOMAIN GUARD
  // ---------------------------------------------------------------------------
  // STAGE_ANGLE (below) is a table of atan(2^-i) * 2^FRACT_W precomputed for
  // FRACT_W=12 ONLY. Rescaling it to another FRACT_W is not a simple shift
  // (atan is transcendental), so any FRACT_W != 12 silently produced wrong
  // rotation angles here prior to this fix (root cause of the reported
  // 16/10/8 and 32/24/8 failures — WIDTH can vary, FRACT_W cannot).
  // Additionally, the table only has entries for STAGE_IDX 0..15; the old
  // code's final `else` branch silently reused the STAGE_IDX==7 value (32)
  // for every STAGE_IDX >= 8, which is the root cause of any ITERATIONS > 8
  // failure. WIDTH must also be wide enough to hold the largest table entry
  // (3217 needs 13 signed bits) — this is what made 8/4/8 and 4/1/8 fail too
  // (both WIDTH and FRACT_W out of domain).
  //
  // Per architecture ADR-0002 (no general multiplier in the datapath) these
  // constants must stay compile-time literals, not a runtime-computed
  // rescale. Since transcendental-function elaboration (e.g. $atan in a
  // localparam) is not reliably supported by the project's synthesis path
  // (Yosys) or verified portable across the full toolchain (Verilator +
  // Yosys + SymbiYosys), we do NOT attempt full FRACT_W genericity here.
  // Instead: FRACT_W is a fixed architectural constant (12) and any other
  // value must fail elaboration loudly rather than compute silently-wrong
  // numbers. This mirrors the constraint already implicit in cordic_lut's
  // K_FACTOR shift-add network.
  //
  // The static-assert idiom below (division by a param-dependent constant
  // that evaluates to 0 for an unsupported config) is a compile-time error
  // in Verilator, Yosys, and standard SV simulators/synthesizers alike —
  // unlike an `initial $fatal`, it also fires during synthesis elaboration.
  localparam bit FRACT_W_SUPPORTED   = (FRACT_W == 12);
  localparam bit STAGE_IDX_SUPPORTED = (STAGE_IDX < 16);
  localparam bit WIDTH_SUPPORTED     = (WIDTH >= 13);   // must hold +/-3217
  localparam int unsigned STATIC_ASSERT_STAGE_DOMAIN =
    (FRACT_W_SUPPORTED && STAGE_IDX_SUPPORTED && WIDTH_SUPPORTED) ? 1 : 1/0;

  // Human-readable failure message for simulation flows (the static assert
  // above already blocks synthesis/elaboration on its own).
  initial begin
    if (!FRACT_W_SUPPORTED) begin
      $fatal(1, "cordic_stage: unsupported FRACT_W=%0d (only FRACT_W=12 is supported; STAGE_ANGLE is a precomputed Q.12 atan table)", FRACT_W);
    end
    if (!STAGE_IDX_SUPPORTED) begin
      $fatal(1, "cordic_stage: unsupported STAGE_IDX=%0d (only STAGE_IDX 0..15 have precomputed atan constants; ITERATIONS must be <= 16)", STAGE_IDX);
    end
    if (!WIDTH_SUPPORTED) begin
      $fatal(1, "cordic_stage: unsupported WIDTH=%0d (WIDTH must be >= 13 to hold the +/-3217 STAGE_ANGLE constant)", WIDTH);
    end
  end

  // Per-stage angle: atan(2^-STAGE_IDX) x 2^FRACT_W, FRACT_W=12 fixed (see
  // domain guard above). Nested ternary for guaranteed elaboration-time
  // constant folding in all tools (STAGE_IDX 0..15; entries beyond ~12
  // correctly round to 0 at Q12 precision -- not a bug, just below
  // resolution -- STAGE_IDX >= 16 is rejected by the guard above).
  localparam logic signed [WIDTH-1:0] STAGE_ANGLE =
    (STAGE_IDX == 0)  ? 3217 :   // 45.000 deg
    (STAGE_IDX == 1)  ? 1899 :   // 26.565 deg
    (STAGE_IDX == 2)  ? 1003 :   // 14.036 deg
    (STAGE_IDX == 3)  ? 509  :   //  7.125 deg
    (STAGE_IDX == 4)  ? 256  :   //  3.576 deg
    (STAGE_IDX == 5)  ? 128  :   //  1.790 deg
    (STAGE_IDX == 6)  ? 64   :   //  0.895 deg
    (STAGE_IDX == 7)  ? 32   :   //  0.448 deg
    (STAGE_IDX == 8)  ? 16   :   //  0.224 deg
    (STAGE_IDX == 9)  ? 8    :   //  0.112 deg
    (STAGE_IDX == 10) ? 4    :   //  0.056 deg
    (STAGE_IDX == 11) ? 2    :   //  0.028 deg
    (STAGE_IDX == 12) ? 1    :   //  0.014 deg
                         0;      //  STAGE_IDX 13..15: rounds to 0 at Q12

  // ---------------------------------------------------------------------------
  // COMBINATIONAL DATAPATH
  // ---------------------------------------------------------------------------

  // Sigma = direction of rotation (0 if z < 0, 1 if z >= 0)
  logic sigma;
  always_comb sigma = ~z_in[WIDTH-1];  // MSB is sign bit; invert for sigma

  // Round-to-nearest arithmetic right shift by STAGE_IDX (hardwired, no barrel
  // shifter). Inlined from cordic_pkg::asr — calling through an 'input int'
  // function parameter prevents Yosys from constant-folding the shift amount,
  // which leaves x_shifted[0]/y_shifted[0] undriven in the synthesized netlist.
  localparam int ROUND_BIAS = (STAGE_IDX > 0) ? (1 << (STAGE_IDX - 1)) : 0;

  logic signed [WIDTH:0]   biased_x,      biased_y;
  logic signed [WIDTH:0]   shifted_ext_x, shifted_ext_y;
  logic signed [WIDTH-1:0] x_shifted,     y_shifted;

  always_comb begin
    biased_x      = {x_in[WIDTH-1], x_in} + (WIDTH+1)'(ROUND_BIAS);
    biased_y      = {y_in[WIDTH-1], y_in} + (WIDTH+1)'(ROUND_BIAS);
    shifted_ext_x = biased_x      >>> STAGE_IDX;
    shifted_ext_y = biased_y      >>> STAGE_IDX;
    x_shifted     = shifted_ext_x[WIDTH-1:0];
    y_shifted     = shifted_ext_y[WIDTH-1:0];
  end

  // BUGFIX (MIN_NEG): this used to be a conditional unary negate
  // (`x_mux = sigma ? x_shifted : -x_shifted;`) feeding a fixed-op adder.
  // Unary negation of a WIDTH-bit value overflows silently when
  // x_shifted/y_shifted == MIN_NEG (reachable whenever x_in/y_in == MIN_NEG
  // and STAGE_IDX == 0, since asr(MIN_NEG, 0) == MIN_NEG), producing the
  // wrong sign into the adder with no overflow indication.
  //
  // Fix: never negate the shifted operand. Feed it to fp_add_sub unmodified
  // and select add/subtract via `op` instead, which is mathematically
  // identical (x_new = x_in - sigma*y_shifted, y_new = y_in + sigma*x_shifted)
  // but never truncates/negates an operand outside fp_add_sub's own
  // (now-correct, sign-extend-first) overflow-safe path.
  logic         op_x, op_y;
  always_comb begin
    op_x = sigma;    // sigma=1: x_new = x_in - y_shifted (subtract)
                      // sigma=0: x_new = x_in + y_shifted (add)
    op_y = ~sigma;    // sigma=1: y_new = y_in + x_shifted (add)
                      // sigma=0: y_new = y_in - x_shifted (subtract)
  end

  // Three fp_add_sub instances
  logic signed [WIDTH-1:0] x_comb, y_comb, z_comb;
  logic         ovf_x, ovf_y, ovf_z;

  // X path: x_new = x_in -/+ (y_in >> STAGE_IDX), sign selected by sigma via op
  fp_add_sub #(.WIDTH(WIDTH), .FRACT_W(FRACT_W)) x_adder (
    .a       (x_in),
    .b       (y_shifted),
    .op      (op_x),
    .sat     (sat),
    .result  (x_comb),
    .overflow(ovf_x)
  );

  // Y path: y_new = y_in +/- (x_in >> STAGE_IDX), sign selected by sigma via op
  fp_add_sub #(.WIDTH(WIDTH), .FRACT_W(FRACT_W)) y_adder (
    .a       (y_in),
    .b       (x_shifted),
    .op      (op_y),
    .sat     (sat),
    .result  (y_comb),
    .overflow(ovf_y)
  );

  // Z path: z_new = z_in - sigma × atan(2^-STAGE_IDX)
  // Note: z wraps (no saturation); convergence property guarantees z → 0
  fp_add_sub #(.WIDTH(WIDTH), .FRACT_W(FRACT_W)) z_adder (
    .a       (z_in),
    .b       (sigma ? STAGE_ANGLE : -STAGE_ANGLE),
    .op      (1'b1),      // subtract (sigma already applied to b)
    .sat     (1'b0),      // z-path wraps; saturation would break convergence
    .result  (z_comb),
    .overflow(ovf_z)
  );

  // ---------------------------------------------------------------------------
  // REGISTERED OUTPUTS (1-cycle latency)
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      x_out     <= '0;
      y_out     <= '0;
      z_out     <= '0;
      valid_out <= 1'b0;
      overflow  <= 1'b0;
    end else begin
      x_out     <= x_comb;
      y_out     <= y_comb;
      z_out     <= z_comb;
      valid_out <= valid_in;
      overflow  <= ovf_x | ovf_y;  // z overflow excluded (z wraps by design)
    end
  end

  // ---------------------------------------------------------------------------
  // ASSERTIONS (bound from cordic_assertions)
  // ---------------------------------------------------------------------------
`ifdef ASSERT_ON
  cordic_assertions #(.WIDTH(WIDTH), .ITERATIONS(cordic_pkg::ITERATIONS)) assert_inst (
    .clk      (clk),   .rst_n    (rst_n),
    .x_in     (x_in),  .y_in     (y_in),   .z_in     (z_in),
    .valid_in (valid_in), .sat   (sat),
    .x_out    (x_out), .y_out    (y_out),   .z_out    (z_out),
    .valid_out(valid_out), .overflow(overflow)
  );
`endif

endmodule
