#!/usr/bin/env bash
#==============================================================================
# Automated PNG Generation for Place & Route Layouts and Synthesis Netlists
# Target: CORDIC Accelerator (Sky130 HD PDK)
# Tools: OpenROAD, Yosys, Graphviz (dot)
#==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${ROOT_DIR}/output"

mkdir -p "${OUTPUT_DIR}"
cd "${ROOT_DIR}"

# Ensure dot is available in PATH
if ! command -v dot &>/dev/null; then
  if [ -d "/nix/store" ]; then
    DOT_BIN=$(find /nix/store/ -maxdepth 3 -name dot 2>/dev/null | grep -E "graphviz.*/bin/dot" | head -n 1 || true)
    if [ -n "${DOT_BIN}" ]; then
      export PATH="$(dirname "${DOT_BIN}"):${PATH}"
    fi
  fi
fi

echo "============================================================"
echo " 1. Generating Place & Route Layout PNG Images (OpenROAD)"
echo "============================================================"

if [ -f "${OUTPUT_DIR}/cordic_top_routed.def" ]; then
  openroad -exit -no_init << 'EOF'
read_lef pdk/sky130_fd_sc_hd_techlef/sky130_fd_sc_hd__nom.tlef
read_lef pdk/sky130_fd_sc_hd_lef/sky130_fd_sc_hd.lef
read_def output/cordic_top_routed.def

# 1. Full Chip Routed Layout
save_image -width 1920 output/cordic_top_pr.png

# 2. Standard Cell Placement View (routing metal layers hidden)
save_image \
  -display_option {Layers/met1 false} \
  -display_option {Layers/met2 false} \
  -display_option {Layers/met3 false} \
  -display_option {Layers/met4 false} \
  -display_option {Layers/met5 false} \
  -display_option {Layers/li1 false} \
  -width 1920 output/cordic_top_placement.png

# 3. Zoomed-in Core Detail (Standard cells, power rails & interconnect)
save_image -area {100 100 180 180} -width 1920 output/cordic_top_pr_zoom.png

# 4. Lower Metal Layers (LI1, Met1, Met2 Signal Interconnect)
save_image \
  -display_option {Layers/met3 false} \
  -display_option {Layers/met4 false} \
  -display_option {Layers/met5 false} \
  -width 1920 output/cordic_top_pr_lower_metal.png
EOF
  echo "[+] Generated P&R PNGs:"
  echo "    - output/cordic_top_pr.png"
  echo "    - output/cordic_top_placement.png"
  echo "    - output/cordic_top_pr_zoom.png"
  echo "    - output/cordic_top_pr_lower_metal.png"
else
  echo "[!] output/cordic_top_routed.def not found; skip P&R image generation."
fi

echo ""
echo "============================================================"
echo " 2. Generating Synthesis Netlist Schematics (Yosys + Dot)"
echo "============================================================"

# Top-level hierarchical RTL netlist schematics
yosys -p "
read_verilog -sv rtl/pkg/cordic_pkg.sv
read_verilog -sv rtl/fp_add_sub.sv
read_verilog -sv rtl/cordic_lut.sv
read_verilog -sv rtl/cordic_stage.sv
read_verilog -sv rtl/cordic_pipeline.sv
read_verilog -sv rtl/cordic_top.sv
hierarchy -check -top cordic_top
proc
opt
show -format dot -prefix output/cordic_top_rtl
"

if command -v dot &>/dev/null; then
  dot -Tpng output/cordic_top_rtl.dot -O
  cp -f output/cordic_top_rtl.dot.11.png output/cordic_top_netlist_hier.png 2>/dev/null || true
  cp -f output/cordic_top_rtl.dot.14.png output/cordic_stage_netlist_rtl.png 2>/dev/null || true
  cp -f output/cordic_top_rtl.dot.12.png output/cordic_lut_netlist_rtl.png 2>/dev/null || true
  cp -f output/cordic_top_rtl.dot.10.png output/fp_add_sub_netlist_rtl.png 2>/dev/null || true
  cp -f output/cordic_top_rtl.dot.13.png output/cordic_pipeline_netlist_rtl.png 2>/dev/null || true

  # Sky130 HD gate-level synthesized netlists
  yosys -p "
read_verilog -sv rtl/pkg/cordic_pkg.sv
read_verilog -sv rtl/fp_add_sub.sv
hierarchy -check -top fp_add_sub
proc; opt; techmap; opt
dfflibmap -liberty pdk/sky130_fd_sc_hd_lib/sky130_fd_sc_hd__tt_025C_1v80.lib
abc -liberty pdk/sky130_fd_sc_hd_lib/sky130_fd_sc_hd__tt_025C_1v80.lib
opt_clean
show -format dot -prefix output/fp_add_sub_gate_synth
"
  dot -Tpng output/fp_add_sub_gate_synth.dot -o output/fp_add_sub_gate_synth.png

  yosys -p "
read_verilog -sv rtl/pkg/cordic_pkg.sv
read_verilog -sv rtl/cordic_lut.sv
hierarchy -check -top cordic_lut
proc; opt; techmap; opt
dfflibmap -liberty pdk/sky130_fd_sc_hd_lib/sky130_fd_sc_hd__tt_025C_1v80.lib
abc -liberty pdk/sky130_fd_sc_hd_lib/sky130_fd_sc_hd__tt_025C_1v80.lib
opt_clean
show -format dot -prefix output/cordic_lut_gate_synth
"
  dot -Tpng output/cordic_lut_gate_synth.dot -o output/cordic_lut_gate_synth.png

  yosys -p "
read_verilog -sv rtl/pkg/cordic_pkg.sv
read_verilog -sv rtl/fp_add_sub.sv
read_verilog -sv rtl/cordic_stage.sv
hierarchy -check -top cordic_stage
proc; opt; flatten -noscopeinfo; techmap; opt
dfflibmap -liberty pdk/sky130_fd_sc_hd_lib/sky130_fd_sc_hd__tt_025C_1v80.lib
abc -liberty pdk/sky130_fd_sc_hd_lib/sky130_fd_sc_hd__tt_025C_1v80.lib
opt_clean
show -format dot -prefix output/cordic_stage_gate_synth
"
  dot -Tpng output/cordic_stage_gate_synth.dot -o output/cordic_stage_gate_synth.png

  echo "[+] Generated Netlist Schematics:"
  echo "    - output/cordic_top_netlist_hier.png"
  echo "    - output/cordic_pipeline_netlist_rtl.png"
  echo "    - output/cordic_stage_netlist_rtl.png"
  echo "    - output/cordic_lut_netlist_rtl.png"
  echo "    - output/fp_add_sub_netlist_rtl.png"
  echo "    - output/fp_add_sub_gate_synth.png"
  echo "    - output/cordic_lut_gate_synth.png"
  echo "    - output/cordic_stage_gate_synth.png"
else
  echo "[!] Graphviz 'dot' not found; generated .dot files only."
fi
