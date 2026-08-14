`timescale 1ns/1ps
//==============================================================================
// Testbench: cordic_pipeline_tb
// Description: Self-checking integration testbench for cordic_pipeline.
//              Verifies pipeline timing, backpressure, reset recovery, and
//              end-to-end arithmetic correctness for two known vectors.
//
//              Expected values computed by hand from golden model:
//                V1: x=4096, y=0, z=3217 (45°) → x_out=2918, y_out=2876, z_out=16
//                V2: x=4096, y=0, z=0    ( 0°) → x_out=4097, y_out=29,   z_out=23
// Owner: Verification Agent
// Wave: 3
//==============================================================================

module cordic_pipeline_tb;
  import cordic_pkg::*;

  // Known vector 1: 45° rotation
  localparam cordic_data_t V1_X   = 16'sd4096, V1_Y = 16'sd0,    V1_Z = 16'sd3217;
  localparam cordic_data_t V1_EX  = 16'sd2918, V1_EY = 16'sd2876, V1_EZ = 16'sd16;
  localparam logic         V1_EOVF = 1'b0;

  // Known vector 2: 0° rotation (z=0, convergence residual stays in x/y)
  localparam cordic_data_t V2_X   = 16'sd4096, V2_Y = 16'sd0,   V2_Z = 16'sd0;
  localparam cordic_data_t V2_EX  = 16'sd4097, V2_EY = 16'sd29, V2_EZ = 16'sd23;
  localparam logic         V2_EOVF = 1'b0;

  localparam int VALID_DEPTH = ITERATIONS + 2;  // 10
  localparam int TIMEOUT     = VALID_DEPTH + 6; // 16 — generous margin

  // DUT signals
  logic         clk, rst_n;
  cordic_data_t x_in, y_in, z_in;
  logic         valid_in, ready_out;
  logic [3:0]   cfg_iterations;
  logic         cfg_saturate, config_valid, config_ready;
  cordic_data_t x_out, y_out, z_out;
  logic         valid_out, ready_in, overflow, irq;
  int           errors;

  cordic_pipeline dut (
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
    .irq           (irq)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  // Apply cfg_saturate in one config cycle.
  task automatic apply_config(input logic sat);
    @(negedge clk);
    cfg_saturate = sat; cfg_iterations = 4'(ITERATIONS); config_valid = 1'b1;
    @(posedge clk); @(negedge clk);
    config_valid = 1'b0;
  endtask

  // Drive one vector into the pipeline for one clock cycle.
  task automatic send_vector(input cordic_data_t xi, yi, zi);
    @(negedge clk);
    x_in = xi; y_in = yi; z_in = zi; valid_in = 1'b1;
    @(posedge clk); @(negedge clk);
    valid_in = 1'b0;
  endtask

  // Poll for valid_out, returning when it fires (or recording a timeout error).
  task automatic wait_output(input string label);
    for (int i = 0; i < TIMEOUT; i++) begin
      @(posedge clk);
      if (valid_out) return;
    end
    $error("[cordic_pipeline] %s: timeout — valid_out not seen within %0d cycles",
           label, TIMEOUT);
    errors++;
  endtask

  task automatic chk(
    input string     label,
    input cordic_data_t ex, ey, ez,
    input logic         eovf
  );
    if (x_out !== ex) begin
      $error("[cordic_pipeline] %s: x_out=%0d exp=%0d", label, x_out, ex); errors++;
    end
    if (y_out !== ey) begin
      $error("[cordic_pipeline] %s: y_out=%0d exp=%0d", label, y_out, ey); errors++;
    end
    if (z_out !== ez) begin
      $error("[cordic_pipeline] %s: z_out=%0d exp=%0d", label, z_out, ez); errors++;
    end
    if (overflow !== eovf) begin
      $error("[cordic_pipeline] %s: overflow=%0b exp=%0b", label, overflow, eovf); errors++;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Test body
  // ---------------------------------------------------------------------------
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
      $error("[cordic_pipeline] T0:reset: outputs not cleared"); errors++;
    end

    // ---- Test 1: 45° rotation — end-to-end arithmetic ----
    apply_config(1'b1);
    send_vector(V1_X, V1_Y, V1_Z);
    wait_output("T1:45deg");
    chk("T1:45deg", V1_EX, V1_EY, V1_EZ, V1_EOVF);

    // ---- Test 2: 0° rotation — identity convergence residual ----
    send_vector(V2_X, V2_Y, V2_Z);
    wait_output("T2:0deg");
    chk("T2:0deg", V2_EX, V2_EY, V2_EZ, V2_EOVF);

    // ---- Test 3: Reset mid-flight clears valid_out ----
    send_vector(V1_X, V1_Y, V1_Z);
    repeat(4) @(posedge clk);        // vector is in-flight
    @(negedge clk); rst_n = 1'b0;
    repeat(3) @(posedge clk);        // wait for reset to propagate
    if (valid_out !== 1'b0) begin
      $error("[cordic_pipeline] T3:mid_reset: valid_out not cleared"); errors++;
    end
    @(negedge clk); rst_n = 1'b1;
    repeat(2) @(posedge clk);

    // ---- Test 4: Output not gated by ready_in (backpressure on input only) ----
    @(negedge clk); ready_in = 1'b0;  // block downstream from accepting
    apply_config(1'b1);
    send_vector(V1_X, V1_Y, V1_Z);
    wait_output("T4:backpressure_out");
    chk("T4:backpressure_out", V1_EX, V1_EY, V1_EZ, V1_EOVF);
    @(negedge clk); ready_in = 1'b1;

    // ---- Test 5: config_ready always asserted in V1; config captured ----
    @(negedge clk);
    if (config_ready !== 1'b1) begin
      $error("[cordic_pipeline] T5: config_ready should be 1"); errors++;
    end
    // Switch to wrap mode and back to verify config re-capture
    apply_config(1'b0);
    apply_config(1'b1);
    send_vector(V1_X, V1_Y, V1_Z);
    wait_output("T5:config_reapply");
    chk("T5:config_reapply", V1_EX, V1_EY, V1_EZ, V1_EOVF);

    if (errors != 0) $fatal(1, "FAIL: cordic_pipeline — %0d error(s)", errors);
    else             $display("PASS: cordic_pipeline");

    $finish;
  end

endmodule
