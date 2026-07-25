# CORDIC Accelerator — PIPELINE.md

**Project:** Parameterized Fixed-Point Pipelined CORDIC Accelerator (V1)  
**Document Version:** 1.0  
**Status:** APPROVED — Single Source of Truth  
**Derived From:** `SPECIFICATION.md`, `MICROARCHITECTURE.md`

---

## 1. Pipeline Overview

| Parameter | Value |
|-----------|-------|
| **Total Stages** | `ITERATIONS + 2` (default: 10 for ITERATIONS=8) |
| **Pipeline Type** | Linear, fixed-latency, valid/ready handshake |
| **Throughput** | 1 vector/cycle (after fill) |
| **Latency** | `ITERATIONS + 2` cycles |
| **Fill Cycles** | `ITERATIONS + 2` |
| **Drain Cycles** | `ITERATIONS + 2` |

---

## 2. Per-Stage Responsibilities

### Stage -1: Input Capture & K-Prescale (Cycle 0)

| Signal | Source | Destination | Registered |
|--------|--------|-------------|------------|
| `x_in`, `y_in`, `z_in` | Top-level input | `cordic_pipeline` input reg | Yes |
| `valid_in` | Top-level input | `cordic_pipeline` valid_pipe[0] | Yes |
| `k_prescale_x`, `k_prescale_y` | `cordic_lut` (combinational) | `cordic_pipeline` x_reg, y_reg | Yes (after LUT) |

**Operations:**
- Capture input vector on `valid_in & ready_out`
- Apply K-factor prescaling via `cordic_lut` (4 MSBs of x,y → LUT index)
- Load into Stage 0 input registers

---

### Stage 0..N-1: CORDIC Iterations (Cycles 1..N)

For each stage `i` (0-indexed):

| Signal | Operation | Shift Amount | Registered Output |
|--------|-----------|--------------|-------------------|
| `x` | `x - σ × (y >> i)` | `i` bits | `x_stage[i+1]` |
| `y` | `y + σ × (x >> i)` | `i` bits | `y_stage[i+1]` |
| `z` | `z - σ × atan(2⁻ⁱ)` | N/A (LUT) | `z_stage[i+1]` |
| `valid` | Shift register | N/A | `valid_pipe[i+1]` |

**Where:**
- `σ = sign(z_stage[i][MSB])` — 1 if positive, -1 if negative
- `atan(2⁻ⁱ)` from `cordic_lut` (combinational)
- Shift is **hardwired** per stage (no barrel shifter)

---

### Stage N: Output Register (Cycle N+1)

| Signal | Source | Destination | Registered |
|--------|--------|-------------|------------|
| `x_stage[N]`, `y_stage[N]`, `z_stage[N]` | Last CORDIC stage | Top-level output | Yes |
| `valid_pipe[N]` | Valid shift register | `valid_out` | Yes |
| `overflow` | OR of all stage overflows | Top-level output | Yes |

---

## 3. Register Boundaries

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ PIPELINE REGISTER BOUNDARIES                                                 │
├────────────────┬────────────────────────────────────────────────────────────┤
│ Boundary       │ Registers                                                  │
├────────────────┼────────────────────────────────────────────────────────────┤
│ Input Capture  │ x_in_reg[WIDTH-1:0], y_in_reg, z_in_reg                   │
│                │ valid_pipe[0]                                              │
├────────────────┼────────────────────────────────────────────────────────────┤
│ Stage 0 Out    │ x_stage[1], y_stage[1], z_stage[1]                        │
│                │ valid_pipe[1]                                              │
├────────────────┼────────────────────────────────────────────────────────────┤
│ Stage i Out    │ x_stage[i+1], y_stage[i+1], z_stage[i+1]                  │
│                │ valid_pipe[i+1]                                            │
├────────────────┼────────────────────────────────────────────────────────────┤
│ Stage N-1 Out  │ x_stage[N], y_stage[N], z_stage[N]                        │
│                │ valid_pipe[N]                                              │
├────────────────┼────────────────────────────────────────────────────────────┤
│ Output Reg     │ x_out_reg, y_out_reg, z_out_reg                           │
│                │ valid_out_reg                                              │
│                │ overflow_reg                                               │
└────────────────┴────────────────────────────────────────────────────────────┘
```

---

## 4. Signal Timing Diagram

```
CLK:        │─┐   │─┐   │─┐   │─┐   │─┐   │─┐   │─┐   │─┐   │─┐   │─┐
            │ │   │ │   │ │   │ │   │ │   │ │   │ │   │ │   │ │   │ │
Cycle:      0   1   2   3   4   5   6   7   8   9   10  11  12
            │   │   │   │   │   │   │   │   │   │   │   │   │   │
valid_in:   ──█───░░░░█───░░░░█───░░░░█───░░░░█───░░░░█───░░░░█───
            (v0)    (v1)    (v2)    (v3)    (v4)    (v5)
            │   │   │   │   │   │   │   │   │   │   │   │   │   │
ready_out:  ──█───░░░░█───░░░░█───░░░░█───░░░░█───░░░░█───░░░░█───
            (high)  (high)  (high)  (high)  (high)  (high)
            │   │   │   │   │   │   │   │   │   │   │   │   │   │
Stage 0:    ────────█───░░░░█───░░░░█───░░░░█───░░░░█───░░░░█───
            (v0)    (v1)    (v2)    (v3)    (v4)    (v5)
            │   │   │   │   │   │   │   │   │   │   │   │   │   │
Stage 1:    ────────────█───░░░░█───░░░░█───░░░░█───░░░░█───░░░░
            (v0)    (v1)    (v2)    (v3)    (v4)    (v5)
            │   │   │   │   │   │   │   │   │   │   │   │   │   │
    ...                                                      ...
            │   │   │   │   │   │   │   │   │   │   │   │   │   │
Stage N-1:  ──────────────────────────────█───░░░░█───░░░░█───
            (v0)    (v1)    (v2)
            │   │   │   │   │   │   │   │   │   │   │   │   │   │
valid_out:  ────────────────────────────────────█───░░░░█───░░░░
            (v0)    (v1)    (v2)
            │   │   │   │   │   │   │   │   │   │   │   │   │   │
ready_in:   ────────────────────────────────────█───█───█───█───
            (high)  (high)  (high)
```

**Legend:**
- `█` = Valid data present
- `░` = Pipeline stage processing
- Cycle 0: Input capture + K-prescale
- Cycles 1-N: CORDIC stages 0 to N-1
- Cycle N+1: Output register

---

## 5. Latency Analysis

| Configuration | ITERATIONS | Total Latency | Fill Cycles | Drain Cycles |
|---------------|------------|---------------|-------------|--------------|
| Default (16-bit) | 8 | 10 cycles | 10 | 10 |
| High Precision | 16 | 18 cycles | 18 | 18 |
| Minimal | 4 | 6 cycles | 6 | 6 |

**Formula:** `Latency = ITERATIONS + 2`

---

## 6. Throughput Analysis

### 6.1 Ideal Throughput (No Backpressure)

| Metric | Value |
|--------|-------|
| **Steady-state throughput** | 1 vector/cycle |
| **Max sustained rate** | Fmax vectors/second |
| **Pipeline efficiency** | 100% (no bubbles in steady state) |

### 6.2 Backpressure Scenarios

| Scenario | Behavior | Throughput Impact |
|----------|----------|-------------------|
| `ready_in = 1` always | Full throughput | 1 vector/cycle |
| `ready_in = 0` for 1 cycle | Pipeline stalls 1 cycle | 1 bubble inserted |
| `ready_in = 0` for M cycles | Pipeline stalls M cycles | M bubbles inserted |
| Periodic `ready_in` | Throttled to downstream rate | Matches downstream |

**Backpressure Latency:** When `ready_in` deasserts, `ready_out` deasserts after **1 cycle** (output stage full).

---

## 7. Valid Pipeline Implementation

```systemverilog
// In cordic_pipeline
localparam int VALID_DEPTH = ITERATIONS + 2;  // input + N stages + output
logic [VALID_DEPTH-1:0] valid_pipe;

always_ff @(posedge clk) begin
  if (!rst_n) begin
    valid_pipe <= '0;
  end else begin
    // ready_out = pipeline can accept (output stage not full OR downstream ready)
    logic ready_out_int;
    ready_out_int = !valid_pipe[VALID_DEPTH-1] | ready_in;
    
    // Shift valid pipeline
    valid_pipe <= {valid_pipe[VALID_DEPTH-2:0], valid_in & ready_out_int};
  end
end

assign ready_out = ready_out_int;
assign valid_out = valid_pipe[VALID_DEPTH-1];
```

---

## 8. Configuration Pipeline

| Signal | Timing | Description |
|--------|--------|-------------|
| `config_valid` | Asserted with `cfg` | Captured in 1 cycle |
| `config_ready` | Asserted next cycle | Ready for new config |
| `cfg_reg` | Updated on `config_valid` | Applies to **next** input vector |

**Configuration does not stall data pipeline.** Config captured in parallel.

---

## 9. Overflow Tracking

| Source | Signal | Propagation |
|--------|--------|-------------|
| `fp_add_sub` (x-path) | `overflow_x` | OR-reduced across all stages |
| `fp_add_sub` (y-path) | `overflow_y` | OR-reduced across all stages |
| `fp_add_sub` (z-path) | `overflow_z` | OR-reduced across all stages |
| **Top-level** | `overflow = overflow_x | overflow_y | overflow_z` | Registered at output |

---

## 10. Reset Behavior

| Cycle | Pipeline State |
|-------|----------------|
| Reset asserted | All `valid_pipe` = 0, all data regs = 0, `config_reg` = defaults |
| Reset deasserted | Pipeline ready; first `valid_in` captured next cycle |
| Latency after reset | `ITERATIONS + 2` cycles to first `valid_out` |

---

## 11. Timing Constraints (Per Stage)

| Path | Budget (16-bit, 200 MHz = 5 ns) | Margin |
|------|----------------------------------|--------|
| Stage i: shift → MUX → fp_add_sub → reg | ≤ 2.5 ns | 50% |
| LUT → Stage 0 input reg | ≤ 1 ns | 80% |
| Valid pipeline shift | ≤ 0.5 ns | 90% |
| Config capture | ≤ 1 ns | 80% |

---

## 12. Waveform Verification Points

| Check | Signal | Expected |
|-------|--------|----------|
| Pipeline fill | `valid_out` | First assertion at cycle `ITERATIONS+2` |
| Throughput | `valid_out` | Asserted every cycle after fill |
| Backpressure | `ready_out` | Deasserts 1 cycle after `ready_in=0` |
| Data correctness | `x_out, y_out` | Match golden model ±1 LSB |
| Overflow | `overflow` | Asserted iff saturation occurred |
| Configuration | `config_ready` | Asserted 1 cycle after `config_valid` |

---

**End of PIPELINE.md**  
*This document defines the canonical pipeline behavior. RTL must implement exactly this timing and register structure.*