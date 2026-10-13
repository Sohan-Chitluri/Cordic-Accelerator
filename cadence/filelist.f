#==============================================================================
# CORDIC Accelerator - SystemVerilog Source Filelist
# Architecture: Adaptive-11 CORDIC (Architecture B1)
# Target: Cadence Genus / Innovus Flow
# Dependency order: package first, then primitives, stage, pipeline, top wrapper
#==============================================================================

rtl/pkg/cordic_pkg.sv
rtl/fp_add_sub.sv
rtl/cordic_lut.sv
rtl/cordic_stage.sv
rtl/cordic_pipeline.sv
rtl/cordic_top.sv
