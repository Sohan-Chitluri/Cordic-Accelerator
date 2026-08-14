`timescale 1ns/1ps
//==============================================================================
// Testbench: cordic_top_tb
// Description: Self-checking integration testbench for cordic_top (top-level
//              passthrough to cordic_pipeline). Verifies the top-level port
//              routing is correct via one 45° vector and a reset check.
// Owner: Verification Agent
// Wave: 4
//==============================================================================

module cordic_top_tb;
  import cordic_pkg::*;

  // 45° vector — same expected values as cordic_pipeline_tb
  localparam cordic_data_t V1_X   = 16'sd4096, V1_Y = 16'sd0,    V1_Z = 16'sd3217;
  localparam cordic_data_t V1_EX  = 16'sd2918, V1_EY = 16'sd2876, V1_EZ = 16'sd16;
  localparam logic         V1_EOVF = 1'b0;

  localparam int VALID_DEPTH = ITERATIONS + 2;
  localparam int TIMEOUT     = VALID_DEPTH + 6;

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
    .irq           (irq)
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

    if (errors != 0) $fatal(1, "FAIL: cordic_top — %0d error(s)", errors);
    else             $display("PASS: cordic_top");

    $finish;
  end

endmodule
