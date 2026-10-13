`timescale 1ns/1ps
//==============================================================================
// Testbench: cordic_param_matrix_tb
// Description: Parameter-matrix regression harness for cordic_stage /
//              cordic_lut. Top-level WIDTH/FRACT_W/ITERATIONS are overridable
//              from the command line (e.g. `verilator ... -GWIDTH=16
//              -GFRACT_W=10 -GITERATIONS=8 ...`), so this single file can be
//              elaborated once per (WIDTH, FRACT_W, ITERATIONS) combination
//              in the regression matrix.
//
// For an IN-DOMAIN combination (FRACT_W==12, ITERATIONS<=16, WIDTH>=13) it
// runs a real functional smoke check: it drives the full ITERATIONS-stage
// chain with the CORDIC-gain-prescaled unit vector at z=0 and checks the
// output converges to (K^-1-scaled) (1,0) within a small tolerance, matching
// golden_model.py's known-angle test.
//
// For an OUT-OF-DOMAIN combination this file is expected to FAIL TO
// ELABORATE (via the static_assert guards added to cordic_stage.sv /
// cordic_lut.sv) -- i.e. a nonzero exit code from this testbench's build
// step is the PASS condition for that config, checked by the driver script
// tb/run_param_matrix.sh, not by this file's own $display/$fatal.
//
// Regression matrix (see tb/run_param_matrix.sh):
//   16/12/8   -- default, must elaborate AND functionally pass (baseline)
//   16/12/12  -- FRACT_W still 12, extended ITERATIONS -- must PASS
//   20/12/8   -- WIDTH widened, FRACT_W still 12 -- must PASS
//   16/10/8   -- FRACT_W != 12 -- must FAIL ELABORATION
//   32/24/8   -- FRACT_W != 12 -- must FAIL ELABORATION
//   8/4/8     -- FRACT_W != 12, WIDTH < 13 -- must FAIL ELABORATION
//   4/1/8     -- FRACT_W != 12, WIDTH < 13 -- must FAIL ELABORATION
//   16/12/17  -- ITERATIONS > 16 (no precomputed angle) -- must FAIL ELABORATION
//
// Owner: Verification Agent
// Wave: 2
//==============================================================================

module cordic_param_matrix_tb #(
  parameter int WIDTH      = cordic_pkg::WIDTH,
  parameter int FRACT_W    = cordic_pkg::FRACT_W,
  parameter int ITERATIONS = cordic_pkg::ITERATIONS
);

  logic clk, rst_n;
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // K-factor prescale check (also carries cordic_lut's own domain guard).
  logic signed [WIDTH-1:0] lut_x_in, lut_y_in;
  logic signed [WIDTH-1:0] lut_x_out, lut_y_out;

  cordic_lut #(
    .WIDTH     (WIDTH),
    .FRACT_W   (FRACT_W),
    .ITERATIONS(ITERATIONS)
  ) dut_lut (
    .x_in        (lut_x_in),
    .y_in        (lut_y_in),
    .k_prescale_x(lut_x_out),
    .k_prescale_y(lut_y_out)
  );

  // ITERATIONS-deep cordic_stage chain (also carries cordic_stage's own
  // domain guard, evaluated once per instantiated STAGE_IDX).
  logic signed [WIDTH-1:0] chain_x [0:ITERATIONS];
  logic signed [WIDTH-1:0] chain_y [0:ITERATIONS];
  logic signed [WIDTH-1:0] chain_z [0:ITERATIONS];
  logic                    chain_valid [0:ITERATIONS];
  logic                    chain_ovf   [0:ITERATIONS];

  genvar gi;
  generate
    for (gi = 0; gi < ITERATIONS; gi++) begin : g_stage
      cordic_stage #(
        .WIDTH    (WIDTH),
        .FRACT_W  (FRACT_W),
        .STAGE_IDX(gi)
      ) dut_stage (
        .clk      (clk),
        .rst_n    (rst_n),
        .active_x (1'b1),
        .active_y (1'b1),
        .active_z (1'b1),
        .x_in     (chain_x[gi]),
        .y_in     (chain_y[gi]),
        .z_in     (chain_z[gi]),
        .valid_in (chain_valid[gi]),
        .sat      (1'b1),
        .x_out    (chain_x[gi+1]),
        .y_out    (chain_y[gi+1]),
        .z_out    (chain_z[gi+1]),
        .valid_out(chain_valid[gi+1]),
        .overflow (chain_ovf[gi+1])
      );
    end
  endgenerate

  int errors;

  initial begin
    errors = 0;
    rst_n  = 1'b0;
    chain_valid[0] = 1'b0;
    lut_x_in = '0; lut_y_in = '0;
    @(posedge clk); @(negedge clk);
    rst_n = 1'b1;

    // K-prescale spot check: k_prescale(ONE_FIX) ~= 0.6072 * 2^FRACT_W.
    lut_x_in = (1 <<< FRACT_W);
    lut_y_in = '0;
    #1;
    if (lut_x_out <= 0 || lut_x_out >= (1 <<< FRACT_W)) begin
      $error("[param_matrix] W=%0d F=%0d I=%0d: k_prescale(ONE_FIX)=%0d out of expected (0, ONE_FIX) range",
             WIDTH, FRACT_W, ITERATIONS, lut_x_out);
      errors++;
    end

    // Full-chain known-angle smoke check: rotate the prescaled unit vector
    // by z=0 -- x should stay ~= k_prescale(ONE_FIX), y should stay ~=0.
    @(negedge clk);
    chain_x[0]     = lut_x_out;
    chain_y[0]     = lut_y_out;
    chain_z[0]     = '0;
    chain_valid[0] = 1'b1;
    @(posedge clk); @(negedge clk);
    chain_valid[0] = 1'b0;
    repeat (ITERATIONS - 1) begin
      @(posedge clk); @(negedge clk);
    end

    if (chain_valid[ITERATIONS] !== 1'b1) begin
      $error("[param_matrix] W=%0d F=%0d I=%0d: chain valid_out never asserted",
             WIDTH, FRACT_W, ITERATIONS);
      errors++;
    end else begin
      // z=0 rotation: the CORDIC gain (~1.647x over enough iterations)
      // exactly cancels the K-factor prescale (~0.607x) applied by
      // cordic_lut, so x_out should converge back to the ORIGINAL
      // (pre-prescale) unit value lut_x_in -- NOT to the prescaled
      // lut_x_out itself. (First draft of this check compared against
      // lut_x_out and consequently misfired here: prescaling by K then
      // undoing it via CORDIC gain necessarily produces ~lut_x_in again,
      // which golden_model.py's known-angle test already establishes this
      // same way -- it feeds ONE_FIX in unprescaled and expects
      // cos(z)*ONE_FIX out.) y_out should be close to 0. Tolerance is
      // generous (~6% + slop) since low ITERATIONS counts (this smoke test
      // isn't restricted to 8) leave more residual angle/gain error.
      longint tol, dx, dy;
      tol = ((longint'(lut_x_in) < 0 ? -longint'(lut_x_in) : longint'(lut_x_in)) >>> 4) + 16;
      dx  = longint'(chain_x[ITERATIONS]) - longint'(lut_x_in);
      dy  = longint'(chain_y[ITERATIONS]);
      if (dx < 0) dx = -dx;
      if (dy < 0) dy = -dy;
      if (dx > tol) begin
        $error("[param_matrix] W=%0d F=%0d I=%0d: x_out=%0d far from expected ~%0d (tol=%0d)",
               WIDTH, FRACT_W, ITERATIONS, chain_x[ITERATIONS], lut_x_in, tol);
        errors++;
      end
      if (dy > tol) begin
        $error("[param_matrix] W=%0d F=%0d I=%0d: y_out=%0d far from expected ~0 (tol=%0d)",
               WIDTH, FRACT_W, ITERATIONS, chain_y[ITERATIONS], tol);
        errors++;
      end
    end

    if (errors != 0) $fatal(1, "FAIL: cordic_param_matrix W=%0d F=%0d I=%0d — %0d error(s)",
                             WIDTH, FRACT_W, ITERATIONS, errors);
    else $display("PASS: cordic_param_matrix W=%0d F=%0d I=%0d", WIDTH, FRACT_W, ITERATIONS);
    $finish;
  end

endmodule
