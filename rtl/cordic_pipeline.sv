//==============================================================================
// Module: cordic_pipeline
// Description: N-stage pipelined CORDIC with valid/ready handshaking and
//              configuration capture. Throughput = 1 vector/cycle after fill.
//              Input stage: K-factor prescaling via cordic_lut (combinational;
//              there is no dedicated input-capture register — see latency note
//              below).
//              Iteration stages: N × cordic_stage (STAGE_IDX hardwired per inst).
//              Each cordic_stage embeds its own angle constant (no shared angle LUT).
//              Output: a small skid FIFO (depth = VALID_DEPTH) holds every
//              completed transaction until `ready_in` consumes it, so a
//              transaction is never silently overwritten under backpressure
//              (see "OUTPUT SKID FIFO" below). cordic_stage itself has no
//              stall input and free-runs every cycle; that is unchanged.
//
// Owner: Pipeline RTL Agent
// Parameters: WIDTH, FRACT_W, ITERATIONS
// Dependencies: cordic_pkg, cordic_lut, cordic_stage
// Wave: 3 (Pipeline Assembly)
//==============================================================================

import cordic_pkg::*;

module cordic_pipeline #(
  parameter int WIDTH      = cordic_pkg::WIDTH,
  parameter int FRACT_W    = cordic_pkg::FRACT_W,
  parameter int ITERATIONS = cordic_pkg::ITERATIONS
) (
  input  logic                    clk,
  input  logic                    rst_n,
  // Input interface
  input  logic signed [WIDTH-1:0] x_in,
  input  logic signed [WIDTH-1:0] y_in,
  input  logic signed [WIDTH-1:0] z_in,
  input  logic                    valid_in,
  output logic                    ready_out,
  // Configuration (simple handshake — no AXI)
  input  logic [3:0]              cfg_iterations,   // currently unused in V1 (fixed at ITERATIONS)
  input  logic                    cfg_saturate,
  input  logic                    config_valid,
  output logic                    config_ready,
  // Output interface
  output logic signed [WIDTH-1:0] x_out,
  output logic signed [WIDTH-1:0] y_out,
  output logic signed [WIDTH-1:0] z_out,
  output logic                    valid_out,
  input  logic                    ready_in,
  // Status
  output logic                    overflow,
  output logic                    irq
);

  // Latency: ITERATIONS stage registers + 1 cycle for the completed vector
  // to land in the output FIFO. There is NO dedicated input-capture
  // register in this RTL: stage_x[0]/stage_y[0]/stage_z[0]/stage_valid[0]
  // below are combinational functions of x_in/y_in/z_in/valid_in gated by
  // ready_out, feeding cordic_stage instance 0 directly. Tracing the actual
  // registers: stage_valid[k] (k=1..ITERATIONS) is registered once per
  // cordic_stage (1 cycle each), so stage_valid[ITERATIONS] appears
  // ITERATIONS cycles after admission, and a transaction is visible at the
  // head of the output FIFO 1 cycle after that (the FIFO-write register) —
  // i.e. VALID_DEPTH = ITERATIONS + 1, confirmed by cycle-accurate
  // simulation. This used to be ITERATIONS + 2 ("input capture + N stages +
  // output register"), matching docs/PIPELINE.md and
  // docs/SPECIFICATION.md's description of a dedicated input register — but
  // that register was never implemented in this RTL, so the documented
  // depth was one cycle deeper than reality. VALID_DEPTH here now reflects
  // the true, measured latency; docs/PIPELINE.md, docs/SPECIFICATION.md and
  // docs/MICROARCHITECTURE.md are stale and should be corrected to
  // ITERATIONS + 1 by whoever owns them (not this file).
  localparam int VALID_DEPTH = ITERATIONS + 1;

  // ---------------------------------------------------------------------------
  // CONFIGURATION REGISTERS
  // ---------------------------------------------------------------------------
  logic cfg_saturate_r;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cfg_saturate_r <= 1'b1;
      config_ready   <= 1'b1;
    end else begin
      config_ready <= 1'b1;
      if (config_valid && config_ready)
        cfg_saturate_r <= cfg_saturate;
    end
  end

  // ---------------------------------------------------------------------------
  // K-PRESCALE (input stage only) — shift-add constant multiply by K
  // ---------------------------------------------------------------------------
  logic signed [WIDTH-1:0] lut_k_x, lut_k_y;

  cordic_lut #(.WIDTH(WIDTH), .FRACT_W(FRACT_W), .ITERATIONS(ITERATIONS)) lut_inst (
    .x_in        (x_in),
    .y_in        (y_in),
    .k_prescale_x(lut_k_x),
    .k_prescale_y(lut_k_y)
  );

  // ---------------------------------------------------------------------------
  // STAGE INTERCONNECT (N+1 entries: index 0 = input, index N = last stage out)
  // ---------------------------------------------------------------------------
  logic signed [WIDTH-1:0] stage_x [0:ITERATIONS];
  logic signed [WIDTH-1:0] stage_y [0:ITERATIONS];
  logic signed [WIDTH-1:0] stage_z [0:ITERATIONS];
  logic         stage_valid    [0:ITERATIONS];
  logic         stage_overflow [0:ITERATIONS];

  // Input stage: K-prescaled x/y, raw z, valid gated with ready.
  // Gated directly by the `ready_out` port (see OUTPUT SKID FIFO below) —
  // there used to be a separate `ready_out_int` net with `ready_out` a
  // second, further-delayed register of it, so the admission decision here
  // and the ready_out value the producer actually sees could disagree for a
  // cycle (a second, independent source of dropped transactions beyond the
  // output-overwrite bug). Collapsed to a single signal so admission and
  // the externally visible ready_out are always identical.
  assign stage_x[0]              = lut_k_x;
  assign stage_y[0]              = lut_k_y;
  assign stage_z[0]              = z_in;
  assign stage_valid[0]          = valid_in & ready_out;
  assign stage_overflow[0]       = 1'b0;

  // ---------------------------------------------------------------------------
  // PER-TRANSACTION CONFIG TAG (fixes config/overflow alignment bug)
  //
  // cfg_saturate_r is a single live register, updated whenever
  // config_valid && config_ready, and the old code wired it identically into
  // EVERY cordic_stage instance's `.sat` port. But each pipeline position i
  // holds a DIFFERENT in-flight transaction at any given cycle (position i
  // holds whatever was admitted i cycles ago) — cordic_stage free-runs every
  // cycle with no stall input, so the stage array advances in lockstep
  // regardless of downstream backpressure (backpressure only affects
  // admission and the output FIFO, not this chain). So a cfg_saturate write
  // that lands while transactions are in flight retroactively changed
  // saturation mode for whichever stages hadn't executed yet that cycle —
  // inconsistently across a SINGLE transaction's own 8 stages. Confirmed by
  // direct inspection and independently by Agent E's formal cfg_align BMC
  // counterexample.
  //
  // Fix: capture cfg_saturate_r at admission (position 0, a plain wire — no
  // extra latency since stage 0 processes this-cycle-admitted data) and
  // shift it forward one register per stage, in lockstep with the stage
  // chain. stage i then always sees the config that was live when ITS OWN
  // transaction was admitted, regardless of any later config write. No
  // change to cordic_stage.sv's ports is needed.
  // ---------------------------------------------------------------------------
  logic cfg_saturate_sr [0:ITERATIONS-1];

  assign cfg_saturate_sr[0] = cfg_saturate_r;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int k = 1; k < ITERATIONS; k++) cfg_saturate_sr[k] <= 1'b1;
    end else begin
      for (int k = 1; k < ITERATIONS; k++) cfg_saturate_sr[k] <= cfg_saturate_sr[k-1];
    end
  end

  // ---------------------------------------------------------------------------
  // PER-TRANSACTION OVERFLOW ACCUMULATION (fixes overflow-attribution bug)
  //
  // stage_overflow[1..ITERATIONS] are the REGISTERED overflow outputs of
  // stages 0..ITERATIONS-1 *as of the current cycle* — i.e. they belong to
  // DIFFERENT transactions resident at different pipeline depths (same
  // free-running-chain reasoning as above), not to one transaction's history
  // at different times. The old combinational OR chain
  // (stage_overflow_accum[i+1] = stage_overflow_accum[i] | stage_overflow[i+1],
  // re-evaluated fresh every cycle) therefore ORs together overflow flags
  // from several unrelated in-flight transactions currently resident at
  // positions 1..ITERATIONS, not the completing transaction's own overflow
  // history — and that combinational value is exactly what got latched into
  // fifo_ovf[wr_ptr] at fifo_push. This is a real, reachable bug (verified
  // by hand-tracing two back-to-back transactions where only the second
  // overflows: at the cycle the first transaction completes, the
  // combinational chain also includes the second transaction's overflow bit
  // from whatever earlier position it currently occupies, corrupting the
  // first transaction's reported overflow) and is NOT fixed by the FIFO
  // rewrite — the FIFO just faithfully stores whatever buggy value the
  // combinational chain produced at push time.
  //
  // Fix: realign each stage's overflow bit to the cycle at which its OWN
  // transaction completes, using a pure per-tap delay line (no cross-register
  // combining, so there is no same-edge race against the registered overflow
  // output inside cordic_stage). Stage i's overflow bit is produced
  // (ITERATIONS - i) cycles before its transaction reaches the final stage,
  // so it is delayed by that many extra cycles; the ITERATIONS-th stage's
  // bit needs no delay. All aligned bits are then OR-reduced combinationally
  // at the completion cycle, which is now valid because every operand
  // belongs to the same transaction at that instant.
  // ---------------------------------------------------------------------------
  logic stage_overflow_aligned [1:ITERATIONS];

  for (genvar i = 1; i <= ITERATIONS; i++) begin : g_ovf_align
    localparam int DEPTH = ITERATIONS - i;
    if (DEPTH == 0) begin : g_no_delay
      assign stage_overflow_aligned[i] = stage_overflow[i];
    end else if (DEPTH == 1) begin : g_delay1
      logic dly_r;
      always_ff @(posedge clk) begin
        if (!rst_n) dly_r <= 1'b0;
        else        dly_r <= stage_overflow[i];
      end
      assign stage_overflow_aligned[i] = dly_r;
    end else begin : g_delayn
      logic [DEPTH-1:0] dly_sr;
      always_ff @(posedge clk) begin
        if (!rst_n) dly_sr <= '0;
        else        dly_sr <= {dly_sr[DEPTH-2:0], stage_overflow[i]};
      end
      assign stage_overflow_aligned[i] = dly_sr[DEPTH-1];
    end
  end

  logic overflow_final;
  always_comb begin
    overflow_final = 1'b0;
    for (int i = 1; i <= ITERATIONS; i++) overflow_final |= stage_overflow_aligned[i];
  end

  // ---------------------------------------------------------------------------
  // CORDIC STAGE CHAIN (generate)
  // ---------------------------------------------------------------------------
  for (genvar i = 0; i < ITERATIONS; i++) begin : g_stages
    cordic_stage #(
      .WIDTH    (WIDTH),
      .FRACT_W  (FRACT_W),
      .STAGE_IDX(i)
    ) stage_inst (
      .clk      (clk),
      .rst_n    (rst_n),
      .x_in     (stage_x[i]),
      .y_in     (stage_y[i]),
      .z_in     (stage_z[i]),
      .valid_in (stage_valid[i]),
      .sat      (cfg_saturate_sr[i]),
      .x_out    (stage_x[i+1]),
      .y_out    (stage_y[i+1]),
      .z_out    (stage_z[i+1]),
      .valid_out(stage_valid[i+1]),
      .overflow (stage_overflow[i+1])
    );
  end

  // ---------------------------------------------------------------------------
  // OUTPUT SKID FIFO AND CREDIT-BASED ADMISSION CONTROL
  //
  // ROOT CAUSE (confirmed): cordic_stage has no stall/enable input at all —
  // every cordic_stage register, and the single output register that used
  // to live here, updated unconditionally every cycle regardless of
  // `ready_in`. So a completed-but-unconsumed transaction sitting in the
  // output register was silently clobbered by the very next transaction to
  // complete, one cycle later, with no error indication. The old
  // "look-ahead" `ready_out` (a valid_pipe shadow shift-register) only ever
  // throttled *new* admissions before the pipe filled — it did nothing to
  // protect data that was already in flight (admitted up to VALID_DEPTH
  // cycles earlier) from being overwritten at the far end. Reproduced with
  // a new regression test (see tb/cordic_pipeline_tb.sv): holding
  // `ready_in` low while sending back-to-back transactions previously
  // resulted in 0 of N transactions ever being observed at the output.
  //
  // FIX: every completed transaction (`stage_valid[ITERATIONS]`) is written
  // into a small output FIFO instead of a single register, so a completed
  // transaction is never overwritten — `valid_out` simply reflects
  // "FIFO non-empty" and, once asserted, holds the SAME head entry until
  // `ready_in` consumes it. This matches docs/INTERFACE_SPECIFICATION.md's
  // documented contract ("Output held until ready_in=1"), which the old
  // single-register implementation never actually delivered.
  //
  // Admission (`ready_out`) is gated by a credit counter (`reserved_count`)
  // that tracks every transaction currently between admission and
  // consumption — whether still marching through the fixed-latency
  // cordic_stage chain or already parked in the FIFO — and never allows
  // more than FIFO_DEPTH to be outstanding at once. `ready_out` is
  // deliberately combinational in `reserved_count` (not registered): a
  // registered/delayed admission gate would let one extra transaction slip
  // in each time reserved_count is re-sampled a cycle late, which would
  // require padding FIFO_DEPTH with slack to compensate. Keeping the
  // comparison combinational removes that whole class of off-by-one risk;
  // FIFO_DEPTH == VALID_DEPTH (the pipe's own fixed depth) is then
  // provably always enough to hold everything that can possibly still be
  // in flight, so no transaction is ever dropped, however long ready_in
  // stays low. This is a bounded, minimal fix that needs no change to
  // cordic_stage.sv (which has no stall port and is owned by another
  // agent): the fixed pipe keeps free-running exactly as it did before, it
  // now just always has somewhere safe to drain into.
  // ---------------------------------------------------------------------------
  localparam int FIFO_DEPTH = VALID_DEPTH;
  localparam int FIFO_AW    = (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH);
  localparam int CNT_W      = $clog2(FIFO_DEPTH + 1);

  logic signed [WIDTH-1:0] fifo_x   [0:FIFO_DEPTH-1];
  logic signed [WIDTH-1:0] fifo_y   [0:FIFO_DEPTH-1];
  logic signed [WIDTH-1:0] fifo_z   [0:FIFO_DEPTH-1];
  logic                    fifo_ovf [0:FIFO_DEPTH-1];

  logic [FIFO_AW-1:0] wr_ptr, rd_ptr;
  logic [CNT_W-1:0]   fifo_count;     // entries actually parked in the FIFO
  logic [CNT_W-1:0]   reserved_count; // in-flight-or-parked; gates admission

  logic fifo_push, fifo_pop;
  assign fifo_push = stage_valid[ITERATIONS];       // pipe completed a vector
  assign fifo_pop  = (fifo_count != '0) && ready_in; // consumer accepts head

  assign ready_out  = (reserved_count < CNT_W'(FIFO_DEPTH));
  assign valid_out  = (fifo_count != '0);
  // Gate the data/overflow reads with valid_out so an empty FIFO (reset, or
  // drained) presents defined '0 outputs instead of an uninitialized array read.
  assign x_out      = valid_out ? fifo_x[rd_ptr]   : '0;
  assign y_out      = valid_out ? fifo_y[rd_ptr]   : '0;
  assign z_out      = valid_out ? fifo_z[rd_ptr]   : '0;
  assign overflow   = valid_out ? fifo_ovf[rd_ptr] : 1'b0;
  assign irq        = fifo_push;   // pulse each time the pipe completes a vector

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wr_ptr         <= '0;
      rd_ptr         <= '0;
      fifo_count     <= '0;
      reserved_count <= '0;
    end else begin
      // FIFO storage: capture every completion, indexed by wr_ptr.
      // Overflow from overflow_final = per-transaction accumulated overflow
      // across all stages (see PER-TRANSACTION OVERFLOW ACCUMULATION above),
      // matching the golden model where overflow is ORed across all CORDIC
      // iterations of the SAME transaction — not a cross-transaction OR of
      // whatever else happens to be in flight.
      if (fifo_push) begin
        fifo_x[wr_ptr]   <= stage_x[ITERATIONS];
        fifo_y[wr_ptr]   <= stage_y[ITERATIONS];
        fifo_z[wr_ptr]   <= stage_z[ITERATIONS];
        fifo_ovf[wr_ptr] <= overflow_final;
        wr_ptr           <= (wr_ptr == FIFO_AW'(FIFO_DEPTH - 1)) ? '0 : wr_ptr + 1'b1;
      end
      if (fifo_pop)
        rd_ptr <= (rd_ptr == FIFO_AW'(FIFO_DEPTH - 1)) ? '0 : rd_ptr + 1'b1;

      unique case ({fifo_push, fifo_pop})
        2'b10:   fifo_count <= fifo_count + 1'b1;
        2'b01:   fifo_count <= fifo_count - 1'b1;
        default: fifo_count <= fifo_count; // 00: no change, 11: net zero
      endcase

      // Credit accounting: +1 on admission (stage_valid[0]), -1 on
      // consumption (fifo_pop). Admission is gated by ready_out, which is
      // itself a combinational function of reserved_count, so
      // reserved_count can never exceed FIFO_DEPTH: whenever it equals
      // FIFO_DEPTH, ready_out is already low and stage_valid[0] cannot be
      // asserted that same cycle.
      unique case ({stage_valid[0], fifo_pop})
        2'b10:   reserved_count <= reserved_count + 1'b1;
        2'b01:   reserved_count <= reserved_count - 1'b1;
        default: reserved_count <= reserved_count;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // ASSERTIONS
  // ---------------------------------------------------------------------------
`ifdef ASSERT_ON
  // Latency: a valid input accepted by the pipeline produces valid_out after
  // exactly VALID_DEPTH cycles.
  property p_pipeline_latency;
    @(posedge clk) disable iff (!rst_n)
      (valid_in && ready_out) |-> ##VALID_DEPTH valid_out;
  endproperty
  assert property (p_pipeline_latency)
    else $error("pipeline: latency violated");

  // Backpressure: if ready_in deasserts, valid_out must not advance past output.
  // (Checked by integration TB)
`endif

endmodule
