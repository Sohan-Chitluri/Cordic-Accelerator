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

// Experiment 2b, step 3 (forced structure): a plain generate-based
// carry-select adder gets erased by synthesis -- Yosys's `flatten` merges
// it into the top-level combinational network, after which `abc -liberty`
// (even with -D/-constr; verified across an 800-11500ps sweep with
// byte-identical netlists produced) re-derives whatever is smallest for
// Sky130 HD, which is a maj3-based ripple chain, regardless of source
// RTL topology. `(* keep_hierarchy *)` on this submodule makes `flatten`
// leave its instances as opaque module boundaries, so ABC maps each one
// as its own bounded combinational block (real I/O port timing arcs, not
// mergeable into the surrounding network) instead of dissolving it back
// into one global 17-bit boolean network. This is a forced-structure
// workaround for a synthesis-flow limitation, not an RTL algorithm
// change -- see RESULTS.md Experiment 2(ii)/2b for the measurements that
// motivated it.
(* keep_hierarchy *)
module fp_csa_block #(
  parameter int BW = 4
) (
  input  logic [BW-1:0] a,
  input  logic [BW-1:0] b,
  output logic [BW-1:0] sum_c0,
  output logic [BW-1:0] sum_c1,
  output logic          cout_c0,
  output logic          cout_c1
);
  logic [BW:0] s0, s1;

  assign s0 = {1'b0, a} + {1'b0, b};
  assign s1 = {1'b0, a} + {1'b0, b} + 1'b1;

  assign sum_c0  = s0[BW-1:0];
  assign sum_c1  = s1[BW-1:0];
  assign cout_c0 = s0[BW];
  assign cout_c1 = s1[BW];
endmodule

module fp_add_sub #(
  parameter int WIDTH            = cordic_pkg::WIDTH,
  parameter int FRACT_W          = cordic_pkg::FRACT_W,
  parameter bit USE_CARRY_SELECT = 1'b1,
  // Carry-select block width in bits. See fp_csa_block above for why this
  // now uses forced-hierarchy submodule instances rather than plain
  // generate-block assigns (Experiment 2(ii) result).
  parameter int CSA_BLOCK         = 4
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
  localparam int EXT_W = WIDTH + 1;

  always_comb begin
    a_ext = {a[WIDTH-1], a};
    b_ext = {b[WIDTH-1], b};
  end

  // a_ext - b_ext == a_ext + (~b_ext) + 1 (mod 2^EXT_W), exact and not just
  // modular: a and b are each within [-2^(WIDTH-1), 2^(WIDTH-1)-1], so the
  // true sum/difference always has magnitude <= 2^WIDTH, exactly
  // representable in EXT_W = WIDTH+1 signed bits with no wraparound -- the
  // same fact the original a_ext +/- b_ext computation relied on. This lets
  // add and subtract share one carry-select adder with a variable initial
  // carry-in (op).
  logic [WIDTH:0] b_eff;
  logic           cin0;
  logic [WIDTH:0] sum_bits;

  assign b_eff = b_ext ^ {(WIDTH+1){op}};
  assign cin0  = op;

  generate
    if (USE_CARRY_SELECT) begin : g_csa
      localparam int NBLK = (EXT_W + CSA_BLOCK - 1) / CSA_BLOCK;
      logic [NBLK-1:0] blk_cin, blk_cout;

      for (genvar blk = 0; blk < NBLK; blk++) begin : g_block
        localparam int LO = blk * CSA_BLOCK;
        localparam int HI = ((LO + CSA_BLOCK) > EXT_W) ? (EXT_W - 1) : (LO + CSA_BLOCK - 1);
        localparam int BW = HI - LO + 1;

        logic [BW-1:0] sum_c0, sum_c1;
        logic          cout_c0, cout_c1;

        fp_csa_block #(.BW(BW)) u_block (
          .a       (a_ext[HI:LO]),
          .b       (b_eff[HI:LO]),
          .sum_c0  (sum_c0),
          .sum_c1  (sum_c1),
          .cout_c0 (cout_c0),
          .cout_c1 (cout_c1)
        );

        if (blk == 0) begin : g_cin_first
          assign blk_cin[blk] = cin0;
        end else begin : g_cin_rest
          assign blk_cin[blk] = blk_cout[blk-1];
        end

        assign sum_bits[HI:LO] = blk_cin[blk] ? sum_c1 : sum_c0;
        assign blk_cout[blk]   = blk_cin[blk] ? cout_c1 : cout_c0;
      end
    end else begin : g_ripple
      assign sum_bits = a_ext + b_eff + cin0;
    end
  endgenerate

  assign sum = signed'(sum_bits);

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
