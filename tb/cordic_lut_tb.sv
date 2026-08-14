`timescale 1ns/1ps
//==============================================================================
// Testbench: cordic_lut_tb
// Description: Self-checking unit testbench for cordic_lut (K-prescaler,
//              combinational). Expected = round(v * 2488 / 4096) computed in
//              longint arithmetic — bit-exact to the RTL shift-add network.
// Owner: Verification Agent
// Wave: 1
//==============================================================================

module cordic_lut_tb;
  import cordic_pkg::*;

  cordic_data_t x_in, y_in;
  cordic_data_t k_prescale_x, k_prescale_y;
  int           errors;

  cordic_lut dut (
    .x_in        (x_in),
    .y_in        (y_in),
    .k_prescale_x(k_prescale_x),
    .k_prescale_y(k_prescale_y)
  );

  // ---------------------------------------------------------------------------
  // Reference: round(v * K_FACTOR / 2^FRACT_W) = (v*2488 + 2048) >>> 12
  // longint (64-bit signed) arithmetic right shift matches SV >>> on signed.
  // ---------------------------------------------------------------------------
  function automatic cordic_data_t k_expected(input cordic_data_t v);
    longint signed acc;
    acc = longint'(v) * 2488;
    acc = acc + 2048;
    acc = acc >>> 12;
    return cordic_data_t'(acc[WIDTH-1:0]);
  endfunction

  task automatic chk_xy(input cordic_data_t xv, yv);
    cordic_data_t ex, ey;
    ex = k_expected(xv);
    ey = k_expected(yv);
    if (k_prescale_x !== ex) begin
      $error("[cordic_lut] k_prescale_x(%0d): got %0d, expected %0d", xv, k_prescale_x, ex);
      errors++;
    end
    if (k_prescale_y !== ey) begin
      $error("[cordic_lut] k_prescale_y(%0d): got %0d, expected %0d", yv, k_prescale_y, ey);
      errors++;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Test body
  // ---------------------------------------------------------------------------
  initial begin
    errors = 0;

    // --- Spot checks (known values) ---
    x_in = 16'sd0;    y_in = 16'sd0;    #1; chk_xy(x_in, y_in);  // zero
    x_in = ONE_FIX;   y_in = 16'sd0;    #1; chk_xy(x_in, y_in);  // K*1.0 = 0.607 (2488)
    x_in = -ONE_FIX;  y_in = ONE_FIX;   #1; chk_xy(x_in, y_in);  // negative
    x_in = MAX_POS;   y_in = MIN_NEG;   #1; chk_xy(x_in, y_in);  // boundary
    x_in = 16'sd1000; y_in = -16'sd2000; #1; chk_xy(x_in, y_in); // asymmetric
    x_in = 16'sd4095; y_in = 16'sd4097; #1; chk_xy(x_in, y_in);  // near ONE_FIX
    x_in = -16'sd1;   y_in = 16'sd1;    #1; chk_xy(x_in, y_in);  // ±1

    // --- Full sweep: x in [-32768, 32767], y fixed to verify x-channel ---
    for (int v = -32768; v <= 32767; v++) begin
      x_in = cordic_data_t'(v); y_in = 16'sd0; #1;
      if (k_prescale_x !== k_expected(x_in)) begin
        $error("[cordic_lut] sweep k_prescale_x(%0d): got %0d, expected %0d",
               v, k_prescale_x, k_expected(x_in));
        errors++;
        if (errors >= 16) begin
          $fatal(1, "FAIL: cordic_lut — stopping after 16 errors");
        end
      end
    end

    // --- Verify y-channel independently over a subset ---
    x_in = 16'sd0;
    for (int v = -32768; v <= 32767; v += 256) begin
      y_in = cordic_data_t'(v); #1;
      if (k_prescale_y !== k_expected(y_in)) begin
        $error("[cordic_lut] y-channel k_prescale_y(%0d): got %0d, expected %0d",
               v, k_prescale_y, k_expected(y_in));
        errors++;
      end
    end

    if (errors != 0) $fatal(1, "FAIL: cordic_lut — %0d error(s)", errors);
    else        $display("PASS: cordic_lut");
  end

endmodule
