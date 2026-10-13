`timescale 1ns/1ps
//==============================================================================
// Testbench: adaptive_equiv_tb
// Description: Independent verification harness proving bit-identical numerical
//              equivalence between Adaptive-11 (operating in mode n) and Fixed-n
//              for all n in [1, 11] across canonical stimulus set V_full (920 vectors).
//
// Owner: Agent B (Independent Verification)
// Wave: Phase 1 Verification
//==============================================================================

import cordic_pkg::*;

module adaptive_equiv_tb;

  localparam int WIDTH      = cordic_pkg::WIDTH;
  localparam int FRACT_W    = cordic_pkg::FRACT_W;
  localparam int ITERATIONS = 11;
  localparam int VALID_DEPTH = ITERATIONS + 1; // 12 cycles
  localparam int TIMEOUT     = VALID_DEPTH + 10;

  logic         clk, rst_n;
  cordic_data_t x_in, y_in, z_in;
  logic         valid_in, ready_out;
  logic [3:0]   cfg_iterations;
  logic         cfg_saturate, config_valid, config_ready;
  cordic_data_t x_out, y_out, z_out;
  logic         valid_out, ready_in, overflow, irq;
  logic         status_mode_clamped_sticky;

  cordic_top #(
    .WIDTH     (WIDTH),
    .FRACT_W   (FRACT_W),
    .ITERATIONS(ITERATIONS)
  ) dut (
    .clk                       (clk),
    .rst_n                     (rst_n),
    .x_in                      (x_in),
    .y_in                      (y_in),
    .z_in                      (z_in),
    .valid_in                  (valid_in),
    .ready_out                 (ready_out),
    .cfg_iterations            (cfg_iterations),
    .cfg_saturate              (cfg_saturate),
    .config_valid              (config_valid),
    .config_ready              (config_ready),
    .x_out                     (x_out),
    .y_out                     (y_out),
    .z_out                     (z_out),
    .valid_out                 (valid_out),
    .ready_in                  (ready_in),
    .overflow                  (overflow),
    .irq                       (irq),
    .status_mode_clamped_sticky(status_mode_clamped_sticky)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  int total_errors = 0;
  int total_checked = 0;

  task automatic reset_dut();
    rst_n        <= 1'b0;
    valid_in     <= 1'b0;
    ready_in     <= 1'b1;
    config_valid <= 1'b0;
    cfg_iterations <= 4'd11;
    cfg_saturate <= 1'b1;
    repeat (5) @(posedge clk);
    rst_n        <= 1'b1;
    repeat (2) @(posedge clk);
  endtask

  task automatic configure_mode(input [3:0] mode);
    @(negedge clk);
    cfg_iterations = mode;
    cfg_saturate   = 1'b1;
    config_valid   = 1'b1;
    @(posedge clk);
    while (!config_ready) @(posedge clk);
    @(negedge clk);
    config_valid   = 1'b0;
    @(posedge clk);
  endtask

  task automatic run_mode_test(input int mode);
    string vecfile;
    int fd, n_vectors, r;
    integer xi, yi, zi, sati, exi, eyi, ezi, eovfi;
    int mode_errors = 0;
    int mode_checked = 0;
    int timeout_cnt;

    vecfile = $sformatf("phase0/vectors/bitexact_check_iter%0d.mem", mode);
    fd = $fopen(vecfile, "r");
    if (fd == 0) begin
      $display("ERROR: Cannot open vector file: %s", vecfile);
      total_errors++;
      return;
    end

    r = $fscanf(fd, "%d\n", n_vectors);
    $display("--- Testing Mode %0d: %0d vectors from %s ---", mode, n_vectors, vecfile);

    configure_mode(4'(mode));

    while (!$feof(fd)) begin
      r = $fscanf(fd, "%d %d %d %d %d %d %d %d\n", xi, yi, zi, sati, exi, eyi, ezi, eovfi);
      if (r != 8) break;

      // Send vector
      @(negedge clk);
      x_in = 16'(xi);
      y_in = 16'(yi);
      z_in = 16'(zi);
      cfg_saturate = 1'(sati);
      config_valid = 1'b1; // same-cycle update per ARCH_SPEC
      cfg_iterations = 4'(mode);
      valid_in = 1'b1;
      ready_in = 1'b1;

      forever begin
        @(posedge clk);
        if (ready_out) break;
      end
      @(negedge clk);
      valid_in = 1'b0;
      config_valid = 1'b0;

      // Wait for output
      timeout_cnt = 0;
      while (!valid_out && timeout_cnt < TIMEOUT) begin
        @(posedge clk);
        timeout_cnt++;
      end

      if (!valid_out) begin
        $display("[FAIL] Mode %0d: Timeout waiting for valid_out on vector %0d", mode, mode_checked);
        mode_errors++;
      end else begin
        if (x_out !== 16'(exi) || y_out !== 16'(eyi) || z_out !== 16'(ezi) || overflow !== 1'(eovfi)) begin
          $display("[MISMATCH] Mode %0d Vec %0d: In=(%0d,%0d,%0d,sat=%0d) Exp=(%0d,%0d,%0d,ovf=%0d) Got=(%0d,%0d,%0d,ovf=%0d)",
                   mode, mode_checked, xi, yi, zi, sati, exi, eyi, ezi, eovfi,
                   x_out, y_out, z_out, overflow);
          mode_errors++;
        end
        @(posedge clk); // consume head
      end
      mode_checked++;
    end

    $fclose(fd);
    $display("Mode %0d Complete: %0d checked, %0d errors", mode, mode_checked, mode_errors);
    total_checked += mode_checked;
    total_errors  += mode_errors;
  endtask

  initial begin
    $display("=================================================================");
    $display("Starting Adaptive-11 vs Fixed-N Equivalence Regression Suite");
    $display("=================================================================");

    reset_dut();

    for (int m = 1; m <= 11; m++) begin
      run_mode_test(m);
    end

    $display("=================================================================");
    $display("Equivalence Regression Summary: %0d total vectors checked across 11 modes", total_checked);
    if (total_errors == 0) begin
      $display("RESULT: ALL 11 MODES BIT-IDENTICAL TO FIXED-N REFERENCES (PASS)");
    end else begin
      $display("RESULT: FAILED with %0d errors", total_errors);
      $fatal(1, "Equivalence check failed");
    end
    $display("=================================================================");
    $finish;
  end

endmodule
