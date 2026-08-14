`timescale 1ns/1ps
//==============================================================================
// Testbench: cordic_stage_tb
// Description: Self-checking unit testbench for cordic_stage (STAGE_IDX=0,
//              sequential, 1-cycle latency). Expected values computed via
//              cordic_pkg tasks to mirror RTL datapath exactly.
// Owner: Verification Agent
// Wave: 2
//==============================================================================

module cordic_stage_tb;
  import cordic_pkg::*;

  // STAGE_IDX=0: atan(2^0)=45°, angle=3217, shift=0 (asr(v,0)=v)
  localparam int          STAGE_IDX   = 0;
  localparam cordic_data_t STAGE_ANGLE = 16'sd3217;

  // DUT signals
  logic         clk, rst_n;
  cordic_data_t x_in, y_in, z_in;
  logic         valid_in, sat;
  cordic_data_t x_out, y_out, z_out;
  logic         valid_out, overflow;

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

  initial clk = 1'b0;
  always #5 clk = ~clk;

  // ---------------------------------------------------------------------------
  // Expected output registers (written before posedge, checked after negedge)
  // ---------------------------------------------------------------------------
  cordic_data_t exp_x, exp_y, exp_z;
  logic         exp_ovf, exp_valid;
  int           errors;

  // Mirrors cordic_stage combinational logic for STAGE_IDX=0.
  // asr(v, 0) = v (s<=0 early return), so shifts are identity here.
  task automatic compute_expected(
    input  cordic_data_t xi, yi, zi,
    input  logic         sat_mode,
    input  logic         vin,
    output cordic_data_t ex, ey, ez,
    output logic         eovf, evalid
  );
    logic         sigma;
    cordic_data_t x_sh, y_sh, xm, ym, zb, dummy_r;
    logic         ox, oy, dummy_o;
    sigma = ~zi[WIDTH-1];
    x_sh  = asr(xi, STAGE_IDX);   // = xi (shift=0)
    y_sh  = asr(yi, STAGE_IDX);   // = yi
    xm    = sigma ? x_sh : -x_sh;
    ym    = sigma ? y_sh : -y_sh;
    sat_sub(xi, ym, sat_mode, ex, ox);        // x_new = x - y_mux
    sat_add(yi, xm, sat_mode, ey, oy);        // y_new = y + x_mux
    zb    = sigma ? STAGE_ANGLE : -STAGE_ANGLE;
    sat_sub(zi, zb, 1'b0, ez, dummy_o);       // z wraps (sat=0)
    eovf   = ox | oy;
    evalid = vin;
  endtask

  task automatic chk_stage(input string label);
    if (x_out !== exp_x) begin
      $error("[cordic_stage] %s: x_out=%0d exp=%0d", label, x_out, exp_x); errors++;
    end
    if (y_out !== exp_y) begin
      $error("[cordic_stage] %s: y_out=%0d exp=%0d", label, y_out, exp_y); errors++;
    end
    if (z_out !== exp_z) begin
      $error("[cordic_stage] %s: z_out=%0d exp=%0d", label, z_out, exp_z); errors++;
    end
    if (overflow !== exp_ovf) begin
      $error("[cordic_stage] %s: overflow=%0b exp=%0b", label, overflow, exp_ovf); errors++;
    end
    if (valid_out !== exp_valid) begin
      $error("[cordic_stage] %s: valid_out=%0b exp=%0b", label, valid_out, exp_valid); errors++;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Test body
  // ---------------------------------------------------------------------------
  initial begin
    errors   = 0;
    x_in     = '0; y_in = '0; z_in = '0;
    valid_in = 1'b0; sat = 1'b1;

    // Reset
    rst_n = 1'b0;
    @(posedge clk); @(negedge clk);
    if (x_out !== '0 || y_out !== '0 || z_out !== '0 || valid_out !== 1'b0 || overflow !== 1'b0) begin
      $error("[cordic_stage] reset: outputs not cleared"); errors++;
    end
    rst_n = 1'b1;

    // ---- Test 1: positive z (sigma=1), no overflow ----
    // x=1000, y=500, z=3217 → x_new=500, y_new=1500, z_new=0, ovf=0
    @(negedge clk);
    x_in = 16'sd1000; y_in = 16'sd500; z_in = 16'sd3217;
    sat = 1'b1; valid_in = 1'b1;
    compute_expected(x_in, y_in, z_in, sat, valid_in,
                     exp_x, exp_y, exp_z, exp_ovf, exp_valid);
    @(posedge clk); @(negedge clk);
    chk_stage("T1:sigma=1_no_ovf");

    // ---- Test 2: negative z (sigma=0), no overflow ----
    // x=1000, y=500, z=-1 → x_new=1500, y_new=-500, z_new=3216, ovf=0
    @(negedge clk);
    x_in = 16'sd1000; y_in = 16'sd500; z_in = -16'sd1;
    sat = 1'b1; valid_in = 1'b1;
    compute_expected(x_in, y_in, z_in, sat, valid_in,
                     exp_x, exp_y, exp_z, exp_ovf, exp_valid);
    @(posedge clk); @(negedge clk);
    chk_stage("T2:sigma=0_no_ovf");

    // ---- Test 3: positive z, y-path saturates ----
    // x=30000, y=5000, z=100 → y_new=35000 → MAX_POS, ovf=1
    @(negedge clk);
    x_in = 16'sd30000; y_in = 16'sd5000; z_in = 16'sd100;
    sat = 1'b1; valid_in = 1'b1;
    compute_expected(x_in, y_in, z_in, sat, valid_in,
                     exp_x, exp_y, exp_z, exp_ovf, exp_valid);
    @(posedge clk); @(negedge clk);
    chk_stage("T3:y_saturates");

    // ---- Test 4: valid_in=0 propagates as valid_out=0 ----
    @(negedge clk);
    x_in = 16'sd100; y_in = 16'sd200; z_in = 16'sd50;
    sat = 1'b1; valid_in = 1'b0;
    compute_expected(x_in, y_in, z_in, sat, valid_in,
                     exp_x, exp_y, exp_z, exp_ovf, exp_valid);
    @(posedge clk); @(negedge clk);
    chk_stage("T4:valid_in=0");

    // ---- Test 5: reset mid-stream clears outputs ----
    @(negedge clk);
    x_in = 16'sd5000; y_in = 16'sd3000; z_in = 16'sd2000;
    sat = 1'b1; valid_in = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rst_n = 1'b0;
    @(posedge clk); @(negedge clk);
    if (x_out !== '0 || y_out !== '0 || z_out !== '0 || valid_out !== 1'b0 || overflow !== 1'b0) begin
      $error("[cordic_stage] T5:mid_reset: outputs not cleared after rst_n=0"); errors++;
    end
    rst_n = 1'b1;

    if (errors != 0) $fatal(1, "FAIL: cordic_stage — %0d error(s)", errors);
    else        $display("PASS: cordic_stage");

    $finish;
  end

endmodule
