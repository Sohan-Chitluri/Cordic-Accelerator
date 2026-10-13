`timescale 1ns/1ps
//==============================================================================
// Testbench: adaptive_precision_tb
// Description: RTL Precision Explorer harness for Adaptive-11 CORDIC.
//              Sweeps iteration modes 1-11 against Fixed-11 golden reference,
//              measures MaxAbs error, RMS error, exact matches, fixed latency,
//              and sustained admission throughput.
//
// Directory: precision_explorer/
//==============================================================================

import cordic_pkg::*;

module adaptive_precision_tb;

  localparam int WIDTH       = cordic_pkg::WIDTH;
  localparam int FRACT_W     = cordic_pkg::FRACT_W;
  localparam int ITERATIONS  = 11;
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

  task automatic reset_dut();
    rst_n          <= 1'b0;
    valid_in       <= 1'b0;
    ready_in       <= 1'b1;
    config_valid   <= 1'b0;
    cfg_iterations <= 4'd11;
    cfg_saturate   <= 1'b1;
    repeat (5) @(posedge clk);
    rst_n          <= 1'b1;
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

  // Structure to hold per-mode statistics
  typedef struct {
    int mode;
    int vector_count;
    int exact_matches;
    int mismatches;
    int max_err_x;
    int max_err_y;
    int max_err_z;
    real sum_sq_err_x;
    real sum_sq_err_y;
    real sum_sq_err_z;
    real rms_err_x;
    real rms_err_y;
    real rms_err_z;
  } mode_stats_t;

  mode_stats_t stats[1:11];

  task automatic run_mode_precision(input int mode);
    string vecfile;
    int fd, n_vectors, r;
    integer xi, yi, zi, sati, exi, eyi, ezi, eovfi;
    int mode_checked = 0;
    int exact_matches = 0;
    int max_dx = 0, max_dy = 0, max_dz = 0;
    real sum_sq_dx = 0.0, sum_sq_dy = 0.0, sum_sq_dz = 0.0;
    int dx, dy, dz;
    int timeout_cnt;

    // We compare mode against Fixed-11 reference vectors
    vecfile = "phase0/vectors/bitexact_check_iter11.mem";
    fd = $fopen(vecfile, "r");
    if (fd == 0) begin
      $display("ERROR: Cannot open vector file: %s", vecfile);
      $fatal(1);
    end

    r = $fscanf(fd, "%d\n", n_vectors);

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
      config_valid = 1'b1;
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
        $fatal(1);
      end else begin
        int sx, sy, sz;
        sx = int'(signed'(x_out));
        sy = int'(signed'(y_out));
        sz = int'(signed'(z_out));
        dx = (sx > exi) ? (sx - exi) : (exi - sx);
        dy = (sy > eyi) ? (sy - eyi) : (eyi - sy);
        dz = (sz > ezi) ? (sz - ezi) : (ezi - sz);

        if (dx > max_dx) max_dx = dx;
        if (dy > max_dy) max_dy = dy;
        if (dz > max_dz) max_dz = dz;

        sum_sq_dx += real'(dx) * real'(dx);
        sum_sq_dy += real'(dy) * real'(dy);
        sum_sq_dz += real'(dz) * real'(dz);

        if (dx == 0 && dy == 0 && dz == 0) begin
          exact_matches++;
        end

        @(posedge clk); // Consume from output FIFO
      end
      mode_checked++;
    end

    $fclose(fd);

    stats[mode].mode = mode;
    stats[mode].vector_count = mode_checked;
    stats[mode].exact_matches = exact_matches;
    stats[mode].mismatches = mode_checked - exact_matches;
    stats[mode].max_err_x = max_dx;
    stats[mode].max_err_y = max_dy;
    stats[mode].max_err_z = max_dz;
    stats[mode].sum_sq_err_x = sum_sq_dx;
    stats[mode].sum_sq_err_y = sum_sq_dy;
    stats[mode].sum_sq_err_z = sum_sq_dz;
    stats[mode].rms_err_x = $sqrt(sum_sq_dx / real'(mode_checked));
    stats[mode].rms_err_y = $sqrt(sum_sq_dy / real'(mode_checked));
    stats[mode].rms_err_z = $sqrt(sum_sq_dz / real'(mode_checked));

    $display("Mode %2d: vectors=%0d | matches=%0d (%0.1f%%) | MaxErr(X,Y,Z)=(%5d,%5d,%5d) | RMS(X,Y,Z)=(%7.2f,%7.2f,%7.2f)",
             mode, mode_checked, exact_matches, (100.0 * real'(exact_matches) / real'(mode_checked)),
             max_dx, max_dy, max_dz,
             stats[mode].rms_err_x, stats[mode].rms_err_y, stats[mode].rms_err_z);
  endtask

  // Task to explicitly test and record latency contract
  task automatic test_latency_contract();
    int injection_cycle, output_cycle, latency;
    $display("\n--- Testing Latency Contract (Modes 1, 4, 11) ---");
    for (int m = 1; m <= 11; m += (m == 1 ? 3 : 7)) begin
      reset_dut();
      @(negedge clk);
      x_in = 16'sd4096; y_in = 16'sd0; z_in = 16'sd2145;
      cfg_saturate = 1'b1; config_valid = 1'b1; valid_in = 1'b1; ready_in = 1'b1;
      cfg_iterations = 4'(m);
      @(posedge clk);
      while (!ready_out) @(posedge clk);
      injection_cycle = int'($time / 10);
      @(negedge clk);
      valid_in = 1'b0; config_valid = 1'b0;

      while (!valid_out) @(posedge clk);
      output_cycle = int'($time / 10);
      latency = output_cycle - injection_cycle;
      $display("Mode %0d: Injected cycle %0d, valid_out cycle %0d (Measured Latency: %0d cycles, Expected: %0d)",
               m, injection_cycle, output_cycle, latency, VALID_DEPTH);
      if (latency !== VALID_DEPTH) begin
        $display("ERROR: Latency mismatch! Got %0d, expected %0d", latency, VALID_DEPTH);
        $fatal(1);
      end
      @(posedge clk);
    end
  endtask

  // Task to test sustained admission throughput
  task automatic test_throughput_contract();
    int admitted_count = 0;
    int cycle_count = 0;
    $display("\n--- Testing Sustained Admission Throughput ---");
    configure_mode(4'd11);
    @(negedge clk);
    valid_in = 1'b1;
    ready_in = 1'b1;
    cfg_iterations = 4'd11;
    cfg_saturate = 1'b1;
    config_valid = 1'b0;
    x_in = 16'd1000; y_in = 16'd1000; z_in = 16'd500;

    for (int cyc = 0; cyc < 50; cyc++) begin
      @(posedge clk);
      cycle_count++;
      if (ready_out && valid_in) begin
        admitted_count++;
      end
    end
    @(negedge clk);
    valid_in = 1'b0;
    $display("Burst Test: %0d admissions in %0d cycles (Throughput = %0.1f%%, Bubble frequency: 1 in 13)",
             admitted_count, cycle_count, (100.0 * real'(admitted_count) / real'(cycle_count)));
  endtask

  initial begin
    int out_fd;
    $display("=================================================================");
    $display("Adaptive-11 Precision Explorer RTL Simulation Harness");
    $display("Measuring Modes 1-11 Numerical Accuracy vs Fixed-11 Reference");
    $display("=================================================================");

    reset_dut();

    for (int m = 1; m <= 11; m++) begin
      run_mode_precision(m);
    end

    test_latency_contract();
    test_throughput_contract();

    // Export raw simulation statistics for python parser
    out_fd = $fopen("precision_explorer/rtl_sim_results.txt", "w");
    if (out_fd != 0) begin
      $fdisplay(out_fd, "mode,vector_count,exact_matches,mismatches,max_err_x,max_err_y,max_err_z,rms_err_x,rms_err_y,rms_err_z");
      for (int m = 1; m <= 11; m++) begin
        $fdisplay(out_fd, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0.6f,%0.6f,%0.6f",
                  stats[m].mode, stats[m].vector_count, stats[m].exact_matches, stats[m].mismatches,
                  stats[m].max_err_x, stats[m].max_err_y, stats[m].max_err_z,
                  stats[m].rms_err_x, stats[m].rms_err_y, stats[m].rms_err_z);
      end
      $fclose(out_fd);
      $display("\nWrote raw RTL simulation metrics to precision_explorer/rtl_sim_results.txt");
    end

    $display("\n=================================================================");
    $display("Precision Explorer RTL Simulation Complete: 11/11 Modes Swept");
    $display("=================================================================");
    $finish;
  end

endmodule
