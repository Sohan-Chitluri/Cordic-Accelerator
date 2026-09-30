#==============================================================================
# Yosys Synthesis Script for CORDIC Accelerator
# Target: Generic ASIC flow (adapt for specific PDK)
# Language: SystemVerilog (IEEE 1800-2012) — ASIC-safe subset
# Requires: Yosys >= 0.13 for -sv flag support
#==============================================================================

# Read design files in dependency order (package first — others depend on it)
# cordic_assertions.sv is a monitor/SVA module only — not synthesizable
read_verilog -sv rtl/pkg/cordic_pkg.sv
read_verilog -sv rtl/fp_add_sub.sv
read_verilog -sv rtl/cordic_lut.sv
read_verilog -sv rtl/cordic_stage.sv
read_verilog -sv rtl/cordic_pipeline.sv
read_verilog -sv rtl/cordic_top.sv

# Set top module
hierarchy -check -top cordic_top

# Synthesis commands
proc; opt; fsm; opt; memory; opt

# Flatten hierarchy — dfflibmap/abc below only process the currently selected
# module(s); without flattening, submodule instances under cordic_top are
# never visited and stay as generic ($add/$mux/...) cells.
# -noscopeinfo: skip generating $scopeinfo debug cells, which otherwise leave
# stale hierarchical net-name references that `check` flags as driverless.
flatten -noscopeinfo

# Lower coarse-grain cells ($add, $mux, ...) to primitive gates ($_AND_, ...)
# so ABC has something to map below.
techmap
opt

# Technology mapping - Sky130 HD standard cell library (typical corner)
# See docs/PLACE_ROUTE_DRC.md for how pdk/sky130_fd_sc_hd_lib is populated.
dfflibmap -liberty pdk/sky130_fd_sc_hd_lib/sky130_fd_sc_hd__tt_025C_1v80.lib
abc -liberty pdk/sky130_fd_sc_hd_lib/sky130_fd_sc_hd__tt_025C_1v80.lib

# Map constant-1/0 connections to real tie cells. Without this, constant nets
# stay as bare Verilog literals (`assign net = 1'h1;`); OpenROAD's link_design
# then synthesizes an implicit tie net for them that gets classified as a
# POWER-type net, which TritonRoute (detailed_route) refuses to route as an
# ordinary signal.
hilomap -singleton -hicell sky130_fd_sc_hd__conb_1 HI -locell sky130_fd_sc_hd__conb_1 LO

# Clean up
opt_clean

# Write synthesized netlist
write_verilog -noattr output/cordic_top_synth.v

# OpenSTA's structural Verilog parser doesn't accept the `signed` keyword on
# gate-level port/wire declarations. It's vestigial at this point (all logic
# is already bit-blasted into individual gates by ABC), so strip it.
!sed -i 's/ signed / /g' output/cordic_top_synth.v

# sky130_fd_sc_hd__conb_1's LO (constant-0) output is unused by this design
# (no 1'b0 constant needed anywhere) and hilomap leaves it unconnected.
# OpenROAD's link_design auto-ties genuinely-floating pins with a constant-0
# Liberty function to an implicit net it classifies as GROUND type, which
# TritonRoute then refuses to route as an ordinary signal (it expects
# GROUND-type nets to have real PDN rail geometry, which this one doesn't).
# Tying LO to an explicit, otherwise-unused signal wire avoids that implicit
# auto-tie entirely — connected pins are read as ordinary signals.
!python3 -c "import re,sys; p='output/cordic_top_synth.v'; s=open(p).read(); s=re.sub(r'(sky130_fd_sc_hd__conb_1\s+\S+\s*\(\s*\.HI\([^)]*\))\s*\);', r'wire _tie_lo_unused_;\n  \1,\n    .LO(_tie_lo_unused_)\n  );', s); open(p,'w').write(s)"

# Statistics
stat -top cordic_top
check -noinit

# Area report
tee -o output/synth_area.rpt stat -top cordic_top

# Timing report (requires STA separately)
# write_sdc output/cordic_timing.sdc