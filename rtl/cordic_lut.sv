//==============================================================================
// Module: cordic_lut
// Description: K-factor prescaling LUT for CORDIC input stage.
//              16-entry LUT indexed by 4 MSBs of x_in and y_in independently.
//              Each cordic_stage embeds its own angle constant (from cordic_pkg
//              ATAN_LUT) via STAGE_ANGLE localparam — no shared angle LUT needed.
//
//              Zero-cycle latency; always_comb + unique case → distributed LUT
//              inference guaranteed (no RAM risk).
//
// Owner: Datapath RTL Agent
// Parameters: WIDTH, FRACT_W, ITERATIONS
// Dependencies: cordic_pkg
// Wave: 1 (Arithmetic Primitives)
//==============================================================================

module cordic_lut
  import cordic_pkg::*;
#(
  parameter int WIDTH      = cordic_pkg::WIDTH,
  parameter int FRACT_W    = cordic_pkg::FRACT_W,
  parameter int ITERATIONS = cordic_pkg::ITERATIONS
) (
  input  logic [3:0]              k_lut_idx_x,   // 4 MSBs of x_in
  input  logic [3:0]              k_lut_idx_y,   // 4 MSBs of y_in (separate)
  output cordic_data_t            k_prescale_x,  // K × x_in approximation
  output cordic_data_t            k_prescale_y   // K × y_in approximation
);

  // ---------------------------------------------------------------------------
  // K-PRESCALE LUT: 16-entry, 4 MSB indexed
  // K = 0.607252935; LUT maps 4 MSBs to K-scaled output in Q12.3
  // ---------------------------------------------------------------------------
  function automatic cordic_data_t k_lut(input logic [3:0] idx);
    unique case (idx)
      4'h0: return -16'sd32768;   // clamped MIN_NEG
      4'h1: return -16'sd30720;
      4'h2: return -16'sd28672;
      4'h3: return -16'sd26624;
      4'h4: return -16'sd24576;
      4'h5: return -16'sd22528;
      4'h6: return -16'sd20480;
      4'h7: return -16'sd18432;
      4'h8: return  16'sd0;
      4'h9: return  16'sd18432;
      4'ha: return  16'sd20480;
      4'hb: return  16'sd22528;
      4'hc: return  16'sd24576;
      4'hd: return  16'sd26624;
      4'he: return  16'sd28672;
      4'hf: return  16'sd30720;
      default: return '0;
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // COMBINATIONAL OUTPUTS
  // ---------------------------------------------------------------------------
  always_comb begin
    k_prescale_x = k_lut(k_lut_idx_x);
    k_prescale_y = k_lut(k_lut_idx_y);
  end

endmodule
