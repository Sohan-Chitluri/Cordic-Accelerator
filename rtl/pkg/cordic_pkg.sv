//==============================================================================
// Package: cordic_pkg
// Description: Single source of truth for all fixed-point types, constants,
//              and shared reference functions. Import with `import cordic_pkg::*;`.
// Owner: Architecture Agent (Lead)
// Wave: 0 (Foundation)
//==============================================================================

package cordic_pkg;

  // ---------------------------------------------------------------------------
  // PARAMETERS (fixed for V1 ASIC target)
  // ---------------------------------------------------------------------------
  parameter int WIDTH      = 16;
  parameter int FRACT_W    = 12;
  parameter int ITERATIONS = 8;

  localparam int STAGE_IDX_W = $clog2(ITERATIONS);

  // ---------------------------------------------------------------------------
  // TYPES
  // ---------------------------------------------------------------------------
  typedef logic signed [WIDTH-1:0]   cordic_data_t;
  typedef logic signed [WIDTH:0]     cordic_ext_t;    // +1 bit for overflow guard

  // ---------------------------------------------------------------------------
  // CONSTANTS
  // ---------------------------------------------------------------------------
  localparam cordic_data_t MAX_POS  = (1 << (WIDTH-1)) - 1;
  localparam cordic_data_t MIN_NEG  = -(1 << (WIDTH-1));
  localparam cordic_data_t ONE_FIX  = 1 << FRACT_W;
  localparam cordic_data_t HALF_FIX = 1 << (FRACT_W - 1);

  // K = 0.607252935 × 2^FRACT_W ≈ 2488 (8 iterations, FRACT_W=12)
  localparam cordic_data_t K_FACTOR = 16'sd2488;

  // atan(2^-i) × 2^FRACT_W reference table (FRACT_W=12).
  // Values: 3217, 1934, 1016, 515, 258, 129, 64, 32 for i=0..7.
  // cordic_stage embeds its own angle as a localparam nested-ternary for
  // maximum tool compatibility (avoids package-array indexing limitations).

  // ---------------------------------------------------------------------------
  // REFERENCE TASKS
  // Reference implementations used by formal/sim infrastructure.
  // RTL modules (fp_add_sub, cordic_stage) implement the same logic inline
  // as combinational assign statements for synthesis efficiency.
  // ---------------------------------------------------------------------------

  // Saturating addition with overflow flag
  task automatic sat_add(
    input  cordic_data_t a, b,
    input  logic         sat,
    output cordic_data_t result,
    output logic         overflow
  );
    logic signed [WIDTH:0] sum;
    sum = {a[WIDTH-1], a} + {b[WIDTH-1], b};   // sign-extend both operands
    if (sat && (sum[WIDTH] ^ sum[WIDTH-1])) begin
      // sum[WIDTH]=0 → positive overflow → MAX_POS
      // sum[WIDTH]=1 → negative overflow → MIN_NEG
      result   = sum[WIDTH] ? MIN_NEG : MAX_POS;
      overflow = 1'b1;
    end else begin
      result   = sum[WIDTH-1:0];
      overflow = sum[WIDTH] ^ sum[WIDTH-1];
    end
  endtask

  // Saturating subtraction with overflow flag
  task automatic sat_sub(
    input  cordic_data_t a, b,
    input  logic         sat,
    output cordic_data_t result,
    output logic         overflow
  );
    logic signed [WIDTH:0] diff;
    diff = {a[WIDTH-1], a} - {b[WIDTH-1], b};  // sign-extend both operands
    if (sat && (diff[WIDTH] ^ diff[WIDTH-1])) begin
      result   = diff[WIDTH] ? MIN_NEG : MAX_POS;
      overflow = 1'b1;
    end else begin
      result   = diff[WIDTH-1:0];
      overflow = diff[WIDTH] ^ diff[WIDTH-1];
    end
  endtask

  // Arithmetic right shift, round-to-nearest (round half up).
  // The rounding bias is added BEFORE the shift: (v + 2^(s-1)) >>> s.
  // Sign-extends to WIDTH+1 bits so the bias never overflows near MAX_POS.
  // Used by cordic_stage for the per-iteration shift; golden model matches.
  function automatic logic signed [WIDTH-1:0] asr(input logic signed [WIDTH-1:0] v, input int s);
    logic signed [WIDTH:0] ext;
    if (s <= 0) begin
      asr = v;
    end else begin
      ext = {v[WIDTH-1], v};
      ext = ext + (1 <<< (s - 1));   // round bias before shift
      ext = ext >>> s;
      asr = ext[WIDTH-1:0];
    end
  endfunction

  // Task form of the above (reference/formal use).
  task automatic arith_shift_right(
    input  cordic_data_t val,
    input  int           shift,
    output cordic_data_t result
  );
    result = asr(val, shift);
  endtask

endpackage
