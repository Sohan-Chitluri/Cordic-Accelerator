#!/usr/bin/env bash
#==============================================================================
# tb/run_param_matrix.sh
# Description: Parameter-matrix regression driver for cordic_stage /
#              cordic_lut (via tb/cordic_param_matrix_tb.sv). Builds and runs
#              each (WIDTH, FRACT_W, ITERATIONS) combination as its own
#              verilator invocation, so an elaboration failure in one config
#              cannot mask a pass in another.
#
#              For configs marked EXPECT_FAIL, a nonzero build/run exit code
#              (i.e. the static_assert domain guards in cordic_stage.sv /
#              cordic_lut.sv correctly rejecting the config at elaboration)
#              is the PASS condition for the matrix entry.
#
#              Run from the repo root inside `nix develop`:
#                nix develop --command bash tb/run_param_matrix.sh
#
# Owner: Verification Agent
#==============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

RTL_DIR=rtl
TB_DIR=tb
OUT_DIR="$(pwd)/output/param_matrix"
mkdir -p "$OUT_DIR"

RTL_SOURCES=(
  "$RTL_DIR/pkg/cordic_pkg.sv"
  "$RTL_DIR/fp_add_sub.sv"
  "$RTL_DIR/cordic_lut.sv"
  "$RTL_DIR/cordic_stage.sv"
)

# name  WIDTH  FRACT_W  ITERATIONS  expect(pass|fail)
MATRIX=(
  "baseline_16_12_8    16 12 8  pass"
  "wide_iter_16_12_12  16 12 12 pass"
  "wide_width_20_12_8  20 12 8  pass"
  "bad_fract_16_10_8   16 10 8  fail"
  "bad_fract_32_24_8   32 24 8  fail"
  "bad_both_8_4_8      8  4  8  fail"
  "bad_both_4_1_8      4  1  8  fail"
  "bad_iters_16_12_17  16 12 17 fail"
)

total=0
failed=0

for entry in "${MATRIX[@]}"; do
  read -r name width fract iters expect <<< "$entry"
  total=$((total + 1))
  bin="$OUT_DIR/V_${name}"
  logfile="$OUT_DIR/${name}.log"

  verilator --binary -j 0 -O3 -CFLAGS "-O3 -std=c++17" \
    -Wno-VARHIDDEN -Wno-TIMESCALEMOD -Wno-UNOPTFLAT \
    --sv --timing --assert \
    --top-module cordic_param_matrix_tb \
    -GWIDTH="$width" -GFRACT_W="$fract" -GITERATIONS="$iters" \
    "${RTL_SOURCES[@]}" \
    "$TB_DIR/cordic_param_matrix_tb.sv" \
    -o "$bin" > "$logfile" 2>&1
  build_rc=$?

  run_rc=1
  if [ $build_rc -eq 0 ]; then
    "$bin" >> "$logfile" 2>&1
    run_rc=$?
  fi

  overall_rc=$build_rc
  if [ $build_rc -eq 0 ]; then overall_rc=$run_rc; fi

  if [ "$expect" = "pass" ]; then
    if [ $overall_rc -eq 0 ] && grep -q "^PASS:" "$logfile"; then
      echo "PASS  $name (WIDTH=$width FRACT_W=$fract ITERATIONS=$iters) [expected pass, got pass]"
    else
      echo "FAIL  $name (WIDTH=$width FRACT_W=$fract ITERATIONS=$iters) [expected pass, build_rc=$build_rc run_rc=$run_rc] -- see $logfile"
      failed=$((failed + 1))
    fi
  else
    if [ $overall_rc -ne 0 ]; then
      echo "PASS  $name (WIDTH=$width FRACT_W=$fract ITERATIONS=$iters) [expected fail, correctly rejected at build_rc=$build_rc run_rc=$run_rc]"
    else
      echo "FAIL  $name (WIDTH=$width FRACT_W=$fract ITERATIONS=$iters) [expected fail, but build+run SUCCEEDED -- domain guard did not fire] -- see $logfile"
      failed=$((failed + 1))
    fi
  fi
done

echo "-----------------------------------------------------"
echo "cordic_param_matrix: $((total - failed))/$total entries matched expectation"
if [ $failed -ne 0 ]; then
  echo "FAIL: $failed param-matrix entr(y/ies) did not match expectation"
  exit 1
fi
echo "PASS: all param-matrix entries matched expectation"
exit 0
