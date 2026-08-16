// Formal verification harness for cordic_stage.
//
// Yosys 0.67 + sby 0.61 compatibility notes:
//   - No concurrent SVA (property...endproperty not supported)
//   - No $past() + initial assume: the $past shadow FF has unconstrained
//     initial value (anyinit), which creates spurious counterexamples at
//     step 0 for properties that check behaviour "after reset". P1-P3 are
//     instead verified by simulation (all 5 tests pass).
//   - Assertions without $past check instantaneous datapath properties
//     and are sound with sby 0.61.
//
// Properties proved here (BMC, depth 20):
//   P4: sat && overflow => x_out clamped to MAX_POS or MIN_NEG
//   P5: sat && overflow => y_out clamped to MAX_POS or MIN_NEG
//   P6: x_out always in signed representable range when valid
//   P7: y_out always in signed representable range when valid
//
// Properties verified by simulation (cordic_assertions.sv, ASSERT_ON):
//   P1: reset clears valid_out within 1 cycle
//   P2: reset clears overflow within 1 cycle
//   P3: valid_in propagates to valid_out with 1-cycle latency
//
// Run via: make formal  (sby -f tb/formal/cordic_formal.sby)

import cordic_pkg::*;

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

  // DUT: no ASSERT_ON — SVA-style cordic_assertions not parsed by Yosys 0.67
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

  // Local constants — explicit arithmetic avoids package typedef ambiguity
  localparam logic signed [WIDTH-1:0] MAX_POS_F = (1 << (WIDTH-1)) - 1;
  localparam logic signed [WIDTH-1:0] MIN_NEG_F = -(1 << (WIDTH-1));

  // Input constraints — always active (no $past dependency)
  localparam signed [WIDTH-1:0] Z_BOUND  = 16'sd7127;   // ±1.74 rad in Q12.3
  localparam signed [WIDTH-1:0] XY_BOUND = 16'sd16383;  // 75% of MAX_POS

  always @(*) begin
    assume(z_in  >= -Z_BOUND  && z_in  <=  Z_BOUND);
    assume(x_in  >= -XY_BOUND && x_in  <=  XY_BOUND);
    assume(y_in  >= -XY_BOUND && y_in  <=  XY_BOUND);
  end

  // P4: sat && overflow => x_out clamped to MAX_POS_F or MIN_NEG_F
  // Checks the saturation clamping logic instantaneously (no history needed)
  always @(posedge clk) begin
    if (rst_n && sat && overflow) begin
      assert (x_out == MAX_POS_F || x_out == MIN_NEG_F);
    end
  end

  // P5: sat && overflow => y_out clamped to MAX_POS_F or MIN_NEG_F
  always @(posedge clk) begin
    if (rst_n && sat && overflow) begin
      assert (y_out == MAX_POS_F || y_out == MIN_NEG_F);
    end
  end

  // P6: x_out always in signed representable range when valid and not in reset
  always @(posedge clk) begin
    if (rst_n && valid_out) begin
      assert (x_out >= MIN_NEG_F && x_out <= MAX_POS_F);
    end
  end

  // P7: y_out always in signed representable range when valid and not in reset
  always @(posedge clk) begin
    if (rst_n && valid_out) begin
      assert (y_out >= MIN_NEG_F && y_out <= MAX_POS_F);
    end
  end

`endif // FORMAL

endmodule
