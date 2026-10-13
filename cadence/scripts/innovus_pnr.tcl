#==============================================================================
# Cadence Innovus Implementation Script
# Design: CORDIC Accelerator (Adaptive-11 Architecture B1)
# Top Module: cordic_top
#==============================================================================

# 1. Design Initialization
set init_verilog "outputs_genus/cordic_top_synth.v"
set init_top_cell "cordic_top"
set init_sdc_file "outputs_genus/cordic_top_synth.sdc"

# Set LEF and tech files (Override with target PDK on Cadence machine)
# Example:
# set init_lef_file "pdk/lef/sky130_fd_sc_hd.tlef pdk/lef/sky130_fd_sc_hd.lef"
if {[info exists env(INNOVUS_LEF_FILES)]} {
  set init_lef_file $env(INNOVUS_LEF_FILES)
}

init_design

# 2. Floorplanning
# Target density ~0.65 with 10um core margins
floorPlan -site CoreSite -r 1.0 0.65 10 10 10 10

# 3. Power Distribution Network
globalNetConnect VDD -type pgpin -pin VPWR -inst *
globalNetConnect VSS -type pgpin -pin VGND -inst *
globalNetConnect VDD -type tiehi
globalNetConnect VSS -type tielo

# Power Rings & Stripes (adapt layer names to target PDK)
# addRing -nets {VDD VSS} -type core_rings -follow core -layer {top met4 bottom met4 left met5 right met5} -width 2.0 -spacing 1.0
sroute -connect { blockPin padPin padRing corePin floatingStripe } -layerChangeRange { met1 met5 } -nets { VDD VSS }

# 4. Placement & Pre-CTS Optimization
setPlaceMode -prerouteRunPowerOpt false
place_opt_design

# 5. Clock Tree Synthesis (CCOpt)
create_ccopt_clock_tree_spec
ccopt_design

# Post-CTS timing optimization
optDesign -postCTS

# 6. Routing (NanoRoute)
setNanoRouteMode -quiet -routeWithTimingDriven true
setNanoRouteMode -quiet -routeWithSiDriven true
routeDesign

# 7. Post-Route Optimization & Parasitic Extraction
extractRC
optDesign -postRoute

# 8. Post-Route Timing and Power Analysis
file mkdir reports_innovus
timeDesign -postRoute -prefix postRoute_setup -reportOnly -outDir reports_innovus
timeDesign -postRoute -hold -prefix postRoute_hold -reportOnly -outDir reports_innovus
report_power -outfile reports_innovus/power.rpt

# 9. Physical Verification
verify_drc -report reports_innovus/drc.rpt
verify_connectivity -report reports_innovus/connectivity.rpt

# 10. GDSII & Netlist Export
file mkdir outputs_innovus
saveNetlist outputs_innovus/cordic_top_routed.v
write_parasitics -spef_file outputs_innovus/cordic_top.spef
defOut -floorplan -netlist -routing outputs_innovus/cordic_top_routed.def

# Stream out GDS (if stream-out map file is provided)
if {[info exists env(GDS_MAP_FILE)] && [info exists env(GDS_FILES)]} {
  streamOut outputs_innovus/cordic_top.gds \
    -mapFile $env(GDS_MAP_FILE) \
    -merge $env(GDS_FILES) \
    -outputMacros \
    -units 1000 -mode ALL
}

puts "=========================================================="
puts "Innovus P&R Complete for cordic_top (Adaptive-11)"
puts "Outputs written to outputs_innovus/ and reports_innovus/"
puts "=========================================================="
exit
