#==============================================================================
# Magic LVS Extraction Script for CORDIC Accelerator
# Extracts a layout-side netlist for Netgen LVS, treating standard cells as
# opaque devices (matched by name against the synthesized Verilog) rather
# than descending into their transistor-level geometry. Deliberately does
# NOT load the standard-cell GDS (unlike scripts/drc.tcl, which needs real
# geometry for DRC/GDS export) — LEF abstracts alone keep cell instances as
# black boxes during extraction, which is what LVS needs.
# Usage: PDK_ROOT=<sky130 volare version dir> magic -noconsole -dnull \
#          -rcfile $PDK_ROOT/sky130A/libs.tech/magic/sky130A.magicrc \
#          scripts/lvs_extract.tcl
#==============================================================================

lef read pdk/sky130_fd_sc_hd_techlef/sky130_fd_sc_hd__nom.tlef
lef read pdk/sky130_fd_sc_hd_lef/sky130_fd_sc_hd.lef

def read output/cordic_top_routed.def

load cordic_top
select top cell

extract path output/lvs_extract
extract all
path search output/lvs_extract
ext2spice lvs
ext2spice
exec mv cordic_top.spice output/lvs_extract/cordic_top.spice

puts "=== Magic LVS Extraction Complete ==="
puts "  Layout-side netlist: output/lvs_extract/cordic_top.spice"

quit -noprompt
