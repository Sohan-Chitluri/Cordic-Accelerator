#==============================================================================
# OpenROAD P&R Script for CORDIC Accelerator
# Usage: openroad -s scripts/pr.tcl
#==============================================================================

# Read the synthesized netlist
read_netlist output/cordic_top_synth.v

# Set the clock period in nanoseconds (200 MHz target = 5ns)
set_clock_period 5.0

# Read timing and constraint files (when available from PDK)
# read_sdc constraints/cordic_timing.sdc
# read_sdc constraints/cordic_placement.sdc

# Floorplanning (if PDK available)
# set_die_area 0 0 1000 1000
# set_core_area 50 50 950 950

# Global placement
global_placement -density 0.7 -routability_driven

# Optimize placement for timing
optimize_placement

# Clock tree synthesis
synthesize_cts

# Detailed placement
detailed_placement

# Route
route

# Optimize for timing/power
optimize_routing

# Write output
write_verilog output/cordic_top_placed.v
write_def output/cordic_top_routed.def
# write_gds output/cordic_top.gds  # Requires GDS write support

# Generate reports
report_metrics

puts "=== OpenROAD P&R Complete ==="
puts "Output files:"
puts "  Placed netlist: output/cordic_top_placed.v"
puts "  Routed DEF: output/cordic_top_routed.def"
