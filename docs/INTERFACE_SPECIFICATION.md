# CORDIC Accelerator — INTERFACE_SPECIFICATION.md

**Project:** Parameterized Fixed-Point Pipelined CORDIC Accelerator (V1)  
**Document Version:** 1.0  
**Status:** APPROVED — Single Source of Truth  
**Derived From:** `SPECIFICATION.md`, `MICROARCHITECTURE.md`, `PIPELINE.md`

---

## 1. Top-Level Interface (`cordic_top`)

### 1.1 Port List

```systemverilog
module cordic_top #(
  parameter int WIDTH       = 16,
  parameter int FRACT_W     = 12,
  parameter int ITERATIONS  = 8
) (
  input  logic                    clk,
  input  logic                    rst_n,
  // Data Input
  input  logic signed [WIDTH-1:0] x_in,
  input  logic signed [WIDTH-1:0] y_in,
  input  logic signed [WIDTH-1:0] z_in,
  input  logic                    valid_in,
  output logic                    ready_out,
  // Configuration
  input  logic [3:0]              cfg_iterations,
  input  logic                    cfg_saturate,
  input  logic                    config_valid,
  output logic                    config_ready,
  // Data Output
  output logic signed [WIDTH-1:0] x_out,
  output logic signed [WIDTH-1:0] y_out,
  output logic signed [WIDTH-1:0] z_out,
  output logic                    valid_out,
  input  logic                    ready_in,
  // Status
  output logic                    overflow,
  output logic                    irq
);
```

### 1.2 Signal Descriptions

| Signal | Direction | Width | Clock Domain | Description |
|--------|-----------|-------|--------------|-------------|
| `clk` | Input | 1 | — | Rising-edge clock |
| `rst_n` | Input | 1 | `clk` | Active-low synchronous reset |
| `x_in` | Input | `WIDTH` | `clk` | X input (Q-format) |
| `y_in` | Input | `WIDTH` | `clk` | Y input (Q-format) |
| `z_in` | Input | `WIDTH` | `clk` | Angle input (radians, Q-format) |
| `valid_in` | Input | 1 | `clk` | Input data valid |
| `ready_out` | Output | 1 | `clk` | Ready to accept input |
| `cfg_iterations` | Input | 4 | `clk` | Iteration count (1-16) |
| `cfg_saturate` | Input | 1 | `clk` | 1=saturate, 0=wrap |
| `config_valid` | Input | 1 | `clk` | Configuration valid |
| `config_ready` | Output | 1 | `clk` | Ready for configuration |
| `x_out` | Output | `WIDTH` | `clk` | X output |
| `y_out` | Output | `WIDTH` | `clk` | Y output |
| `z_out` | Output | `WIDTH` | `clk` | Residual angle (~0) |
| `valid_out` | Output | 1 | `clk` | Output data valid |
| `ready_in` | Input | 1 | `clk` | Downstream ready |
| `overflow` | Output | 1 | `clk` | Saturation occurred |
| `irq` | Output | 1 | `clk` | Pipeline completion interrupt |

---

## 2. Configuration Handshake Protocol

```
Cycle N:     config_valid ────█────
                       │
Cycle N+1:   config_ready ────█──── (asserted 1 cycle after config_valid)
                       │
Internal:    cfg_reg ← cfg (captured on config_valid)
             Applies to NEXT input vector
```

**Timing Rules:**
- `config_ready` asserted **1 cycle after** `config_valid`
- Configuration captured on rising edge when `config_valid=1`
- New configuration applies to the **next** `valid_in` transaction
- `config_ready` remains high unless back-to-back configs (then 1-cycle gap)

---

## 3. Data Input Handshake (Valid/Ready)

```
Cycle N:     valid_in ────█──────█──────█────
                      │       │       │
Cycle N:     ready_out ──█───────█───────█──── (asserted when pipeline can accept)
                      │       │       │
Internal:    Capture x_in, y_in, z_in on valid_in & ready_out
```

**Rules:**
- Data transferred when `valid_in=1` AND `ready_out=1`
- `ready_out` deasserts when pipeline output stage full AND `ready_in=0`
- `ready_out` deasserts **1 cycle after** `ready_in=0` (pipeline depth = 1)

---

## 4. Data Output Handshake (Valid/Ready)

```
Cycle N:     valid_out ────────────█──────█──────█────
                        │          │       │       │
Cycle N:     ready_in ──────────────█───────█───────█──
                        │          │       │       │
Internal:    Output held until ready_in=1
```

**Rules:**
- `valid_out` asserts when output stage has valid data
- Data held until `ready_in=1`
- `overflow` and `irq` asserted with `valid_out`

---

## 5. Module Interfaces

### 5.1 `cordic_pkg.sv` — Package (No Ports)

**Exports:** Types, constants, functions (see `SPECIFICATION.md` Section 6)

```systemverilog
package cordic_pkg;
  parameter int WIDTH = 16;
  parameter int FRACT_W = 12;
  parameter int ITERATIONS = 8;
  
  typedef logic signed [WIDTH-1:0] fixed_t;
  typedef logic signed [WIDTH:0]   fixed_ext_t;
  typedef logic [3:0]              cfg_iterations_t;
  typedef logic                    cfg_saturate_t;
  
  typedef struct packed {
    logic [3:0] iterations;
    logic       saturate;
    logic [1:0] reserved;
  } cordic_cfg_t;
  
  // Functions: sat_add, sat_sub, arith_shift_right, real_to_fixed, fixed_to_real, k_factor_prescale
endpackage
```

---

### 5.2 `cordic_lut.sv` — K-Factor Prescaler (Shift-Add Constant)

```systemverilog
module cordic_lut #(
  parameter int WIDTH      = cordic_pkg::WIDTH,
  parameter int FRACT_W    = cordic_pkg::FRACT_W,
  parameter int ITERATIONS = cordic_pkg::ITERATIONS
) (
  input  logic signed [WIDTH-1:0]  x_in,         // full-precision X input
  input  logic signed [WIDTH-1:0]  y_in,         // full-precision Y input
  output logic signed [WIDTH-1:0]  k_prescale_x, // round(K * x_in)
  output logic signed [WIDTH-1:0]  k_prescale_y  // round(K * y_in)
);
```

K-prescaling uses a multiplier-free shift-add constant network:  
`v × 2488 = (v<<11) + (v<<9) − (v<<6) − (v<<3)`, then `k = (v×2488 + 2048) >>> 12`  
(round-to-nearest arithmetic right shift). K ≈ 2488/4096 = 0.607421875 (0.028% vs. true K). See ADR-0005.

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| `x_in` | Input | `WIDTH` | Full-precision X input (signed, Q-format) |
| `y_in` | Input | `WIDTH` | Full-precision Y input (signed, Q-format) |
| `k_prescale_x` | Output | `WIDTH` | `round(K × x_in)` via shift-add |
| `k_prescale_y` | Output | `WIDTH` | `round(K × y_in)` via shift-add |

**Note:** Per-stage `atan(2⁻ⁱ)` angle constants are embedded directly in each `cordic_stage` instance as localparams; `cordic_lut` is solely responsible for K-factor prescaling.

**Timing:** Purely combinational (0-cycle latency)

---

### 5.3 `fp_add_sub.sv` — Saturating Adder/Subtractor

```systemverilog
module fp_add_sub #(
  parameter int WIDTH = 16,
  parameter int FRACT_W = 12
) (
  input  logic signed [WIDTH-1:0] a,
  input  logic signed [WIDTH-1:0] b,
  input  logic                    op,      // 0 = add, 1 = subtract
  input  logic                    sat,     // 1 = saturate, 0 = wrap
  output logic signed [WIDTH-1:0] result,
  output logic                    overflow
);
```

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| `a` | Input | `WIDTH` | Operand A |
| `b` | Input | `WIDTH` | Operand B |
| `op` | Input | 1 | 0=add, 1=subtract |
| `sat` | Input | 1 | 1=saturate, 0=wrap |
| `result` | Output | `WIDTH` | Result (saturated or wrapped) |
| `overflow` | Output | 1 | 1 if saturation occurred |

**Timing:** Combinational (1-cycle if registered externally)

---

### 5.4 `cordic_stage.sv` — Single CORDIC Iteration

```systemverilog
module cordic_stage #(
  parameter int WIDTH = 16,
  parameter int FRACT_W = 12
) (
  input  logic signed [WIDTH-1:0] x_in,
  input  logic signed [WIDTH-1:0] y_in,
  input  logic signed [WIDTH-1:0] z_in,
  input  logic [$clog2(ITERATIONS):0] stage_idx,  // Fixed per instance
  input  logic                    valid_in,
  input  logic                    sat,
  output logic signed [WIDTH-1:0] x_out,
  output logic signed [WIDTH-1:0] y_out,
  output logic signed [WIDTH-1:0] z_out,
  output logic                    valid_out,
  output logic                    overflow
);
```

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| `x_in` | Input | `WIDTH` | X input |
| `y_in` | Input | `WIDTH` | Y input |
| `z_in` | Input | `WIDTH` | Z input (angle) |
| `stage_idx` | Input | `$clog2(ITERATIONS)` | Stage index (0..N-1) — **hardwired per instance** |
| `valid_in` | Input | 1 | Input valid |
| `sat` | Input | 1 | Saturation mode |
| `x_out` | Output | `WIDTH` | X output |
| `y_out` | Output | `WIDTH` | Y output |
| `z_out` | Output | `WIDTH` | Z output |
| `valid_out` | Output | 1 | Output valid (registered) |
| `overflow` | Output | 1 | Overflow from any adder |

**Timing:** 1-cycle latency (input registered, output registered)

**Internal:** Instantiates 3× `fp_add_sub`; shift amount hardwired by `stage_idx`

---

### 5.5 `cordic_pipeline.sv` — N-Stage Pipeline

```systemverilog
module cordic_pipeline #(
  parameter int WIDTH       = 16,
  parameter int FRACT_W     = 12,
  parameter int ITERATIONS  = 8
) (
  input  logic                    clk,
  input  logic                    rst_n,
  // Input
  input  logic signed [WIDTH-1:0] x_in,
  input  logic signed [WIDTH-1:0] y_in,
  input  logic signed [WIDTH-1:0] z_in,
  input  logic                    valid_in,
  output logic                    ready_out,
  // Config
  input  logic [3:0]              cfg_iterations,
  input  logic                    cfg_saturate,
  input  logic                    config_valid,
  output logic                    config_ready,
  // Output
  output logic signed [WIDTH-1:0] x_out,
  output logic signed [WIDTH-1:0] y_out,
  output logic signed [WIDTH-1:0] z_out,
  output logic                    valid_out,
  input  logic                    ready_in,
  // Status
  output logic                    overflow,
  output logic                    irq
);
```

**Internal Structure:**
- `cordic_lut` (1 instance)
- `cordic_stage` (ITERATIONS instances)
- Valid pipeline shift register (ITERATIONS+2 deep)
- Config register + handshake

---

## 6. Handshake Timing Diagrams

### 6.1 Continuous Flow (No Backpressure)

```
clk:         ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐
valid_in:    ──█─█─█─█─█─█─█─█─█─█─█──
ready_out:   ────█─█─█─█─█─█─█─█─█─█─█
valid_out:   ────────────────────█─█─█─█
ready_in:    ────────────────────█─█─█─█
```

### 6.2 Backpressure (Downstream Not Ready)

```
clk:         ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐
valid_in:    ──█─█─█─█───────█─█─█─█
ready_out:   ────█─█─█────█─────█─█─█
valid_out:   ────────────────█─█──████
ready_in:    ────────────────█─────█─█
             ▲              ▲
             │              │
        Pipeline fills  Pipeline drains
        (ready_out=0)   (ready_in=1)
```

---

## 7. Configuration Timing

```
clk:            ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐
config_valid:   ──█───────█───────█────
config_ready:   ────█───────█───────█───
cfg_reg:        ──░───────░───────░────  (updated on config_valid)
                 (cfg0)    (cfg1)   (cfg2)
                
valid_in:       ──█────█────█────█────█──
                  v0   v1   v2   v3   v4
                  
Applies to:      cfg0  cfg0  cfg1  cfg1  cfg2
```

**Rule:** Configuration captured at cycle N applies to first `valid_in` at cycle > N.

---

## 8. Reset Timing

```
clk:      ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐
rst_n:    ────█────────────── (active low, synchronous)
          
Internal: Pipeline clears in 1 cycle
valid_pipe: all zeros after rst_n deasserts
valid_in:   First capture at cycle 2 after rst_n
valid_out:  First assertion at cycle ITERATIONS+3 after rst_n
```

---

## 9. Interrupt (`irq`) Behavior

| Condition | `irq` Assertion |
|-----------|-----------------|
| Pipeline completes a vector | 1 cycle with `valid_out` |
| Configuration captured | 1 cycle with `config_ready` |
| Error condition (overflow) | 1 cycle with `overflow` |

**Implementation:** `irq = valid_out | config_ready | overflow;` (pulsed, 1 cycle)

---

## 10. Parameter Definitions (Elaboration-Time)

| Parameter | Module(s) | Default | Description |
|-----------|-----------|---------|-------------|
| `WIDTH` | All | 16 | Total bit width |
| `FRACT_W` | All | 12 | Fractional bits |
| `ITERATIONS` | `cordic_pipeline`, `cordic_lut`, `cordic_top` | 8 | Pipeline stages |
| `K_FACTOR` | `cordic_pkg`, `cordic_lut` | 0.60725... | CORDIC gain |

**Parameter Propagation:**
```systemverilog
// cordic_top → cordic_pipeline
cordic_pipeline #(
  .WIDTH(WIDTH),
  .FRACT_W(FRACT_W),
  .ITERATIONS(ITERATIONS)
) pipeline_inst (...);

// cordic_pipeline → cordic_stage (per instance)
genvar i;
generate
  for (i = 0; i < ITERATIONS; i++) begin : g_stages
    cordic_stage #(
      .WIDTH(WIDTH),
      .FRACT_W(FRACT_W)
    ) stage_inst (
      .stage_idx(i[$clog2(ITERATIONS):0]),
      ...
    );
  end
endgenerate
```

---

## 11. Interface Contract Summary

| Interface | Producer | Consumer | Protocol | Latency |
|-----------|----------|----------|----------|---------|
| Top Data In | External | `cordic_top` | Valid/Ready | 1 cycle capture |
| Top Config | External | `cordic_top` | Valid/Ready | 1 cycle capture |
| LUT Angle | `cordic_lut` | `cordic_stage` | Combinational | 0 cycles |
| LUT K-Prescale | `cordic_lut` | `cordic_pipeline` | Combinational | 0 cycles |
| Stage Data | `cordic_stage[i]` | `cordic_stage[i+1]` | Registered | 1 cycle |
| Valid Pipe | `cordic_pipeline` | All stages | Shift register | 1 cycle/shift |
| Top Data Out | `cordic_pipeline` | External | Valid/Ready | 1 cycle hold |

---

**End of INTERFACE_SPECIFICATION.md**  
*This document defines all module interfaces, signal timing, and handshake protocols. RTL implementation must match exactly.*