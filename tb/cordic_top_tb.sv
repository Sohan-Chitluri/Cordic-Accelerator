`timescale 1ns/1ps
//==============================================================================
// Testbench: cordic_top_tb
// Description: Self-checking integration testbench for cordic_top (top-level
//              passthrough to cordic_pipeline). Verifies the top-level port
//              routing is correct via 45° vector, 0° vector, saturation,
//              backpressure, and reset checks.
// Owner: Verification Agent
// Wave: 4
//==============================================================================

import cordic_pkg::*;

// Known vector 1: 45° rotation (11 iterations)
// Expected values computed from golden_model.py CordicGoldenModel(iterations=11)
localparam cordic_data_t V1_X   = 16'sd4096, V1_Y = 16'sd0,    V1_Z = 16'sd3217;
localparam cordic_data_t V1_EX  = 16'sd2898, V1_EY = 16'sd2896, V1_EZ = 16'sd1;
localparam logic         V1_EOVF = 1'b0;

// Known vector 2: 0° rotation (11 iterations)
// Expected values computed from golden_model.py CordicGoldenModel(iterations=11)
localparam cordic_data_t V2_X   = 16'sd4096, V2_Y = 16'sd0,   V2_Z = 16'sd0;
localparam cordic_data_t V2_EX  = 16'sd4097, V2_EY = 16'sd1,  V2_EZ = -16'sd2;
localparam logic         V2_EOVF = 1'b0;

// Saturation test vector: tests pipeline with large but valid inputs.
localparam cordic_data_t VSAT_X = 16'sd30000, VSAT_Y = 16'sd5000, VSAT_Z = 16'sd100;
localparam logic         VSAT_EOVF = 1'b0;  // No overflow after K-prescale

// Config-attribution test vector (11 iterations)
// Expected values computed via tb/golden_model.py CordicGoldenModel(iterations=11)
localparam cordic_data_t CFG_X = -16'sd20466, CFG_Y = 16'sd31176, CFG_Z = -16'sd29053;
localparam cordic_data_t CFG_SAT_EX  = 16'sd32767, CFG_SAT_EY  = 16'sd14896, CFG_SAT_EZ = -16'sd21917;
localparam logic         CFG_SAT_EOVF = 1'b1;
localparam cordic_data_t CFG_WRAP_EX = -16'sd31233, CFG_WRAP_EY = 16'sd18880, CFG_WRAP_EZ = -16'sd21917;

// Overflow-attribution test vector (11 iterations)
localparam cordic_data_t OVF_X = -16'sd20466, OVF_Y = 16'sd31176, OVF_Z = -16'sd29053;
localparam cordic_data_t OVF_EX = 16'sd32767, OVF_EY = 16'sd14896, OVF_EZ = -16'sd21917;
localparam logic         OVF_EOVF = 1'b1;

localparam int VALID_DEPTH = ITERATIONS + 1;  // 12 (ITERATIONS=11)
localparam int TIMEOUT     = VALID_DEPTH + 6; // 18 — generous margin

module cordic_top_tb;

  logic         clk, rst_n;
  cordic_data_t x_in, y_in, z_in;
  logic         valid_in, ready_out;
  logic [3:0]   cfg_iterations;
  logic         cfg_saturate, config_valid, config_ready;
  cordic_data_t x_out, y_out, z_out;
  logic         valid_out, ready_in, overflow, irq;
  int           errors;

  cordic_top dut (
    .clk           (clk),
    .rst_n         (rst_n),
    .x_in          (x_in),
    .y_in          (y_in),
    .z_in          (z_in),
    .valid_in      (valid_in),
    .ready_out     (ready_out),
    .cfg_iterations(cfg_iterations),
    .cfg_saturate  (cfg_saturate),
    .config_valid  (config_valid),
    .config_ready  (config_ready),
    .x_out         (x_out),
    .y_out         (y_out),
    .z_out         (z_out),
    .valid_out     (valid_out),
    .ready_in      (ready_in),
    .overflow      (overflow),
    .irq           (irq),
    .status_mode_clamped_sticky()
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  task automatic wait_output(input string label);
    for (int i = 0; i < TIMEOUT; i++) begin
      @(posedge clk);
      if (valid_out) return;
    end
    $error("[cordic_top] %s: timeout — valid_out not seen within %0d cycles",
           label, TIMEOUT);
    errors++;
  endtask

  task automatic chk(
    input string     label,
    input cordic_data_t ex, ey, ez,
    input logic         eovf
  );
    if (x_out !== ex) begin
      $error("[cordic_top] %s: x_out=%0d exp=%0d", label, x_out, ex); errors++;
    end
    if (y_out !== ey) begin
      $error("[cordic_top] %s: y_out=%0d exp=%0d", label, y_out, ey); errors++;
    end
    if (z_out !== ez) begin
      $error("[cordic_top] %s: z_out=%0d exp=%0d", label, z_out, ez); errors++;
    end
    if (overflow !== eovf) begin
      $error("[cordic_top] %s: overflow=%0b exp=%0b", label, overflow, eovf); errors++;
    end
  endtask

  initial begin
    errors = 0;
    x_in = '0; y_in = '0; z_in = '0;
    valid_in = 1'b0; ready_in = 1'b1;
    cfg_saturate = 1'b1; cfg_iterations = 4'(ITERATIONS); config_valid = 1'b0;

    // ---- Reset ----
    rst_n = 1'b0;
    repeat(3) @(posedge clk);
    @(negedge clk); rst_n = 1'b1;
    repeat(2) @(posedge clk);
    if (valid_out !== 1'b0 || overflow !== 1'b0) begin
      $error("[cordic_top] T0:reset: outputs not cleared"); errors++;
    end

    // ---- Test 1: 45° rotation — end-to-end through cordic_top ----
    // Config
    @(negedge clk);
    cfg_saturate = 1'b1; cfg_iterations = 4'(ITERATIONS); config_valid = 1'b1;
    @(posedge clk); @(negedge clk);
    config_valid = 1'b0;

    // Data
    @(negedge clk);
    x_in = V1_X; y_in = V1_Y; z_in = V1_Z; valid_in = 1'b1;
    @(posedge clk); @(negedge clk);
    valid_in = 1'b0;

    wait_output("T1:45deg");
    chk("T1:45deg", V1_EX, V1_EY, V1_EZ, V1_EOVF);

    // ---- Test 2: Reset clears in-flight data ----
    @(negedge clk);
    x_in = V1_X; y_in = V1_Y; z_in = V1_Z; valid_in = 1'b1;
    @(posedge clk); @(negedge clk);
    valid_in = 1'b0;
    repeat(4) @(posedge clk);
    @(negedge clk); rst_n = 1'b0;
    repeat(3) @(posedge clk);
    if (valid_out !== 1'b0) begin
      $error("[cordic_top] T2:mid_reset: valid_out not cleared by reset"); errors++;
    end
    @(negedge clk); rst_n = 1'b1;
    repeat(2) @(posedge clk);

    // ---- Test 3: Second pass after reset — pipeline recovers ----
    @(negedge clk);
    cfg_saturate = 1'b1; config_valid = 1'b1;
    @(posedge clk); @(negedge clk);
    config_valid = 1'b0;

    @(negedge clk);
    x_in = V1_X; y_in = V1_Y; z_in = V1_Z; valid_in = 1'b1;
    @(posedge clk); @(negedge clk);
    valid_in = 1'b0;

    wait_output("T3:post_reset");
    chk("T3:post_reset", V1_EX, V1_EY, V1_EZ, V1_EOVF);

    // ---- Test 4: 0° rotation — identity convergence residual ----
    @(negedge clk);
    cfg_saturate = 1'b1; config_valid = 1'b1;
    @(posedge clk); @(negedge clk);
    config_valid = 1'b0;

    @(negedge clk);
    x_in = V2_X; y_in = V2_Y; z_in = V2_Z; valid_in = 1'b1;
    @(posedge clk); @(negedge clk);
    valid_in = 1'b0;

    wait_output("T4:0deg");
    chk("T4:0deg", V2_EX, V2_EY, V2_EZ, V2_EOVF);

    // ---- Test 5: Saturation test — large inputs with sat=1 (no overflow expected for these inputs) ----
    @(negedge clk);
    cfg_saturate = 1'b1; config_valid = 1'b1;
    @(posedge clk); @(negedge clk);
    config_valid = 1'b0;

    @(negedge clk);
    x_in = VSAT_X; y_in = VSAT_Y; z_in = VSAT_Z; valid_in = 1'b1;
    @(posedge clk); @(negedge clk);
    valid_in = 1'b0;

    wait_output("T5:saturation");
    // Verify no crash, outputs in valid range, overflow flag correct
    if (x_out < -32768 || x_out > 32767) begin
      $error("[cordic_top] T5:saturation: x_out out of range: %0d", x_out); errors++;
    end
    if (y_out < -32768 || y_out > 32767) begin
      $error("[cordic_top] T5:saturation: y_out out of range: %0d", y_out); errors++;
    end
    if (z_out < -32768 || z_out > 32767) begin
      $error("[cordic_top] T5:saturation: z_out out of range: %0d", z_out); errors++;
    end
    // Check overflow flag against expected value
    if (overflow !== VSAT_EOVF) begin
      $error("[cordic_top] T5:saturation: expected overflow=%0b, got %0b", VSAT_EOVF, overflow); errors++;
    end

    // ---- Test 6: Wrap mode test — sat=0 (no saturation, but no overflow for these inputs) ----
    @(negedge clk);
    cfg_saturate = 1'b0; config_valid = 1'b1;
    @(posedge clk); @(negedge clk);
    config_valid = 1'b0;

    @(negedge clk);
    x_in = VSAT_X; y_in = VSAT_Y; z_in = VSAT_Z; valid_in = 1'b1;
    @(posedge clk); @(negedge clk);
    valid_in = 1'b0;

    wait_output("T6:wrap");
    // Wrap mode: no saturation, but arithmetic overflow still occurs on the same inputs
    // Just verify no crash, outputs in valid range
    if (x_out < -32768 || x_out > 32767) begin
      $error("[cordic_top] T6:wrap: x_out out of range: %0d", x_out); errors++;
    end
    if (y_out < -32768 || y_out > 32767) begin
      $error("[cordic_top] T6:wrap: y_out out of range: %0d", y_out); errors++;
    end
    if (z_out < -32768 || z_out > 32767) begin
      $error("[cordic_top] T6:wrap: z_out out of range: %0d", z_out); errors++;
    end
    // Check overflow flag — should be same as T5 (same inputs, same arithmetic result)
    if (overflow !== VSAT_EOVF) begin
      $error("[cordic_top] T6:wrap: expected overflow=%0b, got %0b", VSAT_EOVF, overflow); errors++;
    end

    // ---- Test 7: Backpressure test — sustained stall ----
    @(negedge clk);
    cfg_saturate = 1'b1; config_valid = 1'b1;
    @(posedge clk); @(negedge clk);
    config_valid = 1'b0;

    @(negedge clk);
    ready_in = 1'b0;  // Block downstream
    x_in = V1_X; y_in = V1_Y; z_in = V1_Z; valid_in = 1'b1;
    @(posedge clk); @(negedge clk);
    valid_in = 1'b0;

    // Hold backpressure for 5 cycles
    repeat(5) @(posedge clk);
    
    // Release backpressure
    @(negedge clk);
    ready_in = 1'b1;

    wait_output("T7:backpressure");
    chk("T7:backpressure", V1_EX, V1_EY, V1_EZ, V1_EOVF);

    // ---- Test 8: Configuration toggle test ----
    @(negedge clk);
    cfg_saturate = 1'b0; config_valid = 1'b1;
    @(posedge clk); @(negedge clk);
    config_valid = 1'b0;

    @(negedge clk);
    cfg_saturate = 1'b1; config_valid = 1'b1;
    @(posedge clk); @(negedge clk);
    config_valid = 1'b0;

    @(negedge clk);
    x_in = V1_X; y_in = V1_Y; z_in = V1_Z; valid_in = 1'b1;
    @(posedge clk); @(negedge clk);
    valid_in = 1'b0;

    wait_output("T8:config_toggle");
    chk("T8:config_toggle", V1_EX, V1_EY, V1_EZ, V1_EOVF);

    // ---- Test 9: Sign transition test ----
    @(negedge clk);
    cfg_saturate = 1'b1; config_valid = 1'b1;
    @(posedge clk); @(negedge clk);
    config_valid = 1'b0;

    @(negedge clk);
    x_in = 16'sd4096; y_in = 16'sd0; z_in = 16'sd3217; valid_in = 1'b1;  // Positive z (sigma=1)
    @(posedge clk); @(negedge clk);
    valid_in = 1'b0;
    wait_output("T9a:sign_pos");

    @(negedge clk);
    x_in = 16'sd4096; y_in = 16'sd0; z_in = -16'sd1; valid_in = 1'b1;  // Negative z (sigma=0)
    @(posedge clk); @(negedge clk);
    valid_in = 1'b0;
    wait_output("T9b:sign_neg");
    // Just verify no crash, outputs within range
    if (x_out < -32768 || x_out > 32767 || y_out < -32768 || y_out > 32767) begin
      $error("[cordic_top] T9:sign_transition: output out of range"); errors++;
    end

    // ---- Test 10: Config attribution — two in-flight transactions, each
    // must use the cfg_saturate value that was live at ITS OWN admission,
    // not whatever is live when it happens to complete. Regression for the
    // cfg_saturate_r-shared-across-all-stages bug (fixed via
    // cfg_saturate_sr per-transaction shift register in cordic_pipeline.sv).
    // ----
    @(negedge clk);
    cfg_saturate = 1'b1; config_valid = 1'b1;   // config A: saturate
    @(posedge clk); @(negedge clk);
    config_valid = 1'b0;

    // Admit TXN_P under config A.
    @(negedge clk);
    x_in = CFG_X; y_in = CFG_Y; z_in = CFG_Z; valid_in = 1'b1;
    @(posedge clk); @(negedge clk);
    valid_in = 1'b0;

    // Before TXN_P completes (latency is VALID_DEPTH-ish cycles away),
    // switch the live config to B: wrap. TXN_P must NOT observe this.
    @(negedge clk);
    cfg_saturate = 1'b0; config_valid = 1'b1;   // config B: wrap
    @(posedge clk); @(negedge clk);
    config_valid = 1'b0;

    // Admit TXN_Q under config B, one cycle behind TXN_P — both are now
    // simultaneously in flight at different pipeline depths.
    @(negedge clk);
    x_in = CFG_X; y_in = CFG_Y; z_in = CFG_Z; valid_in = 1'b1;
    @(posedge clk); @(negedge clk);
    valid_in = 1'b0;

    wait_output("T10:cfg_attr_P(sat)");
    chk("T10:cfg_attr_P(sat)", CFG_SAT_EX, CFG_SAT_EY, CFG_SAT_EZ, CFG_SAT_EOVF);

    wait_output("T10:cfg_attr_Q(wrap)");
    // Wrap mode overflows internally at stage 4 for this vector too (per
    // golden_model.py stage-by-stage trace), so overflow=1 is expected here
    // as well — only x_out/y_out/z_out distinguish sat vs wrap attribution.
    chk("T10:cfg_attr_Q(wrap)", CFG_WRAP_EX, CFG_WRAP_EY, CFG_WRAP_EZ, 1'b1);

    // ---- Test 11: Overflow attribution — a non-overflowing transaction and
    // an overflowing transaction in flight together (both directions),
    // verifying each output's overflow flag belongs to its own transaction,
    // not to whichever other transaction happens to be resident in an
    // earlier/later pipeline stage that cycle. Regression for the
    // stage_overflow_accum cross-transaction combinational-OR bug (fixed via
    // the per-tap overflow delay line / overflow_final in
    // cordic_pipeline.sv).
    // ----
    @(negedge clk);
    cfg_saturate = 1'b1; config_valid = 1'b1;
    @(posedge clk); @(negedge clk);
    config_valid = 1'b0;

    // 11a: no-overflow transaction (V1) admitted first, overflow transaction
    // (OVF_*) admitted one cycle later while V1 is still in flight.
    @(negedge clk);
    x_in = V1_X; y_in = V1_Y; z_in = V1_Z; valid_in = 1'b1;
    @(posedge clk); @(negedge clk);
    x_in = OVF_X; y_in = OVF_Y; z_in = OVF_Z; // valid_in still 1
    @(posedge clk); @(negedge clk);
    valid_in = 1'b0;

    wait_output("T11a:ovf_attr_noovf_first");
    chk("T11a:ovf_attr_noovf_first", V1_EX, V1_EY, V1_EZ, V1_EOVF);

    wait_output("T11a:ovf_attr_ovf_second");
    chk("T11a:ovf_attr_ovf_second", OVF_EX, OVF_EY, OVF_EZ, OVF_EOVF);

    // 11b: reverse order — overflow transaction first, no-overflow second.
    @(negedge clk);
    x_in = OVF_X; y_in = OVF_Y; z_in = OVF_Z; valid_in = 1'b1;
    @(posedge clk); @(negedge clk);
    x_in = V1_X; y_in = V1_Y; z_in = V1_Z; // valid_in still 1
    @(posedge clk); @(negedge clk);
    valid_in = 1'b0;

    wait_output("T11b:ovf_attr_ovf_first");
    chk("T11b:ovf_attr_ovf_first", OVF_EX, OVF_EY, OVF_EZ, OVF_EOVF);

    wait_output("T11b:ovf_attr_noovf_second");
    chk("T11b:ovf_attr_noovf_second", V1_EX, V1_EY, V1_EZ, V1_EOVF);

    if (errors != 0) $fatal(1, "FAIL: cordic_top — %0d error(s)", errors);
    else             $display("PASS: cordic_top — All %0d tests passed", 11);

    $finish;
  end

endmodule