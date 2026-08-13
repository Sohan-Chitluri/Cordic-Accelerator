//==============================================================================
// Module: cordic_top
// Description: Top-level integration — passes through all ports to
//              cordic_pipeline. Clean integration point for synthesis and P&R.
//
// Owner: Integration & Top-Level Agent (Lead)
// Parameters: WIDTH, FRACT_W, ITERATIONS
// Dependencies: cordic_pkg, cordic_pipeline
// Wave: 4 (Top-Level & Sign-Off)
//==============================================================================

module cordic_top
  import cordic_pkg::*;
#(
  parameter int WIDTH      = cordic_pkg::WIDTH,
  parameter int FRACT_W    = cordic_pkg::FRACT_W,
  parameter int ITERATIONS = cordic_pkg::ITERATIONS
) (
  input  logic                    clk,
  input  logic                    rst_n,
  // Data input
  input  cordic_data_t            x_in,
  input  cordic_data_t            y_in,
  input  cordic_data_t            z_in,
  input  logic                    valid_in,
  output logic                    ready_out,
  // Configuration
  input  logic [3:0]              cfg_iterations,
  input  logic                    cfg_saturate,
  input  logic                    config_valid,
  output logic                    config_ready,
  // Data output
  output cordic_data_t            x_out,
  output cordic_data_t            y_out,
  output cordic_data_t            z_out,
  output logic                    valid_out,
  input  logic                    ready_in,
  // Status
  output logic                    overflow,
  output logic                    irq
);

  cordic_pipeline #(
    .WIDTH     (WIDTH),
    .FRACT_W   (FRACT_W),
    .ITERATIONS(ITERATIONS)
  ) pipeline_inst (
    .clk          (clk),
    .rst_n        (rst_n),
    .x_in         (x_in),
    .y_in         (y_in),
    .z_in         (z_in),
    .valid_in     (valid_in),
    .ready_out    (ready_out),
    .cfg_iterations(cfg_iterations),
    .cfg_saturate (cfg_saturate),
    .config_valid (config_valid),
    .config_ready (config_ready),
    .x_out        (x_out),
    .y_out        (y_out),
    .z_out        (z_out),
    .valid_out    (valid_out),
    .ready_in     (ready_in),
    .overflow     (overflow),
    .irq          (irq)
  );

endmodule
