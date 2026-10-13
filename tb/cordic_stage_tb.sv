`timescale 1ns/1ps
//==============================================================================
// Testbench: cordic_stage_tb
// Description: Self-checking unit testbench for cordic_stage (STAGE_IDX=0,1
//              single-stage checks, an 8-stage pipeline chain check, and
//              directed MIN_NEG regression vectors). Expected values computed
//              via cordic_pkg tasks to mirror RTL datapath exactly.
//
// NOTE (fix): this file previously called undefined tasks
// `compute_expected(...)` / `chk_stage(...)` (only the `_0`/`_1`-suffixed
// variants were defined) -- the testbench did not compile. Fixed to call the
// correctly-suffixed tasks. Also replaces the previous `run_8stage_chain`
// stub (which computed a software reference array but never drove/checked
// an actual 8-stage DUT chain) with a real generate-based 8-instance
// cordic_stage pipeline, driven and checked end-to-end.
//
// Also adds directed MIN_NEG regression vectors exercising the two bugs
// found and fixed in rtl/fp_add_sub.sv and rtl/cordic_stage.sv: unary
// negation of a WIDTH-bit value overflows silently when that value equals
// MIN_NEG (most-negative representable value), corrupting sign/overflow
// detection. STAGE_IDX=0 (shift=0) is used so x_shifted/y_shifted==x_in/y_in
// exactly, directly exercising the MIN_NEG path through both the adder and
// asr rounding.
//
// Owner: Verification Agent
// Wave: 2
//==============================================================================

module cordic_stage_tb;
  import cordic_pkg::*;

  // STAGE_IDX=0: atan(2^0)=45°, angle=3217, shift=0 (asr(v,0)=v)
  localparam int          STAGE_IDX_0 = 0;
  localparam cordic_data_t STAGE_ANGLE_0 = 16'sd3217;

  // STAGE_IDX=1: atan(2^-1)=26.565°, angle=1899, shift=1
  localparam int          STAGE_IDX_1 = 1;
  localparam cordic_data_t STAGE_ANGLE_1 = 16'sd1899;

  // STAGE_IDX=2..7 angles (for 8-stage chain)
  localparam cordic_data_t STAGE_ANGLE_2 = 16'sd1003;
  localparam cordic_data_t STAGE_ANGLE_3 = 16'sd509;
  localparam cordic_data_t STAGE_ANGLE_4 = 16'sd256;
  localparam cordic_data_t STAGE_ANGLE_5 = 16'sd128;
  localparam cordic_data_t STAGE_ANGLE_6 = 16'sd64;
  localparam cordic_data_t STAGE_ANGLE_7 = 16'sd32;

  // DUT signals
  logic         clk, rst_n;
  cordic_data_t x_in, y_in, z_in;
  logic         valid_in, sat;
  cordic_data_t x_out, y_out, z_out;
  logic         valid_out, overflow;

  // STAGE_IDX=0 DUT (for existing tests)
  cordic_stage #(
    .WIDTH    (WIDTH),
    .FRACT_W  (FRACT_W),
    .STAGE_IDX(STAGE_IDX_0)
  ) dut_0 (
    .clk      (clk),
    .rst_n    (rst_n),
    .active_x (1'b1),
    .active_y (1'b1),
    .active_z (1'b1),
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

  // STAGE_IDX=1 DUT (for STG_002)
  cordic_data_t x_out_1, y_out_1, z_out_1;
  logic         valid_out_1, overflow_1;

  cordic_stage #(
    .WIDTH    (WIDTH),
    .FRACT_W  (FRACT_W),
    .STAGE_IDX(STAGE_IDX_1)
  ) dut_1 (
    .clk      (clk),
    .rst_n    (rst_n),
    .active_x (1'b1),
    .active_y (1'b1),
    .active_z (1'b1),
    .x_in     (x_in),
    .y_in     (y_in),
    .z_in     (z_in),
    .valid_in (valid_in),
    .sat      (sat),
    .x_out    (x_out_1),
    .y_out    (y_out_1),
    .z_out    (z_out_1),
    .valid_out(valid_out_1),
    .overflow (overflow_1)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  // ---------------------------------------------------------------------------
  // Expected output registers (written before posedge, checked after negedge)
  // ---------------------------------------------------------------------------
  cordic_data_t exp_x, exp_y, exp_z;
  logic         exp_ovf, exp_valid;
  int           errors;

  // ---------------------------------------------------------------------------
  // Exact-math saturate/wrap helper for reference tasks below.
  //
  // BUGFIX: the reference tasks in this file previously computed the
  // conditional negate (`xm = sigma ? x_sh : -x_sh;`) the same way the
  // pre-fix RTL did -- as a WIDTH-bit unary negation BEFORE widening. For
  // x_sh/y_sh == MIN_NEG this silently wrapped back to MIN_NEG instead of
  // +32768, corrupting the "expected" value itself (independent of whether
  // the DUT was correct). This produced a false failure on T9 below: the
  // reference computed exp_x=32767 (from a corrupted MIN_NEG negation) while
  // the (correctly fixed) DUT produced the true mathematically-exact result
  // x_out=-32768. Fixed by computing the full-precision sum in `longint`
  // (no WIDTH-bit intermediate can ever overflow 64 bits here), matching
  // the RTL's own fix of never negating a WIDTH-bit operand in isolation.
  task automatic sat_result(
    input  longint      full,
    input  logic        sat_mode,
    output cordic_data_t r,
    output logic         ovf
  );
    ovf = (full > longint'(MAX_POS)) || (full < longint'(MIN_NEG));
    if (sat_mode && ovf) begin
      r = (full > longint'(MAX_POS)) ? MAX_POS : MIN_NEG;
    end else begin
      r = cordic_data_t'(full);   // two's-complement wrap to WIDTH bits
    end
  endtask

  // Mirrors cordic_stage combinational logic for STAGE_IDX=0 (fixed
  // semantics: x_new = x +/- y_shifted and y_new = y +/- x_shifted with the
  // sign chosen by sigma, never by negating a WIDTH-bit shifted value).
  // asr(v, 0) = v (s<=0 early return), so shifts are identity here.
  task automatic compute_expected_0(
    input  cordic_data_t xi, yi, zi,
    input  logic         sat_mode,
    input  logic         vin,
    output cordic_data_t ex, ey, ez,
    output logic         eovf, evalid
  );
    logic    sigma;
    longint  x_sh, y_sh, x_full, y_full, z_full, angle;
    logic    ox, oy, dummy_o;
    sigma = ~zi[WIDTH-1];
    x_sh  = longint'(asr(xi, STAGE_IDX_0));   // = xi (shift=0)
    y_sh  = longint'(asr(yi, STAGE_IDX_0));   // = yi
    x_full = sigma ? (longint'(xi) - y_sh) : (longint'(xi) + y_sh);
    y_full = sigma ? (longint'(yi) + x_sh) : (longint'(yi) - x_sh);
    sat_result(x_full, sat_mode, ex, ox);
    sat_result(y_full, sat_mode, ey, oy);
    angle  = longint'(STAGE_ANGLE_0);
    z_full = sigma ? (longint'(zi) - angle) : (longint'(zi) + angle);
    sat_result(z_full, 1'b0, ez, dummy_o);   // z always wraps
    eovf   = ox | oy;
    evalid = vin;
  endtask

  // Mirrors cordic_stage combinational logic for STAGE_IDX=1 (see
  // compute_expected_0 for the fixed-semantics rationale).
  task automatic compute_expected_1(
    input  cordic_data_t xi, yi, zi,
    input  logic         sat_mode,
    input  logic         vin,
    output cordic_data_t ex, ey, ez,
    output logic         eovf, evalid
  );
    logic    sigma;
    longint  x_sh, y_sh, x_full, y_full, z_full, angle;
    logic    ox, oy, dummy_o;
    sigma = ~zi[WIDTH-1];
    x_sh  = longint'(asr(xi, STAGE_IDX_1));   // shift by 1
    y_sh  = longint'(asr(yi, STAGE_IDX_1));   // shift by 1
    x_full = sigma ? (longint'(xi) - y_sh) : (longint'(xi) + y_sh);
    y_full = sigma ? (longint'(yi) + x_sh) : (longint'(yi) - x_sh);
    sat_result(x_full, sat_mode, ex, ox);
    sat_result(y_full, sat_mode, ey, oy);
    angle  = longint'(STAGE_ANGLE_1);
    z_full = sigma ? (longint'(zi) - angle) : (longint'(zi) + angle);
    sat_result(z_full, 1'b0, ez, dummy_o);   // z always wraps
    eovf   = ox | oy;
    evalid = vin;
  endtask

  task automatic chk_stage_0(input string label);
    if (x_out !== exp_x) begin
      $error("[cordic_stage] %s: x_out=%0d exp=%0d", label, x_out, exp_x); errors++;
    end
    if (y_out !== exp_y) begin
      $error("[cordic_stage] %s: y_out=%0d exp=%0d", label, y_out, exp_y); errors++;
    end
    if (z_out !== exp_z) begin
      $error("[cordic_stage] %s: z_out=%0d exp=%0d", label, z_out, exp_z); errors++;
    end
    if (overflow !== exp_ovf) begin
      $error("[cordic_stage] %s: overflow=%0b exp=%0b", label, overflow, exp_ovf); errors++;
    end
    if (valid_out !== exp_valid) begin
      $error("[cordic_stage] %s: valid_out=%0b exp=%0b", label, valid_out, exp_valid); errors++;
    end
  endtask

  task automatic chk_stage_1(input string label);
    if (x_out_1 !== exp_x) begin
      $error("[cordic_stage] %s: x_out=%0d exp=%0d", label, x_out_1, exp_x); errors++;
    end
    if (y_out_1 !== exp_y) begin
      $error("[cordic_stage] %s: y_out=%0d exp=%0d", label, y_out_1, exp_y); errors++;
    end
    if (z_out_1 !== exp_z) begin
      $error("[cordic_stage] %s: z_out=%0d exp=%0d", label, z_out_1, exp_z); errors++;
    end
    if (overflow_1 !== exp_ovf) begin
      $error("[cordic_stage] %s: overflow=%0b exp=%0b", label, overflow_1, exp_ovf); errors++;
    end
    if (valid_out_1 !== exp_valid) begin
      $error("[cordic_stage] %s: valid_out=%0b exp=%0b", label, valid_out_1, exp_valid); errors++;
    end
  endtask

  // ---------------------------------------------------------------------------
  // 8-stage pipeline chain (STG_003) — real generate-based DUT chain, checked
  // end-to-end against a software reference that mirrors golden_model.py's
  // cordic_rotation() exactly, stage by stage.
  // ---------------------------------------------------------------------------
  localparam int NSTAGES = 8;

  cordic_data_t chain_x [0:NSTAGES];
  cordic_data_t chain_y [0:NSTAGES];
  cordic_data_t chain_z [0:NSTAGES];
  logic         chain_valid [0:NSTAGES];
  logic         chain_ovf   [0:NSTAGES];
  logic         chain_sat;

  genvar gi;
  generate
    for (gi = 0; gi < NSTAGES; gi++) begin : g_chain_stage
      cordic_stage #(
        .WIDTH    (WIDTH),
        .FRACT_W  (FRACT_W),
        .STAGE_IDX(gi)
      ) dut_chain (
        .clk      (clk),
        .rst_n    (rst_n),
        .active_x (1'b1),
        .active_y (1'b1),
        .active_z (1'b1),
        .x_in     (chain_x[gi]),
        .y_in     (chain_y[gi]),
        .z_in     (chain_z[gi]),
        .valid_in (chain_valid[gi]),
        .sat      (chain_sat),
        .x_out    (chain_x[gi+1]),
        .y_out    (chain_y[gi+1]),
        .z_out    (chain_z[gi+1]),
        .valid_out(chain_valid[gi+1]),
        .overflow (chain_ovf[gi+1])
      );
    end
  endgenerate

  // Software reference for the same 8-stage chain (pure combinational
  // unroll, no clocking) — mirrors golden_model.py's cordic_rotation().
  // Uses the same exact-math (longint) approach as compute_expected_0/1
  // above -- see the BUGFIX note there; a WIDTH-bit conditional negate here
  // would reintroduce the same false-failure risk at MIN_NEG.
  task automatic compute_chain_expected(
    input  cordic_data_t xi, yi, zi,
    input  logic         sat_mode,
    output cordic_data_t ex, ey, ez,
    output logic         eovf
  );
    cordic_data_t xv, yv, zv;
    logic         sigma;
    longint       x_sh, y_sh, x_full, y_full, z_full, angle;
    logic         ox, oy, dummy_o, ovf_last;
    int i;
    xv = xi; yv = yi; zv = zi; ovf_last = 1'b0;
    for (i = 0; i < NSTAGES; i++) begin
      sigma = ~zv[WIDTH-1];
      case (i)
        0: angle = longint'(STAGE_ANGLE_0);
        1: angle = longint'(STAGE_ANGLE_1);
        2: angle = longint'(STAGE_ANGLE_2);
        3: angle = longint'(STAGE_ANGLE_3);
        4: angle = longint'(STAGE_ANGLE_4);
        5: angle = longint'(STAGE_ANGLE_5);
        6: angle = longint'(STAGE_ANGLE_6);
        default: angle = longint'(STAGE_ANGLE_7);
      endcase
      x_sh = longint'(asr(xv, i));
      y_sh = longint'(asr(yv, i));
      x_full = sigma ? (longint'(xv) - y_sh) : (longint'(xv) + y_sh);
      y_full = sigma ? (longint'(yv) + x_sh) : (longint'(yv) - x_sh);
      sat_result(x_full, sat_mode, xv, ox);
      sat_result(y_full, sat_mode, yv, oy);
      z_full = sigma ? (longint'(zv) - angle) : (longint'(zv) + angle);
      sat_result(z_full, 1'b0, zv, dummy_o);
      ovf_last = ox | oy;
    end
    ex = xv; ey = yv; ez = zv; eovf = ovf_last;
  endtask

  // Drive one vector through the full 8-stage chain and check the final
  // stage's output NSTAGES cycles later.
  task automatic run_chain_vector(
    input cordic_data_t xi, yi, zi,
    input logic         sat_mode,
    input string        label
  );
    cordic_data_t exp_cx, exp_cy, exp_cz;
    logic         exp_covf;
    int k;
    compute_chain_expected(xi, yi, zi, sat_mode, exp_cx, exp_cy, exp_cz, exp_covf);

    @(negedge clk);
    chain_x[0]     = xi;
    chain_y[0]     = yi;
    chain_z[0]     = zi;
    chain_valid[0] = 1'b1;
    chain_sat      = sat_mode;

    @(posedge clk); @(negedge clk);
    chain_valid[0] = 1'b0;  // single pulse; let it drain through the pipe

    for (k = 0; k < NSTAGES - 1; k++) begin
      @(posedge clk); @(negedge clk);
    end

    if (chain_valid[NSTAGES] !== 1'b1) begin
      $error("[cordic_stage] %s: chain valid_out did not assert after %0d cycles", label, NSTAGES);
      errors++;
    end
    if (chain_x[NSTAGES] !== exp_cx) begin
      $error("[cordic_stage] %s: chain x_out=%0d exp=%0d", label, chain_x[NSTAGES], exp_cx); errors++;
    end
    if (chain_y[NSTAGES] !== exp_cy) begin
      $error("[cordic_stage] %s: chain y_out=%0d exp=%0d", label, chain_y[NSTAGES], exp_cy); errors++;
    end
    if (chain_z[NSTAGES] !== exp_cz) begin
      $error("[cordic_stage] %s: chain z_out=%0d exp=%0d", label, chain_z[NSTAGES], exp_cz); errors++;
    end
    if (chain_ovf[NSTAGES] !== exp_covf) begin
      $error("[cordic_stage] %s: chain overflow=%0b exp=%0b", label, chain_ovf[NSTAGES], exp_covf); errors++;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Test body
  // ---------------------------------------------------------------------------
  initial begin
    errors   = 0;
    x_in     = '0; y_in = '0; z_in = '0;
    valid_in = 1'b0; sat = 1'b1;
    chain_x[0] = '0; chain_y[0] = '0; chain_z[0] = '0;
    chain_valid[0] = 1'b0; chain_sat = 1'b1;

    // Reset
    rst_n = 1'b0;
    @(posedge clk); @(negedge clk);
    if (x_out !== '0 || y_out !== '0 || z_out !== '0 || valid_out !== 1'b0 || overflow !== 1'b0) begin
      $error("[cordic_stage] reset: outputs not cleared"); errors++;
    end
    rst_n = 1'b1;

    // ---- Test 1: positive z (sigma=1), no overflow ----
    // x=1000, y=500, z=3217 → x_new=500, y_new=1500, z_new=0, ovf=0
    @(negedge clk);
    x_in = 16'sd1000; y_in = 16'sd500; z_in = 16'sd3217;
    sat = 1'b1; valid_in = 1'b1;
    compute_expected_0(x_in, y_in, z_in, sat, valid_in,
                        exp_x, exp_y, exp_z, exp_ovf, exp_valid);
    @(posedge clk); @(negedge clk);
    chk_stage_0("T1:sigma=1_no_ovf");

    // ---- Test 2: negative z (sigma=0), no overflow ----
    // x=1000, y=500, z=-1 → x_new=1500, y_new=-500, z_new=3216, ovf=0
    @(negedge clk);
    x_in = 16'sd1000; y_in = 16'sd500; z_in = -16'sd1;
    sat = 1'b1; valid_in = 1'b1;
    compute_expected_0(x_in, y_in, z_in, sat, valid_in,
                        exp_x, exp_y, exp_z, exp_ovf, exp_valid);
    @(posedge clk); @(negedge clk);
    chk_stage_0("T2:sigma=0_no_ovf");

    // ---- Test 3: positive z, y-path saturates ----
    // x=30000, y=5000, z=100 → y_new=35000 → MAX_POS, ovf=1
    @(negedge clk);
    x_in = 16'sd30000; y_in = 16'sd5000; z_in = 16'sd100;
    sat = 1'b1; valid_in = 1'b1;
    compute_expected_0(x_in, y_in, z_in, sat, valid_in,
                        exp_x, exp_y, exp_z, exp_ovf, exp_valid);
    @(posedge clk); @(negedge clk);
    chk_stage_0("T3:y_saturates");

    // ---- Test 4: valid_in=0 propagates as valid_out=0 ----
    @(negedge clk);
    x_in = 16'sd100; y_in = 16'sd200; z_in = 16'sd50;
    sat = 1'b1; valid_in = 1'b0;
    compute_expected_0(x_in, y_in, z_in, sat, valid_in,
                        exp_x, exp_y, exp_z, exp_ovf, exp_valid);
    @(posedge clk); @(negedge clk);
    chk_stage_0("T4:valid_in=0");

    // ---- Test 5: reset mid-stream clears outputs ----
    @(negedge clk);
    x_in = 16'sd5000; y_in = 16'sd3000; z_in = 16'sd2000;
    sat = 1'b1; valid_in = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rst_n = 1'b0;
    @(posedge clk); @(negedge clk);
    if (x_out !== '0 || y_out !== '0 || z_out !== '0 || valid_out !== 1'b0 || overflow !== 1'b0) begin
      $error("[cordic_stage] T5:mid_reset: outputs not cleared after rst_n=0"); errors++;
    end
    rst_n = 1'b1;

    // ---- STAGE_IDX=1 checks (dut_1), shift=1 ----
    @(negedge clk);
    x_in = 16'sd1000; y_in = 16'sd500; z_in = 16'sd1899;
    sat = 1'b1; valid_in = 1'b1;
    compute_expected_1(x_in, y_in, z_in, sat, valid_in,
                        exp_x, exp_y, exp_z, exp_ovf, exp_valid);
    @(posedge clk); @(negedge clk);
    chk_stage_1("T6:stage1_sigma=1");

    @(negedge clk);
    x_in = -16'sd1000; y_in = 16'sd500; z_in = -16'sd10;
    sat = 1'b0; valid_in = 1'b1;
    compute_expected_1(x_in, y_in, z_in, sat, valid_in,
                        exp_x, exp_y, exp_z, exp_ovf, exp_valid);
    @(posedge clk); @(negedge clk);
    chk_stage_1("T7:stage1_sigma=0_wrap");

    // ---------------------------------------------------------------------
    // MIN_NEG directed regression vectors (STAGE_IDX=0, shift=0, so
    // x_shifted/y_shifted == x_in/y_in exactly -- directly exercises the
    // fp_add_sub / cordic_stage negation-overflow bug and the asr rounding
    // path at the most-negative representable value).
    // ---------------------------------------------------------------------

    // T8: x_in = MIN_NEG, sigma=1 (z_in>=0), saturating mode.
    // x_new = x_in - y_mux = MIN_NEG - 0 = MIN_NEG (no overflow: b=0 avoids
    // the negation path entirely; sanity baseline before T9).
    @(negedge clk);
    x_in = MIN_NEG; y_in = 16'sd0; z_in = 16'sd3217;
    sat = 1'b1; valid_in = 1'b1;
    compute_expected_0(x_in, y_in, z_in, sat, valid_in,
                        exp_x, exp_y, exp_z, exp_ovf, exp_valid);
    @(posedge clk); @(negedge clk);
    chk_stage_0("T8:x_in=MIN_NEG_sigma1_sat");

    // T9: y_in = MIN_NEG, sigma=0 (z_in<0). Old (buggy) RTL/reference math
    // negated y_shifted=MIN_NEG at WIDTH-bit width, silently wrapping it
    // back to MIN_NEG and corrupting the result. Correct math (matching the
    // fix): x_new = x_in + y_shifted = 0 + MIN_NEG = MIN_NEG exactly -- this
    // lands exactly ON the MIN_NEG boundary, which is representable and
    // does NOT overflow. This vector's value is important precisely because
    // it is easy to mis-derive (as an earlier draft of this test did) as
    // "must saturate" when it in fact must not.
    @(negedge clk);
    x_in = 16'sd0; y_in = MIN_NEG; z_in = -16'sd1;
    sat = 1'b1; valid_in = 1'b1;
    compute_expected_0(x_in, y_in, z_in, sat, valid_in,
                        exp_x, exp_y, exp_z, exp_ovf, exp_valid);
    @(posedge clk); @(negedge clk);
    chk_stage_0("T9:y_in=MIN_NEG_sigma0_sat_boundary_no_ovf");

    // T10: same as T9 but wrap mode -- verifies the correctly-wrapped value
    // (not just a saturate-detection sanity check).
    @(negedge clk);
    x_in = 16'sd0; y_in = MIN_NEG; z_in = -16'sd1;
    sat = 1'b0; valid_in = 1'b1;
    compute_expected_0(x_in, y_in, z_in, sat, valid_in,
                        exp_x, exp_y, exp_z, exp_ovf, exp_valid);
    @(posedge clk); @(negedge clk);
    chk_stage_0("T10:y_in=MIN_NEG_sigma0_wrap");

    // T11: x_in = MIN_NEG, sigma=0. x_new = x_in + y_shifted = MIN_NEG + 0 =
    // MIN_NEG (boundary, no overflow, same as T9). But y_new = y_in -
    // x_shifted = 0 - MIN_NEG = 0 - (-32768) = +32768, which genuinely
    // exceeds MAX_POS (32767) -- this IS a real saturating case on the
    // y-path, exercising the fp_add_sub fix (subtracting b==MIN_NEG) via
    // cordic_stage's op-based y-adder.
    @(negedge clk);
    x_in = MIN_NEG; y_in = 16'sd0; z_in = -16'sd1;
    sat = 1'b1; valid_in = 1'b1;
    compute_expected_0(x_in, y_in, z_in, sat, valid_in,
                        exp_x, exp_y, exp_z, exp_ovf, exp_valid);
    @(posedge clk); @(negedge clk);
    chk_stage_0("T11:x_in=MIN_NEG_sigma0_sat_y_saturates");

    @(negedge clk);
    x_in = MIN_NEG; y_in = 16'sd0; z_in = -16'sd1;
    sat = 1'b0; valid_in = 1'b1;
    compute_expected_0(x_in, y_in, z_in, sat, valid_in,
                        exp_x, exp_y, exp_z, exp_ovf, exp_valid);
    @(posedge clk); @(negedge clk);
    chk_stage_0("T12:x_in=MIN_NEG_sigma0_wrap_y_ovf_flag");

    // T13: both x_in and y_in = MIN_NEG simultaneously, sigma=1.
    @(negedge clk);
    x_in = MIN_NEG; y_in = MIN_NEG; z_in = 16'sd3217;
    sat = 1'b1; valid_in = 1'b1;
    compute_expected_0(x_in, y_in, z_in, sat, valid_in,
                        exp_x, exp_y, exp_z, exp_ovf, exp_valid);
    @(posedge clk); @(negedge clk);
    chk_stage_0("T13:x_and_y_MIN_NEG_sigma1_sat");

    // ---------------------------------------------------------------------
    // 8-stage full pipeline chain checks
    // ---------------------------------------------------------------------
    run_chain_vector(16'sd2489, 16'sd0, 16'sd0, 1'b1, "CHAIN1:x=K_unit_z0");
    run_chain_vector(16'sd2489, 16'sd0, 16'sd3217, 1'b1, "CHAIN2:x=K_unit_z45deg");
    run_chain_vector(16'sd1000, -16'sd500, -16'sd2000, 1'b1, "CHAIN3:mixed_sat");
    run_chain_vector(16'sd1000, -16'sd500, -16'sd2000, 1'b0, "CHAIN4:mixed_wrap");
    run_chain_vector(MIN_NEG, 16'sd0, 16'sd0, 1'b1, "CHAIN5:x=MIN_NEG_sat");
    run_chain_vector(16'sd0, MIN_NEG, -16'sd1, 1'b1, "CHAIN6:y=MIN_NEG_sat");
    run_chain_vector(MIN_NEG, MIN_NEG, 16'sd1000, 1'b0, "CHAIN7:xy=MIN_NEG_wrap");

    if (errors != 0) $fatal(1, "FAIL: cordic_stage — %0d error(s)", errors);
    else        $display("PASS: cordic_stage");

    $finish;
  end

endmodule
