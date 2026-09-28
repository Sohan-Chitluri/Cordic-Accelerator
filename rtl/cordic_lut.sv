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

  // ---------------------------------------------------------------------------
  // PARAMETER DOMAIN GUARD
  // ---------------------------------------------------------------------------
  // The shift-add network below (<<11, <<9, <<6, <<3) realizes multiplication
  // by the literal constant 2488, which is round(K * 2^12) -- i.e. it is only
  // a valid K-factor approximation when FRACT_W == 12. For any other FRACT_W
  // this shift-add network multiplies by the wrong K entirely (root cause of
  // the reported 16/10/8, 32/24/8, 8/4/8, 4/1/8 failures for this module).
  // Rescaling the shift-add constant per FRACT_W would require either a real
  // multiplier (forbidden by ADR-0002) or re-deriving a new set of shift
  // amounts for every FRACT_W -- not attempted here (see cordic_stage.sv's
  // matching guard for the full rationale). FRACT_W is therefore a fixed
  // architectural constant; any other value must fail elaboration loudly.
  localparam bit FRACT_W_SUPPORTED = (FRACT_W == 12);
  localparam int unsigned STATIC_ASSERT_LUT_DOMAIN = FRACT_W_SUPPORTED ? 1 : 1/0;

  initial begin
    if (!FRACT_W_SUPPORTED) begin
      $fatal(1, "cordic_lut: unsupported FRACT_W=%0d (only FRACT_W=12 is supported; the K_FACTOR shift-add network realizes round(K*4096) specifically)", FRACT_W);
    end
  end

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
