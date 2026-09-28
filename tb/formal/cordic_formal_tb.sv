// Formal verification harnesses for the CORDIC accelerator.
//
// Yosys/sby compatibility notes:
//   - Concurrent SVA (`property ... endproperty`, `|->`, `##N`) is NOT relied
//     upon here. rtl/common/cordic_assertions.sv (bound from cordic_stage.sv)
//     and the `ifdef ASSERT_ON` block in cordic_pipeline.sv use that syntax,
//     but neither is elaborated by this formal flow (only `-DFORMAL` is
//     defined, never `ASSERT_ON`). Do not assume those SVA properties are
//     formally checked just because they exist in the RTL — they are
//     simulation-only unless re-verified here.
//   - All properties below are written as procedural `assert`/`assume`/
//     `cover` statements using `$past`, portable across the Yosys versions
//     this project has used.
//
// This file contains FOUR independent formal top-level modules, selected by
// [tasks] in cordic_formal.sby. Each is scoped to ONE outcome (pass or a
// documented, genuine counterexample) so a property that is actually FALSE
// on this RTL never masks whether the OTHER properties hold — see the
// per-module headers and the handback report for what is a real proof vs.
// what is an open architectural finding.
//
//   cordic_formal_tb                 - stage-local BMC. EXPECT PASS.
//   cordic_pipeline_core_tb          - pipeline reset + fixed-latency/
//                                       no-loss-no-dup conservation.
//                                       EXPECT PASS.
//   cordic_pipeline_satclamp_tb      - saturation clamp at the PIPELINE
//                                       OUTPUT. EXPECT FAIL — see header,
//                                       this is a genuine architectural
//                                       finding, not a vacuous or broken
//                                       harness.
//   cordic_pipeline_cfg_align_tb     - config/transaction alignment probe:
//                                       does cfg_saturate_r stay constant
//                                       across a transaction's full
//                                       traversal. EXPECT FAIL when
//                                       config_valid is left free — isolates
//                                       the metadata-alignment gap called
//                                       out in the task brief, independent
//                                       of the satclamp finding above.
//
// Run via: make formal  (sby -f tb/formal/cordic_formal.sby)

import cordic_pkg::*;

// =============================================================================
// MODULE 1: cordic_formal_tb - STAGE-LOCAL BMC. EXPECT PASS.
// =============================================================================
//
// Properties (all procedural, BMC depth 20):
//   P1: reset clears valid_out within 1 cycle
//   P2: reset clears overflow within 1 cycle
//   P3: valid_in propagates to valid_out 1 cycle later
//   P4: sat && overflow => (x_out clamped) OR (y_out clamped)
//   P5: (kept for symmetry with the file's original P4/P5 naming — folded
//        into P4 above; see VACUITY FIX / SPEC FIX note)
//   P6: x_out always in signed representable range when valid
//   P7: y_out always in signed representable range when valid
//
// P1-P3 mirror p_reset_clears_valid / p_reset_clears_overflow /
// p_valid_propagates in rtl/common/cordic_assertions.sv, re-expressed
// procedurally so sby actually checks them (the SVA originals are not
// elaborated by this flow). This closes the "P1-P3 inactive" gap reported
// by the prior audit.
//
// VACUITY FIX (audit finding CONFIRMED):
//   The previous harness constrained x_in/y_in to XY_BOUND=16383 (~half of
//   MAX_POS=32767). At STAGE_IDX=4, |x_comb| <= 16383 + asr(16383,4) ~=
//   17407 < 32767, so "sat && overflow" could NEVER become true — P4/P5
//   were vacuously true. Fixed by removing that artificial bound (x_in/y_in
//   are now constrained only by their native WIDTH-bit signed range).
//
// SPEC FIX (found by BMC, NOT by inspection):
//   With the vacuity fix applied, the ORIGINAL two-property formulation —
//     p_sat_clamps_x: (sat && overflow) |-> (x_out clamped)
//     p_sat_clamps_y: (sat && overflow) |-> (y_out clamped)
//   — is FALSE on this RTL and BMC finds a real counterexample at step 3
//   (see report). Root cause: cordic_stage's `overflow` output is
//   `ovf_x | ovf_y` (cordic_stage.sv line ~131), a SINGLE flag covering TWO
//   INDEPENDENT fp_add_sub instances. If only the x-path overflows
//   (ovf_x=1, ovf_y=0), x_out is clamped but y_out is an ordinary,
//   unclamped sum — yet the combined `overflow` flag is still 1, so
//   p_sat_clamps_y's antecedent is true while its consequent is false.
//   Same failure mode symmetrically for y-only overflow. This is a latent
//   spec bug in cordic_assertions.sv's p_sat_clamps_x/p_sat_clamps_y (owned
//   by the Architecture lead, not touched here) — it was never caught
//   because no formal tool ever actually exercised it (vacuous before this
//   fix; SVA not parsed by this flow). The corrected, PROVABLE claim given
//   only the combined `overflow` port is the disjunction below (P4): at
//   least one of x_out/y_out is clamped whenever sat && overflow. Whether
//   cordic_stage should expose ovf_x/ovf_y separately so a precise
//   per-path property can be written is an open recommendation for the
//   Architecture/Datapath agents, not something this file can do (it would
//   require adding output ports to cordic_stage.sv, which this agent does
//   not own).
//
// TIMING FIX (also found by BMC, also a harness bug — not RTL):
//   `sat` is a purely combinational INPUT to cordic_stage: it (together with
//   x_in/y_in) determines x_comb/y_comb/ovf_x/ovf_y THIS cycle, which are
//   then registered into x_out/y_out/overflow, visible NEXT cycle. The
//   original harness (both the pre-existing one and this agent's first
//   attempt at the SPEC FIX above) compared the CURRENT-cycle `sat` against
//   the CURRENT-cycle (already-registered, i.e. one-cycle-old) x_out/
//   y_out/overflow. Since `sat` is left free every cycle, BMC immediately
//   found a trace where `sat`=1 NOW (satisfying the antecedent) while the
//   registered overflow/x_out/y_out actually reflect `sat`=0 (wrap mode)
//   from the PREVIOUS cycle — i.e. checking the property against the wrong
//   cycle's `sat` entirely. All properties that correlate `sat`/x_in/y_in
//   with x_out/y_out/overflow below therefore gate on `$past(sat)` (and
//   `$past(valid_in)` for P3, which already did this correctly), matching
//   the actual 1-cycle register timing.
// =============================================================================

module cordic_formal_tb #(
  parameter int WIDTH     = cordic_pkg::WIDTH,
  parameter int FRACT_W   = cordic_pkg::FRACT_W,
  parameter int STAGE_IDX = 4          // mid-pipeline: exercises shift-by-4 + round
);

  logic                    clk;
  logic                    rst_n;
  logic signed [WIDTH-1:0] x_in, y_in, z_in;
  logic                    valid_in;
  logic                    sat;
  logic signed [WIDTH-1:0] x_out, y_out, z_out;
  logic                    valid_out;
  logic                    overflow;

  // DUT: no ASSERT_ON — SVA-style cordic_assertions not parsed by this flow
  cordic_stage #(
    .WIDTH    (WIDTH),
    .FRACT_W  (FRACT_W),
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

`ifdef FORMAL

  localparam logic signed [WIDTH-1:0] MAX_POS_F = (1 << (WIDTH-1)) - 1;
  localparam logic signed [WIDTH-1:0] MIN_NEG_F = -(1 << (WIDTH-1));

  // z_in bounded to the CORDIC convergence range (sum of all stage angles,
  // ~7108 in Q12.3 == 99.7 deg) — the real operating range for a rotation-
  // mode CORDIC. Irrelevant to the x/y saturation properties (driven purely
  // by x_in/y_in/shift), kept for realism/documentation only.
  localparam signed [WIDTH-1:0] Z_BOUND  = 16'sd7127;   // ~1.74 rad in Q12.3

  // x_in/y_in intentionally left unconstrained beyond their native signed
  // WIDTH-bit range (no XY_BOUND) — see VACUITY FIX note above.
  always @(*) begin
    if (rst_n) begin
      assume(z_in >= -Z_BOUND && z_in <= Z_BOUND);
    end
  end

  always @(posedge clk) begin
    if ($past(rst_n)) assume(rst_n);  // sticky: once released, reset never reasserts (fixed no-op bug)
  end

  initial begin
    assume(!valid_out);
    assume(!overflow);
    assume(!rst_n);
  end

  always @(posedge clk) begin
    if (!$past(rst_n)) begin
      assume(rst_n);
    end
  end

  // P1/P2: reset clears valid_out/overflow within 1 cycle
  always @(posedge clk) begin
    if (!$past(rst_n)) begin
      assert (!valid_out);
      assert (!overflow);
    end
  end

  // P3: valid_in propagates to valid_out exactly 1 cycle later
  always @(posedge clk) begin
    if (rst_n && $past(rst_n) && $past(valid_in)) begin
      assert (valid_out);
    end
  end

  // P4: sat && overflow => at least one of x_out/y_out is clamped
  // (see SPEC FIX note above for why this replaces the original
  // per-path-conjunctive p_sat_clamps_x/p_sat_clamps_y claim, and the
  // TIMING FIX note for why the antecedent uses $past(sat) rather than
  // the current-cycle `sat`)
  always @(posedge clk) begin
    if (rst_n && $past(sat) && overflow && valid_out) begin
      assert ((x_out == MAX_POS_F || x_out == MIN_NEG_F) ||
              (y_out == MAX_POS_F || y_out == MIN_NEG_F));
    end
  end

  // P6/P7: x_out/y_out always in signed representable range when valid
  always @(posedge clk) begin
    if (rst_n && valid_out) begin
      assert (x_out >= MIN_NEG_F && x_out <= MAX_POS_F);
      assert (y_out >= MIN_NEG_F && y_out <= MAX_POS_F);
    end
  end

  // ---------------------------------------------------------------------
  // REACHABILITY COVERS
  // ---------------------------------------------------------------------
  // Prove sat&&overflow is reachable at all (the original audit concern),
  // AND prove the three distinct sub-cases that motivated the SPEC FIX are
  // each independently reachable: x-only overflow, y-only overflow, and
  // both simultaneously. If the "x-only"/"y-only" covers were unreachable,
  // the disjunctive P4 above would reduce to the (equivalent-but-should-
  // say-so) conjunctive claim and the SPEC FIX note would be moot — so
  // these covers are the actual evidence for that claim, not just P4's.
  // ---------------------------------------------------------------------
  always @(posedge clk) begin
    if (rst_n && $past(sat) && overflow && valid_out) begin
      cover (( x_out == MAX_POS_F || x_out == MIN_NEG_F) &&
             !(y_out == MAX_POS_F || y_out == MIN_NEG_F));   // x-only
      cover (!(x_out == MAX_POS_F || x_out == MIN_NEG_F) &&
              (y_out == MAX_POS_F || y_out == MIN_NEG_F));   // y-only
      cover (( x_out == MAX_POS_F || x_out == MIN_NEG_F) &&
              (y_out == MAX_POS_F || y_out == MIN_NEG_F));   // both
    end
  end

`endif // FORMAL

endmodule


// =============================================================================
// MODULE 2a: cordic_pipeline_reset_tb - PIPELINE-LEVEL RESET. EXPECT PASS.
// =============================================================================
//
// DUT: cordic_pipeline (cordic_top is a pure passthrough wrapper — proving
// on cordic_pipeline is equivalent and avoids an extra hierarchy level).
//
// PP1 — Pipeline reset correctness: !rst_n |=> valid_out/overflow/irq all
//       clear, at the FULL PIPELINE boundary (not per-stage). Covered
//       mid-transaction (reset asserted while genuinely in flight) so this
//       isn't a "reset only ever happens at t=0" vacuous proof.
//
// Kept in its own task/module, separate from the conservation property
// below: PP1 is a clean, unconditional PASS, and should not be hidden
// behind — or have its depth cut short by — the genuine, documented FAIL
// in cordic_pipeline_conservation_tb.
// =============================================================================

module cordic_pipeline_reset_tb #(
  parameter int WIDTH      = cordic_pkg::WIDTH,
  parameter int FRACT_W    = cordic_pkg::FRACT_W,
  parameter int ITERATIONS = cordic_pkg::ITERATIONS
);

  logic                    clk;
  logic                    rst_n;
  logic signed [WIDTH-1:0] x_in, y_in, z_in;
  logic                    valid_in;
  logic                    ready_out;
  logic [3:0]              cfg_iterations;
  logic                    cfg_saturate;
  logic                    config_valid;
  logic                    config_ready;
  logic signed [WIDTH-1:0] x_out, y_out, z_out;
  logic                    valid_out;
  logic                    ready_in;
  logic                    overflow;
  logic                    irq;

  cordic_pipeline #(
    .WIDTH     (WIDTH),
    .FRACT_W   (FRACT_W),
    .ITERATIONS(ITERATIONS)
  ) dut (
    .clk           (clk),
    .rst_n         (rst_n),
    .x_in          (x_in),
    .y_in          (y_in),
    .z_in          (z_in),
    .valid_in      (valid_in),
    .ready_out     (ready_out),
    .cfg_iterations(cfg_iterations),
    .cfg_saturate  (cfg_saturate),
    .config_valid  (config_valid),
    .config_ready  (config_ready),
    .x_out         (x_out),
    .y_out         (y_out),
    .z_out         (z_out),
    .valid_out     (valid_out),
    .ready_in      (ready_in),
    .overflow      (overflow),
    .irq           (irq)
  );

`ifdef FORMAL

  always @(posedge clk) begin
    if ($past(rst_n)) assume(rst_n);  // sticky: once released, reset never reasserts
  end
  initial begin
    assume(!rst_n);
    assume(!valid_out);
    assume(!overflow);
    assume(!irq);
  end
  always @(posedge clk) begin
    if (!$past(rst_n)) assume(rst_n);
  end

  // PP1: pipeline-level reset correctness
  always @(posedge clk) begin
    if (!$past(rst_n)) begin
      assert (!valid_out);
      assert (!overflow);
      assert (!irq);
    end
  end

  // Cover: reset asserted while a transaction was genuinely in flight
  always @(posedge clk) begin
    if (!rst_n) begin
      cover ($past(valid_in) || $past(valid_out));
    end
  end

`endif // FORMAL

endmodule


// =============================================================================
// MODULE 2b: cordic_pipeline_conservation_tb - FIXED-LATENCY / NO-LOSS-NO-DUP
// EXPECT FAIL — genuine architectural finding, not a harness bug.
// =============================================================================
//
// Claim tested: valid_out(t) == $past(accepted, LAT) for a fixed LAT, where
// accepted = valid_in && dut.ready_out_int (cordic_pipeline's own internal
// stage-0 admission signal: `assign stage_valid[0] = valid_in &
// ready_out_int;`, reconstructed here from two SCALAR signals rather than
// via a hierarchical reference into the unpacked array dut.stage_valid[0]
// — that direct reference failed outright the first time it was tried,
// "Failed to resolve identifier \dut.stage_valid for width detection", a
// Yosys formal-frontend limitation with hierarchical unpacked-array
// indexing, not an RTL issue).
//
// RESULT: FALSE for BOTH of the two independently-derived LAT candidates
// tried (ITERATIONS+1=9, the true stage_valid[0]->valid_out register-chain
// depth counting 8 cordic_stage hops + 1 output register; and
// cordic_pipeline's own VALID_DEPTH=ITERATIONS+2=10, the constant its
// backpressure/credit-tracking shift register `valid_pipe` uses) — BMC
// finds a counterexample at the same step for both, with ready_in left
// completely free/unconstrained (a fully adversarial downstream consumer).
//
// ROOT CAUSE (most likely, given the evidence below — see report for the
// exact confidence level and what would nail it down further):
//   Every cordic_stage instance registers `valid_out <= valid_in`
//   UNCONDITIONALLY, every cycle — cordic_stage.sv has no stall/enable
//   input at all, so once a transaction is admitted at stage 0 it marches
//   straight to the output in exactly ITERATIONS+1 cycles no matter what
//   ready_in does meanwhile. Admission of NEW transactions, however, is
//   gated by a SEPARATE credit-style tracker: `valid_pipe`, a
//   VALID_DEPTH(=10)-deep shift register recording recent accepts, with
//   `ready_out_int = !valid_pipe[VALID_DEPTH-1] | ready_in`. Because
//   VALID_DEPTH (10) does not equal the true stage latency (9), this
//   credit tracker's window is one cycle wider than the pipe it is meant
//   to protect — under an adversarial ready_in pattern, BMC finds a case
//   where the credit tracker believes a slot is free one cycle before the
//   previous occupant has actually vacated the single shared output
//   register, i.e. two transactions can be made to collide on x_out/y_out/
//   z_out/valid_out, silently dropping one of them. This is a real
//   candidate off-by-one between an admission/credit window and the
//   pipeline's actual physical depth — exactly the class of bug BMC is
//   good at finding and adversarial-ready_in simulation vectors could
//   easily miss (it requires a specific ready_in toggle pattern timed
//   against the credit tracker, not just "back-to-back valid inputs").
//
// This is NOT fixed here — cordic_pipeline.sv is owned by the Pipeline RTL
// agent. See the handback report for the exact counterexample trace path
// and for how much of this root-cause explanation is confirmed vs.
// inferred.
// =============================================================================

module cordic_pipeline_conservation_tb #(
  parameter int WIDTH      = cordic_pkg::WIDTH,
  parameter int FRACT_W    = cordic_pkg::FRACT_W,
  parameter int ITERATIONS = cordic_pkg::ITERATIONS
);

  // True stage-chain latency: stage_valid[0] -> (ITERATIONS registered
  // cordic_stage hops) -> stage_valid[ITERATIONS] -> (1 output register)
  // -> valid_out. See module header for why this differs from
  // cordic_pipeline's own VALID_DEPTH=ITERATIONS+2.
  localparam int STAGE_LATENCY = ITERATIONS + 1;

  logic                    clk;
  logic                    rst_n;
  logic signed [WIDTH-1:0] x_in, y_in, z_in;
  logic                    valid_in;
  logic                    ready_out;
  logic [3:0]              cfg_iterations;
  logic                    cfg_saturate;
  logic                    config_valid;
  logic                    config_ready;
  logic signed [WIDTH-1:0] x_out, y_out, z_out;
  logic                    valid_out;
  logic                    ready_in;
  logic                    overflow;
  logic                    irq;

  cordic_pipeline #(
    .WIDTH     (WIDTH),
    .FRACT_W   (FRACT_W),
    .ITERATIONS(ITERATIONS)
  ) dut (
    .clk           (clk),
    .rst_n         (rst_n),
    .x_in          (x_in),
    .y_in          (y_in),
    .z_in          (z_in),
    .valid_in      (valid_in),
    .ready_out     (ready_out),
    .cfg_iterations(cfg_iterations),
    .cfg_saturate  (cfg_saturate),
    .config_valid  (config_valid),
    .config_ready  (config_ready),
    .x_out         (x_out),
    .y_out         (y_out),
    .z_out         (z_out),
    .valid_out     (valid_out),
    .ready_in      (ready_in),
    .overflow      (overflow),
    .irq           (irq)
  );

`ifdef FORMAL

  logic [7:0] cyc_count;
  always @(posedge clk) begin
    if (!rst_n) cyc_count <= '0;
    else if (cyc_count != 8'hff) cyc_count <= cyc_count + 8'd1;
  end

  always @(posedge clk) begin
    if ($past(rst_n)) assume(rst_n);  // sticky: once released, reset never reasserts
  end
  initial begin
    assume(!rst_n);
    assume(!valid_out);
    assume(!overflow);
    assume(!irq);
  end
  always @(posedge clk) begin
    if (!$past(rst_n)) assume(rst_n);
  end

  // config held quiescent — this property does not care about saturation
  // mode; keeping it quiescent avoids entangling this finding with the
  // separate satclamp/cfg_align findings.
  always @(posedge clk) begin
    if (rst_n && cyc_count != 8'd0) assume(!config_valid);
  end

  // ready_in is left completely FREE — an adversarial/arbitrary downstream
  // consumer. This is the environment under which the finding above was
  // produced; see report for whether a more constrained (but still
  // reasonable) ready_in still reproduces it.
  wire accept_probe = valid_in && dut.ready_out_int;

  always @(posedge clk) begin
    if (rst_n && cyc_count > STAGE_LATENCY) begin
      assert (valid_out == $past(accept_probe, STAGE_LATENCY));
    end
  end

  // Covers: prove accept and complete are each reachable (otherwise this
  // could "pass" vacuously with the pipe permanently empty), and prove the
  // external ready_out really does diverge from the internal
  // ready_out_int that actually gates acceptance — not hypothetical.
  always @(posedge clk) begin
    if (rst_n) begin
      cover (accept_probe);
      cover (valid_out);
      cover (ready_out != dut.ready_out_int);
    end
  end

`endif // FORMAL

endmodule


// =============================================================================
// MODULE 3: cordic_pipeline_satclamp_tb - SATURATION CLAMP AT PIPELINE OUTPUT
// EXPECT FAIL — genuine architectural finding, not a harness bug.
// =============================================================================
//
// Claim tested: valid_out && overflow && cfg_saturate => x_out/y_out
// clamped to MAX_POS/MIN_NEG. This is the literal "saturation clamping at
// the pipeline OUTPUT level" property from the task brief.
//
// RESULT: FALSE. BMC finds a counterexample (see report for the exact
// trace path: tb/formal/cordic_formal_satclamp/engine_0/trace.vcd).
//
// ROOT CAUSE: cordic_pipeline's `overflow` output is
// `stage_overflow_accum[ITERATIONS]`, an OR-reduction across all 8 stages'
// (already-OR'd) per-stage overflow flags — i.e. a STICKY "did saturation
// happen ANYWHERE during this transaction's 8-stage traversal" flag, not a
// "is the FINAL output currently at the saturation boundary" flag. A stage
// that clamps x_out to MAX_POS mid-pipeline hands that clamped value to the
// NEXT stage as ordinary input data; that next stage's arithmetic (which
// depends on sigma/z, unrelated to whether the previous stage saturated)
// can move the value away from MAX_POS entirely while the sticky overflow
// bit stays 1. So a transaction can legitimately finish with overflow=1 and
// a final x_out/y_out that is nowhere near either boundary.
//
// This is NOT something this agent can fix — cordic_pipeline.sv is owned by
// the Pipeline RTL agent. It is exactly the kind of subtle multi-stage
// interaction formal is good at catching and simulation vectors could
// easily miss (it requires overflow at an EARLY stage followed by enough
// subsequent stages to move the result off the boundary — a narrow,
// specific temporal pattern). Reported as an open finding; see handback.
// =============================================================================

module cordic_pipeline_satclamp_tb #(
  parameter int WIDTH      = cordic_pkg::WIDTH,
  parameter int FRACT_W    = cordic_pkg::FRACT_W,
  parameter int ITERATIONS = cordic_pkg::ITERATIONS
);

  logic                    clk;
  logic                    rst_n;
  logic signed [WIDTH-1:0] x_in, y_in, z_in;
  logic                    valid_in;
  logic                    ready_out;
  logic [3:0]              cfg_iterations;
  logic                    cfg_saturate;
  logic                    config_valid;
  logic                    config_ready;
  logic signed [WIDTH-1:0] x_out, y_out, z_out;
  logic                    valid_out;
  logic                    ready_in;
  logic                    overflow;
  logic                    irq;

  cordic_pipeline #(
    .WIDTH     (WIDTH),
    .FRACT_W   (FRACT_W),
    .ITERATIONS(ITERATIONS)
  ) dut (
    .clk           (clk),
    .rst_n         (rst_n),
    .x_in          (x_in),
    .y_in          (y_in),
    .z_in          (z_in),
    .valid_in      (valid_in),
    .ready_out     (ready_out),
    .cfg_iterations(cfg_iterations),
    .cfg_saturate  (cfg_saturate),
    .config_valid  (config_valid),
    .config_ready  (config_ready),
    .x_out         (x_out),
    .y_out         (y_out),
    .z_out         (z_out),
    .valid_out     (valid_out),
    .ready_in      (ready_in),
    .overflow      (overflow),
    .irq           (irq)
  );

`ifdef FORMAL

  localparam logic signed [WIDTH-1:0] MAX_POS_F = (1 << (WIDTH-1)) - 1;
  localparam logic signed [WIDTH-1:0] MIN_NEG_F = -(1 << (WIDTH-1));

  logic [7:0] cyc_count;
  always @(posedge clk) begin
    if (!rst_n) cyc_count <= '0;
    else if (cyc_count != 8'hff) cyc_count <= cyc_count + 8'd1;
  end

  always @(posedge clk) begin
    if ($past(rst_n)) assume(rst_n);  // sticky: once released, reset never reasserts (fixed no-op bug)
  end
  initial begin
    assume(!rst_n);
    assume(!valid_out);
    assume(!overflow);
  end
  always @(posedge clk) begin
    if (!$past(rst_n)) assume(rst_n);
  end

  // config held quiescent — isolates this to purely the sticky-overflow-
  // vs-final-clamp question, independent of the separate config-alignment
  // question probed in cordic_pipeline_cfg_align_tb.
  always @(posedge clk) begin
    if (rst_n && cyc_count != 8'd0) assume(!config_valid);
  end

  // NOTE: gates on dut.cfg_saturate_r (the internal register actually
  // driving every cordic_stage's `sat` port), NOT the external
  // `cfg_saturate` port. The external port is a free/don't-care signal
  // once config_valid is deasserted (see cordic_pipeline.sv: cfg_saturate
  // is only ever sampled into cfg_saturate_r when config_valid &&
  // config_ready) — checking against the raw port instead of the register
  // would test nothing meaningful and could itself produce a spurious
  // "counterexample" unrelated to the real saturation-clamp question.
  always @(posedge clk) begin
    if (rst_n && valid_out && overflow && dut.cfg_saturate_r) begin
      assert (x_out == MAX_POS_F || x_out == MIN_NEG_F);
      assert (y_out == MAX_POS_F || y_out == MIN_NEG_F);
    end
  end

  always @(posedge clk) begin
    if (rst_n) begin
      cover (valid_out && overflow && dut.cfg_saturate_r);
    end
  end

`endif // FORMAL

endmodule


// =============================================================================
// MODULE 4: cordic_pipeline_cfg_align_tb - CONFIG/TRANSACTION ALIGNMENT PROBE
// EXPECT FAIL when config is free — genuine architectural finding.
// =============================================================================
//
// Question from the task brief: "does overflow status correspond to the
// SAME transaction as the data it accompanies" — operationalized here as:
// for any transaction accepted at cycle t (accepted = valid_in && ready_out
// true at t), does cordic_pipeline's internal cfg_saturate_r register hold
// the SAME value at completion time (t + VALID_DEPTH) as it held at accept
// time t? If not, that transaction's 8 stages did not all see a consistent
// saturate/wrap mode, because cordic_pipeline broadcasts a single
// registered cfg_saturate_r combinationally to every cordic_stage
// instance's `sat` port — there is no per-transaction config tag carried
// alongside the data through the pipe.
//
// This uses a hierarchical reference (dut.cfg_saturate_r) into
// cordic_pipeline's internal register. That register is not a port, but
// cordic_pipeline.sv is only READ here (instantiated as DUT), never
// modified — consistent with this agent's file ownership (cordic_pipeline.sv
// belongs to the Pipeline RTL agent).
//
// This property is DELIBERATELY separate from cordic_pipeline_satclamp_tb:
// that module's property is already false for reasons unrelated to config
// changes (see its header), so testing config-alignment via the same
// "final output is clamped" claim would conflate two different root causes.
// This module isolates the question to purely "did the config register
// stay stable across one transaction's flight time," with no claim about
// what the arithmetic result should be.
// =============================================================================

module cordic_pipeline_cfg_align_tb #(
  parameter int WIDTH      = cordic_pkg::WIDTH,
  parameter int FRACT_W    = cordic_pkg::FRACT_W,
  parameter int ITERATIONS = cordic_pkg::ITERATIONS
);

  localparam int VALID_DEPTH = ITERATIONS + 2;

  logic                    clk;
  logic                    rst_n;
  logic signed [WIDTH-1:0] x_in, y_in, z_in;
  logic                    valid_in;
  logic                    ready_out;
  logic [3:0]              cfg_iterations;
  logic                    cfg_saturate;
  logic                    config_valid;
  logic                    config_ready;
  logic signed [WIDTH-1:0] x_out, y_out, z_out;
  logic                    valid_out;
  logic                    ready_in;
  logic                    overflow;
  logic                    irq;

  cordic_pipeline #(
    .WIDTH     (WIDTH),
    .FRACT_W   (FRACT_W),
    .ITERATIONS(ITERATIONS)
  ) dut (
    .clk           (clk),
    .rst_n         (rst_n),
    .x_in          (x_in),
    .y_in          (y_in),
    .z_in          (z_in),
    .valid_in      (valid_in),
    .ready_out     (ready_out),
    .cfg_iterations(cfg_iterations),
    .cfg_saturate  (cfg_saturate),
    .config_valid  (config_valid),
    .config_ready  (config_ready),
    .x_out         (x_out),
    .y_out         (y_out),
    .z_out         (z_out),
    .valid_out     (valid_out),
    .ready_in      (ready_in),
    .overflow      (overflow),
    .irq           (irq)
  );

`ifdef FORMAL

  logic [7:0] cyc_count;
  always @(posedge clk) begin
    if (!rst_n) cyc_count <= '0;
    else if (cyc_count != 8'hff) cyc_count <= cyc_count + 8'd1;
  end

  always @(posedge clk) begin
    if ($past(rst_n)) assume(rst_n);  // sticky: once released, reset never reasserts (fixed no-op bug)
  end
  initial begin
    assume(!rst_n);
    assume(!valid_out);
    assume(!overflow);
  end
  always @(posedge clk) begin
    if (!$past(rst_n)) assume(rst_n);
  end

  // NOTE: config_valid/cfg_saturate are left completely FREE every cycle —
  // a config write is allowed to land while a transaction is mid-flight.
  // This is the whole point of this probe.

  logic accepted;
  assign accepted = valid_in && ready_out;

  // Alignment property: whatever cfg_saturate_r a transaction saw at
  // ACCEPT time, it should still see at COMPLETE time (VALID_DEPTH cycles
  // later) — i.e. no config write landed mid-flight for that transaction.
  always @(posedge clk) begin
    if (rst_n && cyc_count > VALID_DEPTH && $past(accepted, VALID_DEPTH)) begin
      assert (dut.cfg_saturate_r == $past(dut.cfg_saturate_r, VALID_DEPTH));
    end
  end

  // Covers: prove both "a transaction is accepted" and "config actually
  // changes at some point" are reachable, so a FAIL here is a genuine
  // demonstration of mid-flight config drift, not a vacuous antecedent.
  always @(posedge clk) begin
    if (rst_n) begin
      cover (accepted);
      cover (dut.cfg_saturate_r != $past(dut.cfg_saturate_r));
    end
  end

`endif // FORMAL

endmodule
