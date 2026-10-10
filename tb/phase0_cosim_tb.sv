`timescale 1ns/1ps
//==============================================================================
// Testbench: phase0_cosim_tb
// Description: Phase 0, item 1 — bit-exact verification of tb/golden_model.py
//              (CordicGoldenModel) against the frozen-baseline RTL
//              (cordic_pipeline, WIDTH=16, FRACT_W=12, ITERATIONS=8), driven
//              from a directed+random vector file produced by
//              phase0/gen_bitexact_vectors.py in the $fscanf format
//              golden_model.py's own generate_test_mem() already defines:
//                  line 1: count
//                  each line: x_in y_in z_in cfg_saturate  exp_x exp_y exp_z exp_ovf
//
//              This is a new, standalone testbench — no existing RTL or
//              testbench file is modified. One transaction is admitted at a
//              time (config handshake, then data, then drain) so ordering
//              between a per-vector cfg_saturate value and its own
//              transaction is unambiguous.
//
//              TEST_ITERATIONS (Phase 0b, item 1): overrides cordic_pipeline's
//              ITERATIONS module parameter directly (via -pvalue+ or -G at
//              the Verilator command line) so this same testbench can verify
//              any guarded, legal ITERATIONS value (cordic_stage.sv's own
//              domain guard allows STAGE_IDX 0..15, i.e. ITERATIONS<=16) —
//              not just the frozen baseline's 8. cordic_pkg::ITERATIONS
//              (used only for the default) is left untouched; no package or
//              other RTL file needs to change. `cordic_assertions` (bound
//              from cordic_stage.sv under `ifdef ASSERT_ON`, not defined in
//              this build) is not compiled here, so its own hardwired
//              `cordic_pkg::ITERATIONS` reference is irrelevant to this
//              override.
// Owner: Phase 0 (numerical characterization)
//==============================================================================

module phase0_cosim_tb #(
  parameter int TEST_ITERATIONS = cordic_pkg::ITERATIONS
);
  import cordic_pkg::*;

  localparam int VALID_DEPTH = TEST_ITERATIONS + 1;
  localparam int TIMEOUT     = VALID_DEPTH + 8;

  logic         clk, rst_n;
  cordic_data_t x_in, y_in, z_in;
  logic         valid_in, ready_out;
  logic [3:0]   cfg_iterations;
  logic         cfg_saturate, config_valid, config_ready;
  cordic_data_t x_out, y_out, z_out;
  logic         valid_out, ready_in, overflow, irq;

  int errors, checked;
  int fd;
  int n_vectors;
  integer xi, yi, zi, sati, exi, eyi, ezi, eovfi;

  cordic_pipeline #(.ITERATIONS(TEST_ITERATIONS)) dut (
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

  task automatic apply_config(input logic sat);
    @(negedge clk);
    cfg_saturate = sat; cfg_iterations = 4'(TEST_ITERATIONS); config_valid = 1'b1;
    @(posedge clk); @(negedge clk);
    config_valid = 1'b0;
  endtask

  task automatic send_vector(input cordic_data_t xv, yv, zv);
    @(negedge clk);
    x_in = xv; y_in = yv; z_in = zv; valid_in = 1'b1;
    forever begin
      @(posedge clk);
      if (ready_out) break;
    end
    @(negedge clk);
    valid_in = 1'b0;
  endtask

  task automatic wait_and_check(
    input string label, input cordic_data_t ex, ey, ez, input logic eovf
  );
    int i;
    logic got;
    got = 1'b0;
    for (i = 0; i < TIMEOUT; i++) begin
      @(posedge clk);
      if (valid_out) begin
        got = 1'b1;
        break;
      end
    end
    if (!got) begin
      $error("[phase0] %s: timeout waiting for valid_out", label);
      errors++;
      return;
    end
    checked++;
    if (x_out !== ex) begin
      $error("[phase0] %s: x_out=%0d exp=%0d", label, x_out, ex); errors++;
    end
    if (y_out !== ey) begin
      $error("[phase0] %s: y_out=%0d exp=%0d", label, y_out, ey); errors++;
    end
    if (z_out !== ez) begin
      $error("[phase0] %s: z_out=%0d exp=%0d", label, z_out, ez); errors++;
    end
    if (overflow !== eovf) begin
      $error("[phase0] %s: overflow=%0b exp=%0b", label, overflow, eovf); errors++;
    end
  endtask

  initial begin
    string vecfile;
    errors = 0;
    checked = 0;
    rst_n = 1'b0;
    valid_in = 1'b0;
    ready_in = 1'b1;
    config_valid = 1'b0;
    cfg_saturate = 1'b1;
    cfg_iterations = 4'(TEST_ITERATIONS);

    if (!$value$plusargs("VECFILE=%s", vecfile)) vecfile = "phase0/vectors/bitexact_check.mem";

    fd = $fopen(vecfile, "r");
    if (fd == 0) begin
      $error("[phase0] could not open vector file: %s", vecfile);
      $finish;
    end
    void'($fscanf(fd, "%d\n", n_vectors));

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    for (int v = 0; v < n_vectors; v++) begin
      automatic string label;
      void'($fscanf(fd, "%d %d %d %d %d %d %d %d\n",
                     xi, yi, zi, sati, exi, eyi, ezi, eovfi));
      label = $sformatf("vec[%0d]", v);
      apply_config(sati[0]);
      send_vector(cordic_data_t'(xi), cordic_data_t'(yi), cordic_data_t'(zi));
      wait_and_check(label, cordic_data_t'(exi), cordic_data_t'(eyi),
                      cordic_data_t'(ezi), eovfi[0]);
    end

    $fclose(fd);

    $display("========================================================");
    if (errors == 0)
      $display("PASS: phase0_cosim — %0d/%0d vectors bit-exact", checked, n_vectors);
    else
      $display("FAIL: phase0_cosim — %0d errors across %0d/%0d vectors checked",
                errors, checked, n_vectors);
    $display("========================================================");
    $finish;
  end

endmodule
