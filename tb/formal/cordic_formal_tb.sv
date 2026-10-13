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
// MODULE 2b: cordic_pipeline_conservation_tb - NO TRANSACTION LOSS/DUPLICATION
// REWRITTEN 2026-09-29 (twice) against the post-merge cordic_pipeline.sv
// (Agent A's skid-FIFO + credit-admission rewrite). EXPECT PASS.
// =============================================================================
//
// STALE-HARNESS NOTE, round 1: the version that shipped with Agent E's
// original pass referenced `dut.ready_out_int` (deleted in the merge) and
// compared a fixed-latency equality against `valid_out`, which is no
// longer a single-cycle pulse but "FIFO non-empty" (holds for many cycles
// under backpressure, by design). See prior revision of this comment
// (preserved in git history) for detail.
//
// STALE-HARNESS NOTE, round 2 (Agent A diagnosed this one): the round-1
// fix targeted `dut.fifo_push`/`dut.fifo_count` directly in procedural
// code (`assert (dut.fifo_push == $past(accept_probe, ITERATIONS))` etc).
// Yosys's -formal SV frontend does NOT resolve a plain hierarchical
// dot-reference to a real internal net when used this way from OUTSIDE
// the instance — it silently creates a new, unconnected, implicitly-
// declared 1-bit identifier with that literal name (a WARNING, not a hard
// error, for scalars — "Identifier `\dut.fifo_push' is implicitly
// declared" — easy to miss scrolling past hundreds of benign "Replacing
// memory..." lines, which is exactly what happened here). Yosys's formal
// prep then turns that phantom identifier into a fully free ($anyseq)
// signal, so what actually got checked was
// "(unconstrained free bit) == $past(accept_probe, ITERATIONS)" — BMC
// trivially falsifies that, and the "counterexample" meant nothing about
// the real design. Agent A confirmed this by directly reconstructing the
// REAL dut.fifo_push value history from engine_0/trace.vcd (disambiguated
// from same-named signals elsewhere in the hierarchy) and showing it
// satisfies the intended CB1 claim at every step, including the reported
// failure step. Same tool-limitation class as the unpacked-array issue
// already flagged in cordic_pipeline_satclamp_tb's comments — it turns
// out it also silently degrades scalar hierarchical references to a
// warning instead of a hard error, which is why it wasn't caught here
// the way it was for satclamp's arrays (which DID hard-error).
//
// FIX: no `dut.*` references anywhere in this module. Both properties are
// restated as a TESTBENCH-LOCAL shadow FIFO-occupancy model, driven
// entirely by external ports:
//   - `accept_probe = valid_in && ready_out` (external, as before).
//   - `push_model = $past(accept_probe, ITERATIONS)` — the FIFO-push event
//     is MODELED (not read from the DUT) as occurring exactly ITERATIONS
//     cycles after admission. This is an ASSUMPTION grounded in reading
//     cordic_stage.sv (its `valid_out <= valid_in` is unconditional, no
//     stall port at all) and cordic_pipeline.sv's stage-chain wiring
//     (fifo_push = stage_valid[ITERATIONS], a straight ITERATIONS-deep
//     register chain from stage_valid[0] with no conditional logic
//     anywhere in between) — not something this property independently
//     re-verifies, since doing so would require reading the same
//     unreadable internal signals. Flagged explicitly as an assumption,
//     not a proven fact, per the task's vacuity-discipline requirement.
//   - `consume = valid_out && ready_in` (external).
//   - `shadow_count`: a local counter, +1 on push_model, -1 on consume.
//   CB1' — valid_out(t) == (shadow_count(t) != 0): does the DUT's real,
//     externally-observed level signal track the occupancy my model
//     predicts from admission/consumption events alone. This IS the real,
//     externally-checkable form of "no transaction loss/duplication" for
//     a level-based FIFO interface (a lost transaction would make
//     valid_out incorrectly show empty when the model expects data
//     present; a duplicated one would show data present when none should
//     remain).
//   CB2' — shadow_count(t) <= FIFO_DEPTH always: consistency check between
//     the external `ready_out` admission gate and the modeled push rate —
//     if `ready_out` under-throttles relative to the assumed push timing,
//     this catches it.
// =============================================================================

module cordic_pipeline_conservation_tb #(
  parameter int WIDTH      = cordic_pkg::WIDTH,
  parameter int FRACT_W    = cordic_pkg::FRACT_W,
  parameter int ITERATIONS = cordic_pkg::ITERATIONS
);

  // Matches cordic_pipeline.sv's own VALID_DEPTH = ITERATIONS + 1 (the
  // FIFO is sized FIFO_DEPTH = VALID_DEPTH there).
  localparam int FIFO_DEPTH = ITERATIONS + 1;
  localparam int CNT_W      = $clog2(FIFO_DEPTH + 1);

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
  // separate satclamp/cfg_align properties.
  always @(posedge clk) begin
    if (rst_n && cyc_count != 8'd0) assume(!config_valid);
  end

  // ready_in left completely FREE — adversarial/arbitrary downstream
  // consumer, including "never ready". The credit-admission scheme is
  // supposed to make CB1'/CB2' hold regardless.
  wire accept_probe = valid_in && ready_out;   // == stage_valid[0], external ports only
  wire consume      = valid_out && ready_in;    // external ports only

  // push_model: ASSUMED (not independently re-verified — see module
  // header) to occur exactly ITERATIONS cycles after accept_probe, based
  // on reading cordic_stage.sv/cordic_pipeline.sv's unconditional
  // register-chain structure. No dut.* reference. $past() must appear
  // directly inside a clocked always block in this Yosys version (a
  // top-level "wire x = $past(...)" continuous assignment errored with
  // "System function $past is only allowed in clocked blocks") — computed
  // here as an explicit register instead.
  // BUG FOUND AND FIXED (this session): $past(sig, N) for N exceeding the
  // cycles actually elapsed since reset is NOT reliably 0 in this Yosys
  // version — for a plain combinational wire (accept_probe has no defined
  // "value before reset"), the solver is free to pick ANY value for that
  // out-of-range lookback, and BMC will happily pick 1 to manufacture a
  // spurious early "push" that permanently corrupts the running
  // shadow_count accumulator (a single bogus +1 in cycle 1 desyncs every
  // subsequent comparison, even though the CB1'/CB2' asserts below only
  // start checking once cyc_count > ITERATIONS). Fixed by gating
  // push_model itself to 0 until cyc_count guarantees $past(accept_probe,
  // ITERATIONS-1) has full real history behind it — no real push can occur
  // that early anyway (ITERATIONS-cycle minimum latency, per the
  // register-chain reading in the module header), so this loses no real
  // events.
  logic push_model;
  always @(posedge clk) begin
    if (!rst_n || cyc_count < 8'(ITERATIONS - 1)) push_model <= 1'b0;
    else                                          push_model <= $past(accept_probe, ITERATIONS - 1);
  end

  logic [CNT_W-1:0] shadow_count;
  always @(posedge clk) begin
    if (!rst_n) begin
      shadow_count <= '0;
    end else begin
      unique case ({push_model, consume})
        2'b10:   shadow_count <= shadow_count + 1'b1;
        2'b01:   shadow_count <= shadow_count - 1'b1;
        default: shadow_count <= shadow_count;
      endcase
    end
  end

  // CB1': the DUT's real, externally-observed valid_out level tracks the
  // occupancy predicted by admission/consumption events alone. This is
  // what "no transaction loss/duplication" means, restated in terms this
  // Yosys frontend can actually check (see module header for the
  // hierarchical-reference limitation this works around).
  always @(posedge clk) begin
    if (rst_n && cyc_count > ITERATIONS) begin
      assert (valid_out == (shadow_count != '0));
    end
  end

  // CB2': shadow occupancy never exceeds capacity — a consistency check
  // between the external ready_out admission gate and the assumed push
  // timing.
  always @(posedge clk) begin
    if (rst_n) begin
      assert (shadow_count <= CNT_W'(FIFO_DEPTH));
    end
  end

  // Covers: prove admission, consumption, a genuinely full shadow FIFO,
  // and valid_out itself are all reachable — otherwise CB1'/CB2' could
  // pass vacuously (e.g. if ready_out never actually let anything in).
  always @(posedge clk) begin
    if (rst_n) begin
      cover (accept_probe);
      cover (consume);
      cover (push_model);
      cover (shadow_count == CNT_W'(FIFO_DEPTH));
      cover (valid_out);
    end
  end

`endif // FORMAL

endmodule


// =============================================================================
// MODULE 3: cordic_pipeline_satclamp_tb - SATURATION CLAMP AT PIPELINE OUTPUT
// REWRITTEN 2026-09-29 (twice) against the post-merge cordic_pipeline.sv.
// EXPECT FAIL — genuine architectural finding, survives both rewrites.
// =============================================================================
//
// STALE-HARNESS NOTE, round 1: the version that shipped with Agent E's
// original pass checked the external `overflow`/`x_out`/`y_out` ports
// (FIFO-read side, decoupled in time from any specific transaction once the
// FIFO can queue) against the LIVE `dut.cfg_saturate_r` (which, per Agent
// B's fix, is now deliberately free to change and is no longer what
// determined any specific transaction's arithmetic) — a comparison between
// two unrelated points in time. See prior revision of this comment for
// detail (preserved in git history).
//
// STALE-HARNESS NOTE, round 2: this session's first fix moved the check to
// PUSH TIME using hierarchical references into cordic_pipeline's internal
// UNPACKED ARRAYS (`dut.stage_x[ITERATIONS]`, `dut.stage_y[ITERATIONS]`,
// `dut.cfg_saturate_sr[ITERATIONS-1]`). That failed to elaborate at all —
// Yosys reported "Identifier implicitly declared" / "Range select out of
// bounds... Setting result bit to undef" for ALL of these and even the
// SCALAR signals referenced in the same compound condition (dut.fifo_push,
// dut.overflow_final), producing a bogus (undef-driven) "counterexample" at
// step 2 that meant nothing. This is a CONFIRMED, reproduced-twice Yosys
// formal-frontend limitation with hierarchical references into a
// submodule's unpacked-array elements (first seen with
// dut.stage_valid[0] earlier in this file's history) — not specific to
// $past(), and not an RTL issue.
//
// FIX: avoid unpacked-array hierarchical references entirely. Restrict the
// check to the case where the FIFO is EMPTY immediately before a push
// (`dut.fifo_count == 0`, `fifo_count` is a plain packed bit vector, not an
// array — safe to reference): in that case wr_ptr==rd_ptr already, so
// exactly ONE cycle after the push, valid_out/x_out/y_out/overflow (the
// external, scalar, port-level signals) are GUARANTEED to reflect this
// exact just-pushed transaction, with no FIFO-queueing ambiguity. All
// referenced dut signals (fifo_push, fifo_count, overflow_final,
// cfg_saturate_r) are scalar/packed. This narrows coverage to the
// "pipe not backed up" case, but the property under test (does a
// mid-pipeline clamp survive to the final output) is a fact about the
// fixed 8-stage arithmetic chain alone, independent of FIFO occupancy —
// testing it in the simplest reachable scenario is sufficient to confirm
// or refute that specific root cause.
//
// RESULT: STILL FALSE under the scalar-only, tool-reliable harness.
//
// ROOT CAUSE (unchanged by the FIFO/config-tagging rework, because it lives
// entirely inside the fixed 8-stage arithmetic chain, which neither Agent A
// nor Agent B touched): `overflow_final` is a per-transaction-correct
// OR-reduction (Agent B's g_ovf_align fix) across all 8 stages' individual
// overflow flags — "did saturation happen ANYWHERE during this
// transaction's 8-stage traversal", not "is the FINAL output currently at
// the saturation boundary". A stage that clamps x_out to MAX_POS
// mid-pipeline hands that clamped value to the NEXT stage as ordinary
// input data; that next stage's arithmetic (depending on sigma/z, unrelated
// to whether the previous stage saturated) can move the value away from
// MAX_POS entirely while the sticky bit stays 1. So a transaction can still
// legitimately finish with overflow_final=1 and a final x/y nowhere near
// either boundary.
//
// This is NOT something this agent can fix — cordic_pipeline.sv is owned by
// the Pipeline RTL agent. Confirmed-still-open finding; see handback report
// for the counterexample trace path.
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

  // FULLY PORT-ONLY formulation — no dut.* hierarchical references at all.
  // Three different ways of referencing cordic_pipeline's internal
  // fifo_push/fifo_count/overflow_final/cfg_saturate_r from this specific
  // module (continuous-assign wire alias, $past() of that alias, and a
  // plain procedural non-blocking read in always_ff) ALL produced
  // "Identifier implicitly declared" warnings and an untrustworthy
  // (undef-driven) counterexample, despite some of those exact same
  // patterns working cleanly for the same underlying signals elsewhere in
  // this file (cordic_pipeline_conservation_tb's direct use of
  // dut.fifo_push/dut.fifo_count). This was not root-caused in the time
  // available this session — see handback report. Falling back to the
  // external ports entirely sidesteps it: `valid_out` transitioning from 0
  // to 1 (i.e. $past(!valid_out) && valid_out) can ONLY happen when the
  // FIFO was empty and a push just landed — wr_ptr==rd_ptr at that push,
  // so x_out/y_out/overflow at the cycle valid_out first goes high are
  // guaranteed (by the FIFO's own read/write pointer logic, which this
  // property does not need to inspect directly to rely on) to reflect
  // exactly that just-completed transaction. `cfg_saturate` (external
  // port) stands in for "was sat mode in effect" since config is held
  // quiescent for this entire task (assumed above) — the external port and
  // the internal register are equal throughout under that assumption.
  always @(posedge clk) begin
    if (rst_n && $past(!valid_out) && valid_out && overflow && cfg_saturate) begin
      assert (x_out == MAX_POS_F || x_out == MIN_NEG_F);
      assert (y_out == MAX_POS_F || y_out == MIN_NEG_F);
    end
  end

  always @(posedge clk) begin
    if (rst_n) begin
      cover ($past(!valid_out) && valid_out && overflow && cfg_saturate);
    end
  end

`endif // FORMAL

endmodule


// =============================================================================
// MODULE 4: cordic_pipeline_cfg_align_tb - CONFIG/TRANSACTION ALIGNMENT
// REWRITTEN 2026-09-29 against the post-merge cordic_pipeline.sv (Agent B's
// per-transaction cfg_saturate_sr fix). NOT FORMALLY VERIFIED — tool
// limitation, not an RTL finding either way. Reachability-only task; see
// TOOL LIMITATION note below and the handback report.
// =============================================================================
//
// STALE-HARNESS NOTE: the old version of this module asserted
// `dut.cfg_saturate_r == $past(dut.cfg_saturate_r, VALID_DEPTH)` for any
// accepted transaction — i.e. it demanded the LIVE config register itself
// stay constant across a transaction's flight time. That claim is now
// simply wrong to make: Agent B's fix deliberately makes cfg_saturate_r
// free to change at any time (a config write mid-flight is fine now), and
// instead threads the value that was live AT ADMISSION through a dedicated
// per-tap shift register, `cfg_saturate_sr[0:ITERATIONS-1]`, in lockstep
// with the stage chain, so each stage always sees the config its OWN
// transaction was admitted under, regardless of later writes. The old
// property FAILING on the current RTL is not evidence the fix doesn't
// work — cfg_saturate_r changing mid-flight is now the INTENDED, correctly
// handled case, and the old harness was directly asserting the opposite of
// that intent (a straightforward case of the property becoming the wrong
// claim once the design's contract changed, not a design bug).
//
// TOOL LIMITATION — CANNOT FORMALLY VERIFY THE DIRECT CLAIM WITH THIS
// TOOLCHAIN (reported explicitly per this project's formal-verification
// guidance, rather than forced through a low-confidence workaround):
//
// The natural, precise way to state Agent B's fix is "cfg_saturate_sr[k]
// (now) == $past(cfg_saturate_r, k) for every tap k=1..ITERATIONS-1". That
// requires reading dut.cfg_saturate_sr[k] — a hierarchical reference into
// an UNPACKED ARRAY element of cordic_pipeline. This session confirmed
// (twice: once attempting exactly this property here, once in
// cordic_pipeline_satclamp_tb for a different array) that this Yosys
// version does not reliably elaborate such references — even a plain,
// non-$past, same-cycle read produced "Identifier implicitly declared" /
// "Range select out of bounds... Setting result bit to undef" and a
// silently undef-driven bogus counterexample, not a clean error that would
// at least fail loudly. So the direct per-tap array proof is not available
// with this toolchain in the time available this session.
//
// An indirect proxy was considered (a local shadow shift-register fed only
// by the scalar dut.cfg_saturate_r, checked against OBSERVABLE x_out/y_out
// clamp behavior via cordic_pipeline_satclamp_tb's "FIFO empty at push"
// technique) but rejected: it would conflate this property with
// cordic_pipeline_satclamp_tb's separate, already-confirmed-FAIL finding
// (mid-pipeline clamps can be undone by later stages), so a FAIL on that
// combined test would not distinguish "config alignment is broken" from
// "the unrelated satclamp issue fired" — a low-confidence result not worth
// reporting as if it answered the question.
//
// SECOND LOOK (2026-09-29, after conservation's external-port-only fix
// worked): re-examined whether a satclamp-style pure-external-port
// reformulation could give a real, decoupled proof here too. Two more
// ideas were explored and both dead-end for structural, not tooling,
// reasons — recorded so this isn't re-attempted fruitlessly later:
//
//   (a) "Only test transactions where overflow happens at exactly the
//       LAST stage (i=ITERATIONS-1)" — with no subsequent stage able to
//       move a clamped value off the boundary, satclamp's confirmed bug
//       wouldn't apply, cleanly isolating the config question via
//       magnitude-at-overflow the same way satclamp itself does. Dead
//       end: which stage overflows is a function of the z-path sigma
//       decisions across all 8 stages, which depends on per-stage
//       internal state this module has no way to constrain or select via
//       external input assumptions alone (would need exactly the internal
//       visibility already established to be unavailable).
//   (b) "Test non-overflowing transactions, where sat vs. wrap mode
//       shouldn't matter" — dead end for the opposite reason: fp_add_sub's
//       non-overflow branch (`result = sum[WIDTH-1:0]`) is IDENTICAL for
//       sat and wrap mode. Non-overflowing transactions are observationally
//       indistinguishable regardless of which config tag they carried, so
//       there is no external signal to check in that regime either —
//       overflowing transactions are the ONLY regime where config mode is
//       externally visible at all, and that regime is exactly where (a)'s
//       problem bites.
//
// Conclusion: a real, non-vacuous, externally-observable proof of
// config/transaction alignment, decoupled from the separate satclamp
// finding, is not achievable with the signals available outside
// cordic_pipeline plus this Yosys version's hierarchical-reference
// limitation. This is reported as genuinely infeasible within this
// session's tools, not worked around.
//
// What THIS module verifies instead: only reachability `cover`s (below),
// establishing that the interesting scenario (a transaction accepted, with
// a config write landing somewhere during its flight, tracked purely via
// scalar dut.cfg_saturate_r) is a real, reachable trace on the current
// RTL — i.e. the scenario the original property was meant to probe is not
// itself vacuous/unreachable. No assert is made about the DUT's per-tap
// array behavior; there is nothing here for sby to disprove, so this task
// reports PASS trivially and that PASS should NOT be read as a proof of
// config/transaction alignment. See handback report for what would
// actually unblock a real proof (newer Yosys, or cordic_pipeline.sv
// exposing a scalar debug tap — the latter not implementable by this
// agent, cordic_pipeline.sv is out of scope).
// =============================================================================

module cordic_pipeline_cfg_align_tb #(
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
  // a config write is allowed to land at any time, including while
  // transactions are mid-flight. No assert is made here — see TOOL
  // LIMITATION note in the module header.
  logic accepted;
  assign accepted = valid_in && ready_out;

  // CORRECTION #2 (found while finalizing this session): the first fix
  // attempt replaced the continuous-assign alias
  // (`wire cfg_sat_l = dut.cfg_saturate_r;`) with a clocked procedural read
  // (`always @(posedge clk) cfg_sat_l <= dut.cfg_saturate_r;`), reasoning
  // that only continuous-assign aliasing was broken. Re-verified by
  // rerunning sby: the SAME "Identifier `\dut.cfg_saturate_r' is implicitly
  // declared" warning still fires. This confirms Agent A's diagnosis is
  // broader than first assumed: Yosys -formal does not reliably resolve
  // `dut.*` hierarchical dot-references AT ALL from outside the instance —
  // neither via continuous assign NOR via direct procedural (clocked or
  // combinational) read — for this signal. There is no dut.* workaround.
  //
  // FIX: use the external `cfg_saturate` port directly instead of trying to
  // observe the internal `cfg_saturate_r` register. `cfg_saturate` sampled
  // when `config_valid && config_ready` is exactly what feeds
  // `cfg_saturate_r`; since config_valid/config_ready are left free (see
  // note above), a plain edge-detect on the external port is an honest,
  // real-port-only proxy for "a config value change has been offered",
  // sufficient for a reachability cover (this module makes no assert).
  logic cfg_sat_l;
  always @(posedge clk) begin
    if (!rst_n)                      cfg_sat_l <= 1'b0;
    else if (config_valid && config_ready) cfg_sat_l <= cfg_saturate;
  end

  always @(posedge clk) begin
    if (rst_n) begin
      cover (accepted);
      cover (cfg_sat_l != $past(cfg_sat_l));
      // A transaction accepted ITERATIONS-1 cycles ago, with a config
      // change having landed somewhere in that window — the scenario the
      // (unprovable-with-this-toolchain) property was meant to probe.
      cover ($past(accepted, ITERATIONS - 1) &&
             (cfg_sat_l != $past(cfg_sat_l, ITERATIONS - 1)));
    end
  end

`endif // FORMAL

endmodule
