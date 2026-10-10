#==============================================================================
# OpenSTA Post-Route Timing Analysis Script for CORDIC Accelerator
# Loads the OpenROAD-routed netlist plus REAL extracted parasitics (SPEF,
# produced by scripts/pr.tcl via OpenRCX: define_process_corner +
# extract_parasitics + write_spef) and re-checks timing in a standalone
# OpenSTA run — the same tool/flow used for pre-layout STA (scripts/sta.tcl),
# so the two numbers are directly comparable and neither is an artifact of
# a different tool's internal defaults.
#
# This is distinct from OpenROAD's own post-route `report_worst_slack`/
# `report_tns` (run inline in scripts/pr.tcl right after detailed_route):
# that internal report uses OpenROAD's own resident timer against whatever
# parasitics it already has loaded in-session. This script instead starts a
# *fresh* OpenSTA process, reads the routed gate-level netlist cold, and
# explicitly reads back the SPEF from disk — closing the specific gap where
# a "post-route" number might silently still be computed on ideal/zero wires
# or on a different corner than the standalone flow.
#
# Usage: tools/OpenSTA/build/sta scripts/sta_postroute.tcl
# (Run after `make pr`, which must produce output/cordic_top_routed.v and
# output/cordic_top_routed.spef.)
#==============================================================================

# Read the ROUTED netlist (post-CTS, post-filler-insertion — not the pre-P&R
# synthesized one) so cell instances match the SPEF's net/pin names.
read_verilog output/cordic_top_routed.v

read_liberty pdk/sky130_fd_sc_hd_lib/sky130_fd_sc_hd__tt_025C_1v80.lib

link_design cordic_top

read_sdc phase0c/constraints/cordic_16ns.sdc

# Real extracted parasitics from the routed DEF (OpenRCX, via scripts/pr.tcl).
# This is the crux of the claim-#1 reproduction: replace ideal/zero wires
# (or a statistical wireload model) with actual RC from the as-routed layout.
read_spef output/cordic_top_routed.spef

# Reports — same set/format as scripts/sta.tcl for direct comparison.
report_checks -path_delay min_max -format full > output/sta_postroute_checks.rpt
report_tns > output/sta_postroute_tns.rpt
report_wns > output/sta_postroute_wns.rpt
report_worst_slack -max >> output/sta_postroute_wns.rpt
report_worst_slack -min >> output/sta_postroute_wns.rpt

report_clock_properties > output/sta_postroute_clock.rpt
report_power > output/sta_postroute_power.rpt

exit
