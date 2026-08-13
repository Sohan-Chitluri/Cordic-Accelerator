#==============================================================================
# Yosys Synthesis Script for CORDIC Accelerator
# Target: Generic ASIC flow (adapt for specific PDK)
# Language: SystemVerilog (IEEE 1800-2012) — ASIC-safe subset
# Requires: Yosys >= 0.13 for -sv flag support
#==============================================================================

# Read design files in dependency order (package first — others depend on it)
read_verilog -sv rtl/pkg/cordic_pkg.sv
read_verilog -sv rtl/common/cordic_assertions.sv
read_verilog -sv rtl/fp_add_sub.sv
read_verilog -sv rtl/cordic_lut.sv
read_verilog -sv rtl/cordic_stage.sv
read_verilog -sv rtl/cordic_pipeline.sv
read_verilog -sv rtl/cordic_top.sv

# Set top module
hierarchy -check -top cordic_top

# Synthesis commands
proc; opt; fsm; opt; memory; opt

# Technology mapping - use built-in Yosys cells (no external liberty file)
# This avoids needing a PDK liberty file for bootstrap validation
abc

# Clean up
opt_clean

# Write synthesized netlist
write_verilog -noattr output/cordic_top_synth.v

# Statistics
stat -top cordic_top
check -noinit

# Area report
tee -o output/synth_area.rpt stat -top cordic_top

# Timing report (requires STA separately)
# write_sdc output/cordic_timing.sdc