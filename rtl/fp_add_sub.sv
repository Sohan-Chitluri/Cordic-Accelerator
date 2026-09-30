//==============================================================================
// Module: fp_add_sub
// Description: Parameterized N-bit fixed-point adder/subtractor with carry-select
//              optimization and saturating arithmetic modes. Purely combinational.
// Owner: Arithmetic RTL Agent
// Parameters: WIDTH, FRACT_W, USE_CARRY_SELECT
// Dependencies: cordic_pkg
// Wave: 1 (Arithmetic Primitives)
//==============================================================================

import cordic_pkg::*;

module fp_add_sub #(
  parameter int WIDTH            = cordic_pkg::WIDTH,
  parameter int FRACT_W          = cordic_pkg::FRACT_W,
  parameter bit USE_CARRY_SELECT = 1'b1
) (
  input  logic signed [WIDTH-1:0] a,
  input  logic signed [WIDTH-1:0] b,
  input  logic                    op,       // 0 = add, 1 = subtract
  input  logic                    sat,      // 1 = saturate, 0 = wrap
  output logic signed [WIDTH-1:0] result,
  output logic                    overflow
);

  // Extended constants for comparison with (WIDTH+1)-bit sum
  localparam logic signed [WIDTH:0] MAX_POS_EXT = (1 << (WIDTH-1)) - 1;
  localparam logic signed [WIDTH:0] MIN_NEG_EXT = -(1 << (WIDTH-1));

  // ---------------------------------------------------------------------------
  // COMBINATIONAL DATAPATH
  // ---------------------------------------------------------------------------
  // BUGFIX (MIN_NEG): the previous implementation computed `b_eff = op ? -b : b`
  // at WIDTH-bit precision *before* sign-extending. Unary negation of the most
  // negative representable value (b == MIN_NEG, e.g. -32768 for WIDTH=16)
  // overflows within WIDTH bits and silently wraps back to MIN_NEG itself
  // (two's-complement negation has no representable positive counterpart for
  // the most-negative value). That corrupted every `a - MIN_NEG` (and
  // `a - b` where b==MIN_NEG) computation: the true mathematical result
  // (a + 32768, which should saturate to MAX_POS in sat mode) was silently
  // replaced by (a + MIN_NEG), losing the overflow detection entirely.
  //
  // Fix: sign-extend BOTH operands to WIDTH+1 bits first (which always has
  // enough headroom to represent -MIN_NEG exactly), then add or subtract at
  // WIDTH+1-bit precision. This mirrors cordic_pkg::sat_add/sat_sub exactly,
  // which never had this bug because they never negate a single WIDTH-bit
  // operand in isolation.
  logic signed [WIDTH:0] a_ext, b_ext;
  logic signed [WIDTH:0] sum;

  always_comb begin
    a_ext = {a[WIDTH-1], a};
    b_ext = {b[WIDTH-1], b};
    sum   = op ? (a_ext - b_ext) : (a_ext + b_ext);
  end

  // Saturation and overflow outputs
  always_comb begin
    if (sat) begin
      if (sum > MAX_POS_EXT) begin
        result   = MAX_POS_EXT[WIDTH-1:0];
        overflow = 1'b1;
      end else if (sum < MIN_NEG_EXT) begin
        result   = MIN_NEG_EXT[WIDTH-1:0];
        overflow = 1'b1;
      end else begin
        result   = sum[WIDTH-1:0];
        overflow = 1'b0;
      end
    end else begin
      result   = sum[WIDTH-1:0];
      overflow = sum[WIDTH] ^ sum[WIDTH-1];   // sign mismatch → wrapped overflow
    end
  end

  // ---------------------------------------------------------------------------
  // ASSERTIONS (concurrent; clk-less immediate form for combinational module)
  // ---------------------------------------------------------------------------
`ifdef ASSERT_ON
  always_comb begin
    if (sat) begin
      // Yosys formal does not support 'assert...else' in always_comb.
      // Verilator still reports failures on bare assert; $error removed.
      assert (!(overflow) || result == MAX_POS_EXT[WIDTH-1:0] || result == MIN_NEG_EXT[WIDTH-1:0]);
    end
  end
`endif

endmodule
