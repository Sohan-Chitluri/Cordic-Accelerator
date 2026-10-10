# Standalone area/cell-count report, run against an already-synthesized
# gate-level netlist (output/cordic_top_synth.v). Needed as a workaround: in
# scripts/synth.tcl, `stat -top cordic_top` crashes yosys
# (std::out_of_range / map::at) whenever the design was built with
# chparam -set ITERATIONS <n> cordic_top for n != the cordic_pkg.sv default
# (8) -- the crash happens strictly inside the reporting step, AFTER
# write_verilog has already written a correct netlist, so the synthesized
# netlist itself is not in question. Confirmed reproducible: n=4 crashes,
# n=8 (the default, no chparam needed) does not.
read_verilog -sv output/cordic_top_synth.v
read_liberty -lib pdk/sky130_fd_sc_hd_lib/sky130_fd_sc_hd__tt_025C_1v80.lib
hierarchy -check -top cordic_top
stat -top cordic_top -liberty pdk/sky130_fd_sc_hd_lib/sky130_fd_sc_hd__tt_025C_1v80.lib
