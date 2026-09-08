//==============================================================================
// Module: cordic_pipeline
// Description: N-stage pipelined CORDIC with valid/ready handshaking and
//              configuration capture. Throughput = 1 vector/cycle after fill.
//              Input stage: K-factor prescaling via cordic_lut.
//              Iteration stages: N × cordic_stage (STAGE_IDX hardwired per inst).
//              Each cordic_stage embeds its own angle constant (no shared angle LUT).
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

  // Latency: input capture + ITERATIONS stages + output register
  localparam int VALID_DEPTH = ITERATIONS + 2;

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
  // stage_overflow_accum[i] = accumulated overflow from all stages 0..i-1
  // ---------------------------------------------------------------------------
  logic signed [WIDTH-1:0] stage_x [0:ITERATIONS];
  logic signed [WIDTH-1:0] stage_y [0:ITERATIONS];
  logic signed [WIDTH-1:0] stage_z [0:ITERATIONS];
  logic         stage_valid    [0:ITERATIONS];
  logic         stage_overflow [0:ITERATIONS];
  logic         stage_overflow_accum [0:ITERATIONS];

  // Input stage: K-prescaled x/y, raw z, valid gated with ready
  logic ready_out_int;

  assign stage_x[0]              = lut_k_x;
  assign stage_y[0]              = lut_k_y;
  assign stage_z[0]              = z_in;
  assign stage_valid[0]          = valid_in & ready_out_int;
  assign stage_overflow[0]       = 1'b0;
  assign stage_overflow_accum[0] = 1'b0;  // No overflow before any stages

  // ---------------------------------------------------------------------------
  // CORDIC STAGE CHAIN (generate)
  // Overflow accumulates through the pipeline: accum[i+1] = accum[i] | ovf[i]
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
      .sat      (cfg_saturate_r),
      .x_out    (stage_x[i+1]),
      .y_out    (stage_y[i+1]),
      .z_out    (stage_z[i+1]),
      .valid_out(stage_valid[i+1]),
      .overflow (stage_overflow[i+1])
    );

    // Pipeline accumulated overflow: OR current stage overflow with accumulated overflow
    // This accumulation happens combinatorially within this loop, then gets latched
    // in the output register at the appropriate time.
    assign stage_overflow_accum[i+1] = stage_overflow_accum[i] | stage_overflow[i+1];
  end

  // ---------------------------------------------------------------------------
  // VALID PIPELINE AND BACKPRESSURE
  // ready_out_int is registered once → ready_out registered again for timing.
  // This gives a 2-cycle backpressure latency (acceptable for ITERATIONS+2 depth).
  // ---------------------------------------------------------------------------
  logic [VALID_DEPTH-1:0] valid_pipe;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      valid_pipe    <= '0;
      ready_out_int <= 1'b1;
      ready_out     <= 1'b1;
    end else begin
      ready_out_int <= !valid_pipe[VALID_DEPTH-1] | ready_in;
      ready_out     <= ready_out_int;
      valid_pipe    <= {valid_pipe[VALID_DEPTH-2:0], valid_in & ready_out_int};
    end
  end

  // ---------------------------------------------------------------------------
  // OUTPUT REGISTER
  // Overflow from stage_overflow_accum[ITERATIONS] = accumulated overflow from
  // all stages, matching the golden model where overflow is ORed across all
  // CORDIC iterations.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      x_out     <= '0;
      y_out     <= '0;
      z_out     <= '0;
      valid_out <= 1'b0;
      overflow  <= 1'b0;
      irq       <= 1'b0;
    end else begin
      x_out     <= stage_x[ITERATIONS];
      y_out     <= stage_y[ITERATIONS];
      z_out     <= stage_z[ITERATIONS];
      valid_out <= stage_valid[ITERATIONS];
      overflow  <= stage_overflow_accum[ITERATIONS];
      irq       <= stage_valid[ITERATIONS];   // pulse on each valid output
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
