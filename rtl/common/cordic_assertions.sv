//==============================================================================
// Module: cordic_assertions
// Description: Bindable SVA assertion module for CORDIC accelerator.
//              Monitors one cordic_stage interface; bind from cordic_stage.sv.
//              Synthesized RTL: assertions are ignored by Yosys.
//              Simulation/Formal: assertions checked by Verilator/SymbiYosys.
// Owner: Architecture Agent (Lead)
// Wave: 0 (Foundation)
//==============================================================================

import cordic_pkg::*;

module cordic_assertions #(
  parameter int WIDTH      = cordic_pkg::WIDTH,
  parameter int FRACT_W    = cordic_pkg::FRACT_W,
  parameter int ITERATIONS = cordic_pkg::ITERATIONS
) (
  input logic                    clk,
  input logic                    rst_n,
  // Stage input interface (monitor only — no outputs)
  input logic signed [WIDTH-1:0] x_in,
  input logic signed [WIDTH-1:0] y_in,
  input logic signed [WIDTH-1:0] z_in,
  input logic                    valid_in,
  input logic                    sat,
  // Stage output interface (monitor only)
  input logic signed [WIDTH-1:0] x_out,
  input logic signed [WIDTH-1:0] y_out,
  input logic signed [WIDTH-1:0] z_out,
  input logic                    valid_out,
  input logic                    overflow
);

`ifdef ASSERT_ON

  // ---------------------------------------------------------------------------
  // RESET PROPERTIES
  // After reset deasserts, outputs must clear within 1 cycle.
  // ---------------------------------------------------------------------------
  property p_reset_clears_valid;
    @(posedge clk) !rst_n |=> !valid_out;
  endproperty

  property p_reset_clears_overflow;
    @(posedge clk) !rst_n |=> !overflow;
  endproperty

  assert property (p_reset_clears_valid)
    else $error("ASSERT: valid_out not cleared after reset");
  assert property (p_reset_clears_overflow)
    else $error("ASSERT: overflow not cleared after reset");

  // ---------------------------------------------------------------------------
  // SATURATION PROPERTIES
  // When sat=1 and overflow=1, outputs must be clamped.
  // ---------------------------------------------------------------------------
  property p_sat_clamps_x;
    @(posedge clk) disable iff (!rst_n)
      (sat && overflow) |-> (x_out == MAX_POS || x_out == MIN_NEG);
  endproperty

  property p_sat_clamps_y;
    @(posedge clk) disable iff (!rst_n)
      (sat && overflow) |-> (y_out == MAX_POS || y_out == MIN_NEG);
  endproperty

  assert property (p_sat_clamps_x)
    else $error("ASSERT: sat=1, overflow=1 but x_out not clamped");
  assert property (p_sat_clamps_y)
    else $error("ASSERT: sat=1, overflow=1 but y_out not clamped");

  // ---------------------------------------------------------------------------
  // VALID PROPAGATION
  // valid_out must follow valid_in with exactly 1-cycle latency.
  // ---------------------------------------------------------------------------
  property p_valid_propagates;
    @(posedge clk) disable iff (!rst_n)
      valid_in |=> valid_out;
  endproperty

  assert property (p_valid_propagates)
    else $error("ASSERT: valid_in high but valid_out not high 1 cycle later");

  // ---------------------------------------------------------------------------
  // COVERAGE POINTS
  // ---------------------------------------------------------------------------
  cover property (@(posedge clk) disable iff (!rst_n) valid_in && sat);
  cover property (@(posedge clk) disable iff (!rst_n) valid_in && !sat);
  cover property (@(posedge clk) disable iff (!rst_n) overflow && sat);
  cover property (@(posedge clk) disable iff (!rst_n) overflow && !sat);

`endif // ASSERT_ON

endmodule
