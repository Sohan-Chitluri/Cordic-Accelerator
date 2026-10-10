`timescale 1ns/1ps

module gl_power_sim_tb;
  reg clk;
  reg rst_n;
  reg signed [15:0] x_in, y_in, z_in;
  reg valid_in;
  wire ready_out;
  reg [3:0] cfg_iterations;
  reg cfg_saturate;
  reg config_valid;
  wire config_ready;
  wire signed [15:0] x_out, y_out, z_out;
  wire valid_out;
  reg ready_in;
  wire overflow, irq;

  cordic_top dut (
    .clk(clk),
    .rst_n(rst_n),
    .x_in(x_in),
    .y_in(y_in),
    .z_in(z_in),
    .valid_in(valid_in),
    .ready_out(ready_out),
    .cfg_iterations(cfg_iterations),
    .cfg_saturate(cfg_saturate),
    .config_valid(config_valid),
    .config_ready(config_ready),
    .x_out(x_out),
    .y_out(y_out),
    .z_out(z_out),
    .valid_out(valid_out),
    .ready_in(ready_in),
    .overflow(overflow),
    .irq(irq)
  );

  initial clk = 1'b0;
  always #7.5 clk = ~clk; // 15.0 ns period

  integer fd, n_vecs, v, r, test_iter;
  integer xi, yi, zi, sati, exi, eyi, ezi, eovfi;
  reg [1023:0] vecfile_name;
  reg [1023:0] vcdfile_name;

  initial begin
    if (!$value$plusargs("VECFILE=%s", vecfile_name))
      vecfile_name = "phase0/vectors/bitexact_check_iter4.mem";

    if (!$value$plusargs("VCDFILE=%s", vcdfile_name))
      vcdfile_name = "power_sim.vcd";

    $dumpfile(vcdfile_name);
    $dumpvars(0, gl_power_sim_tb.dut);

    rst_n = 1'b0;
    valid_in = 1'b0;
    ready_in = 1'b1;
    config_valid = 1'b0;
    cfg_saturate = 1'b1;
    if (!$value$plusargs("ITER=%d", test_iter)) test_iter = 4;
    cfg_iterations = test_iter[3:0];
    x_in = 16'd0;
    y_in = 16'd0;
    z_in = 16'd0;

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    fd = $fopen(vecfile_name, "r");
    if (fd == 0) begin
      $display("FATAL: Cannot open vector file %s", vecfile_name);
      $finish;
    end
    r = $fscanf(fd, "%d\n", n_vecs);

    for (v = 0; v < n_vecs; v = v + 1) begin
      r = $fscanf(fd, "%d %d %d %d %d %d %d %d\n",
                  xi, yi, zi, sati, exi, eyi, ezi, eovfi);
      @(negedge clk);
      x_in = xi[15:0];
      y_in = yi[15:0];
      z_in = zi[15:0];
      valid_in = 1'b1;
      cfg_saturate = sati[0];
      @(posedge clk);
      while (!ready_out) @(posedge clk);
    end
    @(negedge clk);
    valid_in = 1'b0;

    // Drain pipeline
    repeat (30) @(posedge clk);

    $fclose(fd);
    $dumpflush;
    $display("SUCCESS: Simulation finished for %0d vectors", n_vecs);
    $finish;
  end
endmodule
