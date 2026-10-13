#==============================================================================
# Cadence Genus Synthesis Script
# Design: CORDIC Accelerator (Adaptive-11 Architecture B1)
# Top Module: cordic_top
#==============================================================================

# 1. Environment & Setup
set_db / .init_lib_search_path {. ./pdk ./lib /home/install/FOUNDRY}
set_db / .script_search_path {. ./cadence/scripts ./scripts}

# Target and link libraries (Override with target PDK on Cadence machine)
# Example for Sky130 HD:
# set_db / .target_library_path {sky130_fd_sc_hd__tt_025C_1v80.lib}
# set_db / .link_library_path   {sky130_fd_sc_hd__tt_025C_1v80.lib}
if {[info exists env(GENUS_TARGET_LIB)]} {
  set_db / .target_library_path $env(GENUS_TARGET_LIB)
  set_db / .link_library_path   $env(GENUS_TARGET_LIB)
} else {
  puts "INFO: GENUS_TARGET_LIB not set in environment. Set target_library_path manually before running."
}

# 2. Read SystemVerilog RTL Files
set_db / .hdl_language sv
set_db / .information_level 7

# Read files in dependency order
read_hdl -language sv rtl/pkg/cordic_pkg.sv
read_hdl -language sv rtl/fp_add_sub.sv
read_hdl -language sv rtl/cordic_lut.sv
read_hdl -language sv rtl/cordic_stage.sv
read_hdl -language sv rtl/cordic_pipeline.sv
read_hdl -language sv rtl/cordic_top.sv

# 3. Elaboration
elaborate cordic_top

# Check design consistency
check_design -unresolved

# 4. Read Timing Constraints
read_sdc cadence/constraints/cordic.sdc

# 5. Synthesis Steps
# Generic synthesis
syn_generic

# Technology mapping
syn_map

# Incremental optimization (timing/area)
syn_opt

# 6. Reports Generation
file mkdir reports_genus
report_timing > reports_genus/timing.rpt
report_area   > reports_genus/area.rpt
report_power  > reports_genus/power.rpt
report_qor    > reports_genus/qor.rpt
report_gates  > reports_genus/gates.rpt

# 7. Export Outputs for Innovus
file mkdir outputs_genus
write_hdl     > outputs_genus/cordic_top_synth.v
write_sdc     > outputs_genus/cordic_top_synth.sdc
write_db -to_file outputs_genus/cordic_top_synth.db

puts "=========================================================="
puts "Genus Synthesis Complete for cordic_top (Adaptive-11)"
puts "Outputs written to outputs_genus/ and reports_genus/"
puts "=========================================================="
exit
