//==============================================================================
// Module: cordic_lut
// Description: K-factor prescaler for the CORDIC input stage.
//
//              Multiplies x_in and y_in by the CORDIC gain reciprocal
//              K = 0.607252935 using a fixed shift-add network (NO multiplier,
//              per ADR-0002). K is realized exactly as the Q12 constant
//              K_FACTOR = 2488/4096 = 0.607421875 (0.028% vs. true K):
//
//                v * 2488 = (v<<11) + (v<<9) - (v<<6) - (v<<3)
//                k        = round( v*2488 / 4096 ) = (v*2488 + 2048) >>> 12
//
//              Purely combinational (0-cycle). Synthesizes to a small adder
//              tree — no RAM/ROM inference. Full input precision preserved
//              (supersedes the old 4-MSB LUT which quantized to 16 levels).
//
//              Each cordic_stage embeds its own atan(2^-i) angle constant, so
//              no shared angle LUT is required here.
//
// Owner: Datapath RTL Agent
// Parameters: WIDTH, FRACT_W, ITERATIONS
// Dependencies: cordic_pkg
// Wave: 1 (Arithmetic Primitives)
//==============================================================================

import cordic_pkg::*;

module cordic_lut #(
  parameter int WIDTH      = cordic_pkg::WIDTH,
  parameter int FRACT_W    = cordic_pkg::FRACT_W,
  parameter int ITERATIONS = cordic_pkg::ITERATIONS
) (
  input  logic signed [WIDTH-1:0] x_in,          // full-precision input X
  input  logic signed [WIDTH-1:0] y_in,           // full-precision input Y
  output logic signed [WIDTH-1:0] k_prescale_x,   // round(K * x_in)
  output logic signed [WIDTH-1:0] k_prescale_y    // round(K * y_in)
);

  // Wide accumulator: |v| <= 32768, v*2488 ~ 8.15e7 < 2^27. Use WIDTH+FRACT_W+2
  // bits of headroom to hold the shifted partial products and the round bias.
  localparam int ACC_W = WIDTH + FRACT_W + 2;   // 30 bits for 16/12

  // Shift-add constant multiply by K_FACTOR (2488 = 2^11 + 2^9 - 2^6 - 2^3),
  // then round-to-nearest arithmetic shift right by FRACT_W.
  function automatic logic signed [WIDTH-1:0] k_prescale(input logic signed [WIDTH-1:0] v);
    logic signed [ACC_W-1:0] ext;
    logic signed [ACC_W-1:0] acc;
    ext = ACC_W'(v);                            // sign-extend to accumulator width
    acc = (ext <<< 11) + (ext <<< 9) - (ext <<< 6) - (ext <<< 3);
    acc = acc + (1 <<< (FRACT_W-1));            // round-to-nearest bias (+2048)
    acc = acc >>> FRACT_W;                      // arithmetic >> 12
    k_prescale = acc[WIDTH-1:0];
  endfunction

  always_comb begin
    k_prescale_x = k_prescale(x_in);
    k_prescale_y = k_prescale(y_in);
  end

endmodule
