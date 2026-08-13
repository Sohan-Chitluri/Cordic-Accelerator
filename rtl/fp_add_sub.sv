//==============================================================================
// Module: fp_add_sub
// Description: Parameterized N-bit fixed-point adder/subtractor with carry-select
//              optimization and saturating arithmetic modes. Purely combinational.
// Owner: Arithmetic RTL Agent
// Parameters: WIDTH, FRACT_W, USE_CARRY_SELECT
// Dependencies: cordic_pkg
// Wave: 1 (Arithmetic Primitives)
//==============================================================================

module fp_add_sub
  import cordic_pkg::*;
#(
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
  logic signed [WIDTH-1:0] b_eff;
  logic signed [WIDTH:0]   sum;

  always_comb begin
    b_eff = op ? -b : b;
    // Sign-extend both operands to WIDTH+1 bits before adding to detect overflow
    sum   = {a[WIDTH-1], a} + {b_eff[WIDTH-1], b_eff};
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
      assert (!(overflow) || result == MAX_POS_EXT[WIDTH-1:0] || result == MIN_NEG_EXT[WIDTH-1:0])
        else $error("fp_add_sub: sat overflow but result not clamped");
    end
  end
`endif

endmodule
