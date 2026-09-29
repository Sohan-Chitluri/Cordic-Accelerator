#==============================================================================
# OpenROAD P&R Script for CORDIC Accelerator
# Target: Sky130 HD standard cell library
# Usage: openroad -no_init -exit scripts/pr.tcl
# See docs/PLACE_ROUTE_DRC.md for how pdk/sky130_fd_sc_hd_lef,
# pdk/sky130_fd_sc_hd_techlef, and pdk/sky130_fd_sc_hd_lib are populated.
#==============================================================================

read_lef pdk/sky130_fd_sc_hd_techlef/sky130_fd_sc_hd__nom.tlef
read_lef pdk/sky130_fd_sc_hd_lef/sky130_fd_sc_hd.lef
read_liberty pdk/sky130_fd_sc_hd_lib/sky130_fd_sc_hd__tt_025C_1v80.lib

read_verilog output/cordic_top_synth.v
link_design cordic_top

read_sdc constraints/cordic.sdc

# -----------------------------------------------------------------------------
# CLEAN UP PHANTOM CONSTANT NETS
# OpenROAD's Verilog reader creates implicit "zero_"/"one_" nets for constant-
# function Liberty pins (e.g. tie cells) as bookkeeping; even with all real
# tie-cell pins explicitly connected in the netlist, these end up as
# zero-pin, zero-purpose nets typed GROUND/POWER that TritonRoute refuses to
# route (it expects GROUND/POWER-typed nets to have real PDN rail geometry).
# They carry no actual connectivity, so deleting them is safe.
# -----------------------------------------------------------------------------
set db [ord::get_db]
set block [[$db getChip] getBlock]
foreach phantom_net_name {zero_ one_} {
  set phantom_net [$block findNet $phantom_net_name]
  if {$phantom_net ne "NULL"} {
    odb::dbNet_destroy $phantom_net
  }
}

# -----------------------------------------------------------------------------
# FLOORPLAN
# -----------------------------------------------------------------------------
initialize_floorplan -utilization 40 -aspect_ratio 1.0 -core_space 2.0 -site unithd

# Routing track definitions — not present in the tech LEF, values from
# pdk/sky130_fd_sc_hd_lib's sibling tracks.info (offset/pitch, in microns).
make_tracks li1  -x_offset 0.23 -x_pitch 0.46 -y_offset 0.17 -y_pitch 0.34
make_tracks met1 -x_offset 0.17 -x_pitch 0.34 -y_offset 0.17 -y_pitch 0.34
make_tracks met2 -x_offset 0.23 -x_pitch 0.46 -y_offset 0.23 -y_pitch 0.46
make_tracks met3 -x_offset 0.34 -x_pitch 0.68 -y_offset 0.34 -y_pitch 0.68
make_tracks met4 -x_offset 0.46 -x_pitch 0.92 -y_offset 0.46 -y_pitch 0.92
make_tracks met5 -x_offset 1.70 -x_pitch 3.40 -y_offset 1.70 -y_pitch 3.40

# -----------------------------------------------------------------------------
# TAP / ENDCAP CELLS
# Without periodic N-well taps, N-well regions across cell rows aren't tied
# to VPWR at regular intervals, which fails Sky130 nwell width/spacing DRC
# (nwell.1, nwell.2a) once real cell geometry is checked in Magic.
# -----------------------------------------------------------------------------
tapcell -tapcell_master sky130_fd_sc_hd__tapvpwrvgnd_1 -distance 15

# -----------------------------------------------------------------------------
# I/O PIN PLACEMENT
# -----------------------------------------------------------------------------
place_pins -hor_layers met3 -ver_layers met2

# -----------------------------------------------------------------------------
# WIRE RC ESTIMATE (Flow v1, step 1 of 5)
# global_placement has no timing signal without this: it computes R/C per
# unit length from the tech LEF's per-layer RPERSQ/CPERSQDIST for met2
# (dominant signal-routing layer by measured wirelength: 59629um vs met1's
# 53741um in the Flow v0 route report) and met3 (used for clock buffering
# in this flow's clock_tree_synthesis step below).
# -----------------------------------------------------------------------------
set_wire_rc -signal -layer met2
set_wire_rc -clock -layer met3

# -----------------------------------------------------------------------------
# GLOBAL PLACEMENT (Flow v1, step 2 of 5: -timing_driven)
# -----------------------------------------------------------------------------
global_placement -density 0.6 -timing_driven

# -----------------------------------------------------------------------------
# DETAILED PLACEMENT
# -----------------------------------------------------------------------------
detailed_placement
check_placement

# -----------------------------------------------------------------------------
# DESIGN REPAIR (Flow v1, step 3 of 5)
# Fixes max_cap/max_slew/max_fanout violations by inserting buffers and
# upsizing gates -- the mechanism that actually targets a single min-drive
# cell driving many fanout pins (the Step 1 diagnosis / Step 2's remaining
# carry-chain slew). Requires legal placement (just done above) and must be
# followed by detailed_placement to re-legalize newly inserted/resized cells.
# -----------------------------------------------------------------------------
repair_design
detailed_placement
check_placement

# -----------------------------------------------------------------------------
# POWER DISTRIBUTION NETWORK
# TritonRoute (detailed_route below) requires power/ground nets to have real
# rail geometry and be classified as special nets; without this step it
# errors on the standard cells' implicit VPWR/VGND connections.
# -----------------------------------------------------------------------------
add_global_connection -net VPWR -pin_pattern {^VPWR$} -power
add_global_connection -net VGND -pin_pattern {^VGND$} -ground
global_connect

set_voltage_domain -name CORE -power VPWR -ground VGND
define_pdn_grid -name main_grid -voltage_domains CORE
add_pdn_stripe -grid main_grid -layer met1 -width 0.48 -followpins
pdngen

# -----------------------------------------------------------------------------
# CLOCK TREE SYNTHESIS
# -----------------------------------------------------------------------------
clock_tree_synthesis -root_buf sky130_fd_sc_hd__clkbuf_4 -buf_list sky130_fd_sc_hd__clkbuf_4
detailed_placement

# -----------------------------------------------------------------------------
# POST-CTS TIMING REPAIR (Flow v1, step 4 of 5)
# Real clock tree now exists (post-CTS), so repair against the propagated
# clock rather than the ideal clock used during placement -- CTS insertion
# delay/skew can change which paths are critical. estimate_parasitics
# -placement gives repair_timing an RC estimate before routing exists.
# -----------------------------------------------------------------------------
set_propagated_clock [all_clocks]
estimate_parasitics -placement
repair_timing -setup
detailed_placement
check_placement

# -----------------------------------------------------------------------------
# FILLER CELLS
# Detailed placement legalizes cell positions but doesn't require rows to be
# fully abutted — leftover gaps between cells break the continuous N-well
# strip each row shares, which fails Sky130 nwell width/spacing DRC (nwell.1,
# nwell.2a). Filling every gap restores a continuous row.
# -----------------------------------------------------------------------------
filler_placement {sky130_fd_sc_hd__fill_1 sky130_fd_sc_hd__fill_2 sky130_fd_sc_hd__fill_4 sky130_fd_sc_hd__fill_8}

# -----------------------------------------------------------------------------
# ROUTING
# -----------------------------------------------------------------------------
global_route
detailed_route

# -----------------------------------------------------------------------------
# OUTPUTS
# -----------------------------------------------------------------------------
write_def output/cordic_top_routed.def
write_verilog output/cordic_top_routed.v

# -----------------------------------------------------------------------------
# PARASITIC EXTRACTION (OpenRCX)
# Real, routed-geometry RC extraction from the detailed-routed DEF, using
# volare's calibrated Sky130A OpenRCX rules deck (pdk/sky130_fd_sc_hd_rcx_rules
# .nom.magic, a symlink to sky130A/libs.tech/openlane/rules.openrcx.sky130A
# .nom.magic — the "nom" = nominal/typical corner, matching the tt_025C_1v80
# Liberty used everywhere else in this flow). extract_parasitics walks the
# actual routed wires and vias TritonRoute just placed and computes real
# per-net R/C from this calibrated model, instead of an ideal-wire/statistical
# wireload guess.
#
# NOTE: `extract_parasitics -lef_rc` (deriving R/C straight from the tech
# LEF's per-layer RESISTANCE/CAPACITANCE fields, no rules deck) reliably
# segfaults this OpenROAD build post-extraction (RCX-0468 "Can't open
# extraction model file" followed by a crash in ~rcx::extRCModel, even
# though the LEF has RC data — reproduced independently here and matches a
# prior audit's own finding, see evidence at
# /home/peskybird/cordic-audit-32e9748/evidence/rcx.log if present on this
# machine). Passing an explicit -ext_model_file avoids that path entirely
# and is what actually works.
#
# The resulting SPEF is written for a *separate* standalone OpenSTA run
# (scripts/sta_postroute.tcl) so post-route timing is checked with the same
# tool/flow as pre-layout STA, not just OpenROAD's own internal timer (which
# may use different default derating/corner settings from a bare OpenSTA
# invocation, and would not by itself demonstrate that a standalone,
# extracted-RC STA run agrees with what OpenROAD reports inline below).
# -----------------------------------------------------------------------------
extract_parasitics -ext_model_file pdk/sky130_fd_sc_hd_rcx_rules.nom.magic
write_spef output/cordic_top_routed.spef

# -----------------------------------------------------------------------------
# REPORTS
# -----------------------------------------------------------------------------
report_design_area
report_worst_slack -max
report_tns

puts "=== OpenROAD P&R Complete ==="
puts "Output files:"
puts "  Routed DEF:  output/cordic_top_routed.def"
puts "  Routed netlist: output/cordic_top_routed.v"
puts "  Extracted SPEF: output/cordic_top_routed.spef"
