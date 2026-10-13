#!/usr/bin/env bash
#==============================================================================
# Adaptive-11 Precision Explorer Execution Script
#
# Regenerates all experimental results from source:
# 1. Compiles and runs Verilator RTL simulation (cordic_top Modes 1-11)
# 2. Runs the Python statistical analysis engine (CSV, Report, SVG)
# 3. Runs unit tests verifying the harness integrity
#==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "================================================================="
echo "Adaptive-11 Precision Explorer: Full Regeneration"
echo "Repository: ${REPO_ROOT}"
echo "================================================================="

cd "${REPO_ROOT}"

# 1. Compile SystemVerilog RTL Precision Testbench
echo ""
echo "[Step 1/3] Compiling and running RTL simulation (Verilator)..."
verilator --binary -j 0 -O3 -CFLAGS "-O3 -std=c++17" \
  -Wno-VARHIDDEN -Wno-TIMESCALEMOD \
  --sv --timing --assert \
  --top-module adaptive_precision_tb \
  rtl/pkg/cordic_pkg.sv \
  rtl/common/cordic_assertions.sv \
  rtl/fp_add_sub.sv \
  rtl/cordic_lut.sv \
  rtl/cordic_stage.sv \
  rtl/cordic_pipeline.sv \
  rtl/cordic_top.sv \
  precision_explorer/adaptive_precision_tb.sv \
  -o "${SCRIPT_DIR}/Vadaptive_precision_tb"

# Execute RTL simulation
"${SCRIPT_DIR}/Vadaptive_precision_tb"

# 2. Run Python Precision Analytics Engine
echo ""
echo "[Step 2/3] Generating CSV metrics, Markdown report, and SVG plot..."
python3 precision_explorer/precision_explorer.py

# 3. Run Test Suite for the Experiment Harness
echo ""
echo "[Step 3/3] Running Precision Explorer test suite..."
python3 precision_explorer/test_precision_explorer.py

echo ""
echo "================================================================="
echo "All Precision Explorer artifacts successfully regenerated!"
echo "CSV:    precision_explorer/precision_metrics.csv"
echo "Report: precision_explorer/PRECISION_REPORT.md"
echo "Plot:   precision_explorer/precision_error_curves.svg"
echo "================================================================="
