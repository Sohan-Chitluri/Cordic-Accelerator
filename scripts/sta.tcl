#==============================================================================
# OpenSTA Timing Analysis Script for CORDIC Accelerator
# Target: Generic ASIC flow (adapt for specific PDK)
#==============================================================================

# Read synthesized netlist
read_verilog output/cordic_top_synth.v

# Read technology library — Sky130 HD, typical corner (tt, 25C, 1.8V)
# See docs/PLACE_ROUTE_DRC.md for how pdk/sky130_fd_sc_hd_lib is populated.
read_liberty pdk/sky130_fd_sc_hd_lib/sky130_fd_sc_hd__tt_025C_1v80.lib

# Link design
link_design cordic_top

# Read constraints
read_sdc constraints/cordic.sdc

# Operating conditions default to the library's own tt_025C_1v80 corner;
# no override needed. Pre-layout STA uses the library's default wire load
# selection (no explicit set_wire_load_mode) since no floorplan area exists yet.

# Report checks
report_checks -path_delay min_max -format full > output/sta_checks.rpt
report_tns > output/sta_tns.rpt
report_wns > output/sta_wns.rpt

# Report clock properties (report_clock is not an OpenSTA command)
report_clock_properties > output/sta_clock.rpt

# Report power
report_power > output/sta_power.rpt

# Exit
exit