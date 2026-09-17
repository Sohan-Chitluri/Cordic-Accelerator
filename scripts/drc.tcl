#==============================================================================
# Magic DRC Script for CORDIC Accelerator
# Reads the OpenROAD-routed DEF, runs Sky130 HD DRC, writes GDSII.
# Usage: PDK_ROOT=<sky130 volare version dir> magic -noconsole -dnull \
#          -rcfile $PDK_ROOT/sky130A/libs.tech/magic/sky130A.magicrc \
#          scripts/drc.tcl
#==============================================================================

lef read pdk/sky130_fd_sc_hd_techlef/sky130_fd_sc_hd__nom.tlef
lef read pdk/sky130_fd_sc_hd_lef/sky130_fd_sc_hd.lef

# Standard-cell real layout geometry (LEF above only gives abstract boxes —
# needed for placement/routing but not for DRC or GDS output).
gds read pdk/sky130_fd_sc_hd_gds/sky130_fd_sc_hd.gds

def read output/cordic_top_routed.def

load cordic_top
select top cell

drc check
set drc_violations [drc listall why]
puts "=== DRC Violation Count: [llength $drc_violations] ==="

set drc_fh [open output/cordic_top_drc.rpt w]
puts $drc_fh $drc_violations
close $drc_fh

gds write output/cordic_top.gds

puts "=== Magic DRC + GDS Complete ==="
puts "  DRC report: output/cordic_top_drc.rpt"
puts "  GDSII:      output/cordic_top.gds"
puts "  For LVS, see scripts/lvs_extract.tcl (a separate, LEF-only"
puts "  extraction pass — this script's real cell GDS geometry, needed"
puts "  for DRC/GDS export, makes extraction descend into transistor-level"
puts "  detail inside standard cells, which is wrong for LVS matching)."

quit -noprompt
