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

  // Per-stage angle: atan(2^-STAGE_IDX) × 2^FRACT_W in Q12.3 (FRACT_W=12).
  // Nested ternary for guaranteed elaboration-time constant folding in all tools.
  localparam logic signed [WIDTH-1:0] STAGE_ANGLE =
    (STAGE_IDX == 0) ? 16'sd3217 :   // 45.000°
    (STAGE_IDX == 1) ? 16'sd1899 :   // 26.565°
    (STAGE_IDX == 2) ? 16'sd1003 :   // 14.036°
    (STAGE_IDX == 3) ? 16'sd509  :   //  7.125°
    (STAGE_IDX == 4) ? 16'sd256  :   //  3.576°
    (STAGE_IDX == 5) ? 16'sd128  :   //  1.790°
    (STAGE_IDX == 6) ? 16'sd64   :   //  0.895°
                       16'sd32;      //  0.448° (STAGE_IDX == 7)

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

  // Conditional negate: +shifted if sigma=1, -shifted if sigma=0
  logic signed [WIDTH-1:0] x_mux, y_mux;
  always_comb begin
    x_mux = sigma ? x_shifted : -x_shifted;
    y_mux = sigma ? y_shifted : -y_shifted;
  end

  // Three fp_add_sub instances
  logic signed [WIDTH-1:0] x_comb, y_comb, z_comb;
  logic         ovf_x, ovf_y, ovf_z;

  // X path: x_new = x_in - sigma × (y_in >> STAGE_IDX)
  fp_add_sub #(.WIDTH(WIDTH), .FRACT_W(FRACT_W)) x_adder (
    .a       (x_in),
    .b       (y_mux),
    .op      (1'b1),      // subtract
    .sat     (sat),
    .result  (x_comb),
    .overflow(ovf_x)
  );

  // Y path: y_new = y_in + sigma × (x_in >> STAGE_IDX)
  fp_add_sub #(.WIDTH(WIDTH), .FRACT_W(FRACT_W)) y_adder (
    .a       (y_in),
    .b       (x_mux),
    .op      (1'b0),      // add
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
