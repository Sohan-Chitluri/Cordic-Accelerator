#==============================================================================
# Synopsys Design Constraints (SDC) for CORDIC Accelerator
# Target: Generic ASIC flow - adapt for specific PDK
#==============================================================================

# -----------------------------------------------------------------------------
# CLOCK DEFINITION
# -----------------------------------------------------------------------------
create_clock -name clk -period 10.000 [get_ports clk]
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
set_dont_touch_network [get_ports rst_n]

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