#==============================================================================
# OpenSTA Timing Analysis Script for CORDIC Accelerator
# Target: Generic ASIC flow (adapt for specific PDK)
#==============================================================================

# Read synthesized netlist
read_verilog output/cordic_top_synth.v

# Read technology library (replace with your PDK)
# read_liberty /path/to/your/lib/typical.lib
read_liberty /usr/local/share/opensta/cmos_cells.lib

# Link design
link_design cordic_top

# Read constraints
read_sdc constraints/cordic.sdc

# Set operating conditions (adjust for your PDK)
set_operating_conditions -library typical

# Set wire load mode (optional)
set_wire_load_mode top

# Report checks
report_checks -path_delay min_max -format full > output/sta_checks.rpt
report_tns > output/sta_tns.rpt
report_wns > output/sta_wns.rpt

# Report clock
report_clock > output/sta_clock.rpt

# Report power (if UPF available)
# report_power > output/sta_power.rpt

# Exit
exit