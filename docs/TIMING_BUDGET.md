# CORDIC Accelerator — TIMING_BUDGET.md

**Project:** Parameterized Fixed-Point Pipelined CORDIC Accelerator (V1)  
**Document Version:** 1.0  
**Status:** APPROVED — Single Source of Truth  
**Derived From:** `SPECIFICATION.md`, `MICROARCHITECTURE.md`, `PIPELINE.md`

---

## 1. Timing Budget Overview

| Level | Target | Notes |
|-------|--------|-------|
| **Stage Critical Path** | ≤ 2.5 ns (400 MHz equivalent) | Per-stage budget |
| **Pipeline Frequency** | Measured post-synthesis | No fixed Fmax target |
| **Clock Uncertainty** | 10% period | Conservative for student flow |
| **Setup/Hold Margin** | > 0 ns post-STA | Zero violations required |

---

## 2. Critical Path Analysis

### 2.1 Per-Stage Critical Path (`cordic_stage`)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ CRITICAL PATH: Stage i                                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   x_i ──────────────────────────────────────────────────────┐               │
│                                                              │               │
│   y_i ───► [Fixed Shift >> i] ──► [2:1 MUX] ──► [fp_add_sub] ├─► x_{i+1}    │
│                     (wire)        (σ_i)    (carry-select)      (reg)       │
│                                                              │               │
│   z_i ──────────────────────────────────────────────────────┘               │
│                     │                                                       │
│                     ▼                                                       │
│              [cordic_lut]                                                   │
│              (combinational)                                                │
│                     │                                                       │
│                     ▼                                                       │
│              atan(2⁻ⁱ)                                                      │
│                     │                                                       │
│                     ▼                                                       │
│              [fp_add_sub] ──► z_{i+1} (reg)                                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 Path Delays (Estimated, 16-bit, 28nm typical)

| Path Segment | Delay | Notes |
|--------------|-------|-------|
| Fixed shift (wire routing) | ~50 ps | Metal delay only |
| 2:1 MUX (σ_i select) | ~100 ps | 16-bit wide |
| `fp_add_sub` carry-select | ~1.2 ns | 16-bit, 4-bit blocks |
| Register setup + clock skew | ~200 ps | Conservative |
| **Total combinational** | **~1.55 ns** | |
| **Clock period (with margin)** | **2.5 ns (400 MHz)** | 38% margin |

### 2.3 Alternative: Ripple-Carry Fallback

| Adder Type | Delay | Area | Use Case |
|------------|-------|------|----------|
| Carry-select (4-bit blocks) | 1.2 ns | 2× RCA | Primary |
| Ripple-carry + reg stage | 2× 0.8 ns | 1× RCA | Fallback if timing fails |

---

## 3. Stage Timing Budget Allocation

| Stage Component | Budget | % of Period | Margin |
|-----------------|--------|-------------|--------|
| Fixed shift | 50 ps | 2% | High |
| MUX | 100 ps | 4% | High |
| Adder (carry-select) | 1.2 ns | 48% | Medium |
| Register overhead | 200 ps | 8% | Standard |
| Clock uncertainty (10%) | 250 ps | 10% | Conservative |
| **Total Used** | **1.8 ns** | **72%** | |
| **Slack** | **0.7 ns** | **28%** | **Target: > 0** |

---

## 4. Pipeline-Level Timing

### 4.1 Input Stage (Cycle 0)

| Path | Budget | Notes |
|------|--------|-------|
| Input reg → K-prescale LUT → Stage 0 input reg | 1.5 ns | LUT is combinational |

### 4.2 CORDIC Stages (Cycles 1..N)

| Path | Budget | Notes |
|------|--------|-------|
| Stage i reg → Stage i+1 reg | 2.5 ns | Per-stage budget above |

### 4.3 Output Stage (Cycle N+1)

| Path | Budget | Notes |
|------|--------|-------|
| Stage N-1 reg → Output reg | 1.0 ns | Simple register |

---

## 5. Inter-Module Timing

### 5.1 `cordic_lut` → `cordic_stage`

```
cordic_lut (combinational)
       │
       ├── angle_out ─────────────────────► cordic_stage (z-path adder)
       │
       └── k_prescale_x/y ──► cordic_pipeline input reg (cycle 0)
```

**Constraint:** `cordic_lut` must meet setup to Stage 0 input register.

### 5.2 `fp_add_sub` Internal

```
a, b, op, sat ──► [Carry-Select Adder] ──► result, overflow
```

**Constraint:** Purely combinational; registered at stage boundaries.

### 5.3 Valid Pipeline

```
valid_pipe[i] ──► [Flop] ──► valid_pipe[i+1]
```

**Constraint:** Simple shift register; meets timing easily (< 500 ps).

---

## 6. Clocking & Uncertainty

| Parameter | Value | Source |
|-----------|-------|--------|
| Clock period | Variable (measured) | Post-synthesis |
| Clock uncertainty | 10% period | Industry practice |
| Clock skew (global) | 100 ps | Estimate |
| Clock jitter | 50 ps | Estimate |
| **Total uncertainty** | **10% + 150 ps** | Conservative |

---

## 7. SDC Constraints (Template)

```tcl
# constraints/cordic.sdc
# Clock definition
create_clock -name clk -period 10.000 [get_ports clk]  # 100 MHz reference
set_clock_uncertainty -setup 0.500 [get_clocks clk]
set_clock_uncertainty -hold 0.100 [get_clocks clk]

# Input delays (relative to clk)
set_input_delay -clock clk -max 2.0 [get_ports {x_in y_in z_in valid_in}]
set_input_delay -clock clk -min 0.5 [get_ports {x_in y_in z_in valid_in}]
set_input_delay -clock clk -max 2.0 [get_ports {cfg_iterations cfg_saturate config_valid}]
set_input_delay -clock clk -min 0.5 [get_ports {cfg_iterations cfg_saturate config_valid}]

# Output delays (relative to clk)
set_output_delay -clock clk -max 3.0 [get_ports {x_out y_out z_out valid_out overflow irq}]
set_output_delay -clock clk -min 0.5 [get_ports {x_out y_out z_out valid_out overflow irq}]

# Ready signals (outputs from DUT perspective)
set_output_delay -clock clk -max 2.0 [get_ports ready_out]
set_output_delay -clock clk -min 0.5 [get_ports ready_out]

# Ready_in (input to DUT)
set_input_delay -clock clk -max 2.0 [get_ports ready_in]
set_input_delay -clock clk -min 0.5 [get_ports ready_in]

# Config ready (output)
set_output_delay -clock clk -max 2.0 [get_ports config_ready]
set_output_delay -clock clk -min 0.5 [get_ports config_ready]

# False paths (none in V1 - single clock domain)
# No multicycle paths in V1

# Reset
set_dont_touch_network [get_ports rst_n]
```

---

## 8. Post-Synthesis Evaluation Methodology

### 8.1 Measurement Steps

```bash
# 1. Synthesize
make synth

# 2. Extract netlist
# (tool-specific: yosys write_verilog, or vendor write_sdf)

# 3. STA
make sta

# 4. Parse reports
# - Worst Negative Slack (WNS)
# - Total Negative Slack (TNS)
# - Fmax = 1 / (period - WNS)
# - Critical path report
```

### 8.2 Pass/Fail Criteria

| Metric | Pass | Marginal | Fail |
|--------|------|----------|------|
| **WNS** | > 0 ns | 0 to -0.5 ns | < -0.5 ns |
| **TNS** | < 0.1 ns | 0.1 to 1 ns | > 1 ns |
| **Fmax** | > 100 MHz | 50-100 MHz | < 50 MHz |
| **Critical Path** | In adder | In LUT/MUX | In control logic |

### 8.3 Iteration Loop (If Timing Fails)

```
STA Fail
    │
    ▼
Analyze Critical Path
    │
    ├──► Adder too slow? → Ripple-carry + reg stage (2-cycle adder)
    ├──► LUT too slow?   → Register LUT output (1-cycle latency)
    ├──► MUX too slow?   → Reduce fanout, buffer
    └──► Register overhead? → Retime, add pipeline stage
    │
    ▼
Modify RTL / Constraints
    │
    ▼
Re-synthesize → STA
```

---

## 9. Timing Assumptions

| Assumption | Value | Risk if Wrong |
|------------|-------|---------------|
| Single clock domain | Yes | CDC would add 2+ cycles |
| No I/O registers in core | Yes | Adds 1 cycle latency each |
| Combinational LUT | 0-cycle | If RAM inferred → +1 cycle |
| Fixed shifts | Wire delay | If barrel shifter → +1ns |
| Carry-select adder | 4-bit blocks | If ripple → 2× delay |

---

## 10. Power-Timing Tradeoff (V1)

| Optimization | Timing Impact | Power Impact |
|--------------|---------------|--------------|
| Clock gating (UPF) | None | -20% dynamic |
| Operand isolation | None | -10% dynamic |
| Reduce ITERATIONS | Linear improvement | -10% per stage |
| Ripple-carry adder | 2× slower | -30% area/power |

**V1 Decision:** No clock gating in RTL (UPF handles); carry-select adder for timing margin.

---

**End of TIMING_BUDGET.md**  
*This budget guides implementation and STA sign-off. Actual measurements drive final closure.*