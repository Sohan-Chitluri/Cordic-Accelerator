#==============================================================================
# Synopsys Design Constraints (SDC) for CORDIC Accelerator
# Target: Generic ASIC flow - adapt for specific PDK
#==============================================================================

# -----------------------------------------------------------------------------
# CLOCK DEFINITION
# -----------------------------------------------------------------------------
# Period 11.5ns (~87 MHz): measured post-synthesis Fmax, not an a-priori target
# (see ADR-0001 — this design has no fixed Fmax requirement, deliberately, to
# avoid over-constraining a student ASIC flow). 10.0ns (100MHz) failed timing
# by -1.08ns pre-layout / -0.58ns post-route on the fp_add_sub carry chain;
# 11.5ns gives ~0.4ns margin above the worst measured violation.
create_clock -name clk -period 11.500 [get_ports clk]
set_clock_uncertainty -setup 0.500 [get_clocks clk]
set_clock_uncertainty -hold 0.100 [get_clocks clk]

# -----------------------------------------------------------------------------
# INPUT DELAYS (relative to clk)
# -----------------------------------------------------------------------------
# Data inputs
set_input_delay -clock clk -max 2.0 [get_ports {x_in y_in z_in valid_in}]
set_input_delay -clock clk -min 0.5 [get_ports {x_in y_in z_in valid_in}]

# Configuration inputs
set_input_delay -clock clk -max 2.0 [get_ports {cfg_iterations cfg_saturate config_valid}]
set_input_delay -clock clk -min 0.5 [get_ports {cfg_iterations cfg_saturate config_valid}]

# Ready input
set_input_delay -clock clk -max 2.0 [get_ports ready_in]
set_input_delay -clock clk -min 0.5 [get_ports ready_in]

# -----------------------------------------------------------------------------
# OUTPUT DELAYS (relative to clk)
# -----------------------------------------------------------------------------
# Data outputs
set_output_delay -clock clk -max 3.0 [get_ports {x_out y_out z_out valid_out overflow irq}]
set_output_delay -clock clk -min 0.5 [get_ports {x_out y_out z_out valid_out overflow irq}]

# Ready output
set_output_delay -clock clk -max 2.0 [get_ports ready_out]
set_output_delay -clock clk -min 0.5 [get_ports ready_out]

# Config ready output
set_output_delay -clock clk -max 2.0 [get_ports config_ready]
set_output_delay -clock clk -min 0.5 [get_ports config_ready]

# -----------------------------------------------------------------------------
# RESET
# -----------------------------------------------------------------------------
# set_dont_touch_network is a Synopsys/Cadence-only command with no OpenSTA
# equivalent; rst_n has no clock-tree-style buffering concern in a P&R-less
# pre-layout STA flow, so it is simply omitted here.

# -----------------------------------------------------------------------------
# FALSE PATHS (none in V1 - single clock domain)
# -----------------------------------------------------------------------------
# No false paths in V1 design

# -----------------------------------------------------------------------------
# MULTICYCLE PATHS (none in V1)
# -----------------------------------------------------------------------------
# No multicycle paths in V1 design

# -----------------------------------------------------------------------------
# CLOCK GATING (handled via UPF in synthesis)
# -----------------------------------------------------------------------------
# No clock gating in RTL for V1

# -----------------------------------------------------------------------------
# DRIVING CELL / LOAD (optional - adjust for PDK)
# -----------------------------------------------------------------------------
# set_driving_cell -lib_cell BUF_X1 [get_ports {x_in y_in z_in valid_in cfg_iterations cfg_saturate config_valid ready_in}]
# set_load 0.05 [get_ports {x_out y_out z_out valid_out ready_out overflow irq config_ready}]