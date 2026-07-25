# CORDIC Accelerator — MICROARCHITECTURE.md

**Project:** Parameterized Fixed-Point Pipelined CORDIC Accelerator (V1)  
**Document Version:** 1.0  
**Status:** APPROVED — Single Source of Truth  
**Derived From:** `SPECIFICATION.md`  
**Architecture Review:** See `architecture_review_decisions.md` and `adr/`

---

## 1. Overall Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           cordic_top                                        │
│  ┌─────────────┐  ┌─────────────────────────────────────────────────────┐  │
│  │  Config     │  │                  cordic_pipeline                    │  │
│  │  Handshake  │  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌────────┐  │  │
│  └──────┬──────┘  │  │  Stage 0 │ │  Stage 1 │ │  Stage 2 │ │ ...    │  │  │
│         │         │  └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬───┘  │  │
│         ▼         │       │            │            │            │      │  │
│  ┌─────────────┐  │       ▼            ▼            ▼            ▼      │  │
│  │  Pipeline   │  │  ┌──────────────────────────────────────────────┐  │  │
│  │  Control    │  │  │              cordic_lut (combinational)       │  │  │
│  │  (valid     │  │  │  • atan(2⁻ⁱ) for i=0..ITERATIONS-1           │  │  │
│  │   shifting) │  │  │  • K-factor prescale LUT (16 entries)        │  │  │
│  └─────────────┘  │  └──────────────────────────────────────────────┘  │  │
└───────────────────┴─────────────────────────────────────────────────────┘
```

**Top-Level Modules:**
| Module | Instance | Purpose |
|--------|----------|---------|
| `cordic_top` | 1 | Top-level I/O, config handshake, pipeline instantiation |
| `cordic_pipeline` | 1 | N-stage pipeline, valid/ready handshaking, stage instantiation |
| `cordic_stage` | N (parameterized) | Single CORDIC iteration: fixed shift + MUX + adder |
| `cordic_lut` | 1 | Combinational angle LUT + K-factor prescale LUT |
| `fp_add_sub` | 3×N (per stage: x, y, z) | Saturating adder/subtractor with carry-select |

---

## 2. Datapath

### 2.1 Data Representation

```
Fixed-point format: Q(FRACT_W).(WIDTH-FRACT_W-1) signed
Example (WIDTH=16, FRACT_W=12): Q12.3
  Bit 15: Sign
  Bits 14-12: Integer (3 bits, range ±4)
  Bits 11-0: Fraction (12 bits, resolution 2⁻¹² ≈ 0.000244)

Range: ±(2^(WIDTH-FRACT_W-1) - 2^(-FRACT_W))
       = ±(2^3 - 2^-12) ≈ ±7.9998
```

### 2.2 CORDIC Rotation Equations (Per Stage i)

```
x_{i+1} = x_i - σ_i × (y_i >> i)
y_{i+1} = y_i + σ_i × (x_i >> i)
z_{i+1} = z_i - σ_i × atan(2⁻ⁱ)

where σ_i = sign(z_i)  (1 if z_i ≥ 0, -1 if z_i < 0)
```

### 2.3 K-Factor Prescaling (Input Stage)

```
K = Π cos(atan(2⁻ⁱ)) for i=0..ITERATIONS-1 ≈ 0.607252935

x_0 = K × x_in
y_0 = K × y_in
z_0 = z_in
```

Implemented via 16-entry LUT in `cordic_lut`: input `x_in[15:12]` (4 MSBs) → prescaled `x_0`.

---

## 3. Pipeline Organization

| Stage | Function | Registers | Latency |
|-------|----------|-----------|---------|
| **Input** | K-prescale LUT, input register | `x_reg`, `y_reg`, `z_reg`, `valid_reg` | 1 cycle |
| **Stage 0..N-1** | CORDIC iteration i | `x_reg`, `y_reg`, `z_reg`, `valid_reg` | N cycles |
| **Output** | Output register | `x_out`, `y_out`, `z_out`, `valid_out` | 1 cycle |

**Total Pipeline Depth = ITERATIONS + 2 cycles**

### 3.1 Stage Internals (`cordic_stage`)

```
                    ┌──────────────┐
     x_in ──────────►│              │
                     │  Fixed Shift │──► (x_i >> stage_idx)  [combinational, hardwired]
     y_in ──────────►│  (by i bits) │
                     │              │
                    └──────┬───────┘
                           │
                    ┌──────┴──────┐
                    │  2:1 MUX    │──► ±shifted_value  (σ_i = sign(z_in[MSB]))
                    └──────┬──────┘
                           │
          ┌────────────────┼────────────────┐
          ▼                ▼                ▼
     ┌─────────┐      ┌─────────┐      ┌─────────┐
     │fp_add_sub│     │fp_add_sub│     │fp_add_sub│
     │  (x)    │      │  (y)    │      │  (z)    │
     └────┬────┘      └────┬────┘      └────┬────┘
          │                │                │
          ▼                ▼                ▼
       x_out            y_out            z_out
```

**Per-Stage Critical Path:** `Fixed Shift (wire) → MUX → fp_add_sub`

---

## 4. Stage-by-Stage Operation

| Cycle | Stage | Operation | Valid Signal |
|-------|-------|-----------|--------------|
| 0 | Input | Capture `x_in, y_in, z_in`; apply K-prescale LUT | `valid_in` |
| 1 | Stage 0 | Shift by 0, σ₀ = sign(z), x/y/z update | `valid_reg[0]` |
| 2 | Stage 1 | Shift by 1, σ₁ = sign(z), x/y/z update | `valid_reg[1]` |
| ... | ... | ... | ... |
| N | Stage N-1 | Shift by N-1, σ = sign(z), x/y/z update | `valid_reg[N-1]` |
| N+1 | Output | Register outputs | `valid_out` |

---

## 5. Register Placement

| Register | Location | Purpose |
|----------|----------|---------|
| `x_in_reg, y_in_reg, z_in_reg` | `cordic_pipeline` input | Capture input, break timing from source |
| `valid_in_reg` | `cordic_pipeline` input | Pipeline valid shifting |
| `x_stage[i], y_stage[i], z_stage[i]` | `cordic_stage` output | Per-stage pipeline registers |
| `valid_stage[i]` | `cordic_pipeline` | Valid pipeline (shift register) |
| `x_out_reg, y_out_reg, z_out_reg` | `cordic_pipeline` output | Clean output timing |
| `valid_out_reg` | `cordic_pipeline` output | Output valid |
| `config_reg` | `cordic_top` | Hold configuration |

**No registers inside `cordic_stage` or `cordic_lut`** — purely combinational.

---

## 6. Control Logic

### 6.1 Pipeline Control (Valid Shifting)

```systemverilog
// In cordic_pipeline
logic [ITERATIONS:0] valid_pipe;  // ITERATIONS+1 stages + output

always_ff @(posedge clk) begin
  if (!rst_n) begin
    valid_pipe <= '0;
  end else begin
    // Shift valid pipeline
    valid_pipe <= {valid_pipe[ITERATIONS-1:0], valid_in & ready_out};
    
    // Backpressure: ready_out = !valid_pipe[ITERATIONS-1] | ready_in
    // (stall if output stage full and downstream not ready)
  end
end
```

**Backpressure Protocol:**
- `ready_out` asserted when pipeline can accept new data
- `ready_in` from downstream allows output stage to advance
- If `!ready_in` and output stage valid → pipeline stalls, `ready_out` deasserts after 1 cycle

### 6.2 Configuration Handshake

```
config_valid ──────┐
                   ├──► config_reg (1-cycle capture)
config_ready ◄─────┘   (asserted when config_reg not pending)
```

- Configuration captured in 1 cycle
- `config_ready` = 1 when no pending config update
- Configuration applies to next input vector (not retroactive)

---

## 7. Critical Path Analysis

### 7.1 Critical Path (Per Stage)

```
fixed_shift (wire, 0 delay)
    │
    ▼
2:1 MUX (σ_i select) ──────────────┐
    │                              │
    ▼                              ▼
fp_add_sub (carry-select) ◄────────┘
    │
    ▼
Stage Register
```

**Estimated Delay (16-bit, typical 28nm):**
| Component | Delay |
|-----------|-------|
| Fixed shift (wire) | ~0 ps |
| 2:1 MUX | ~30 ps |
| fp_add_sub (carry-select, 16-bit) | ~350 ps |
| Register setup + clock skew | ~100 ps |
| **Total per stage** | **~480 ps** |

**Pipeline Frequency Target:** ~2 GHz (theoretical) → **Realistic post-P&R: 100-300 MHz**

### 7.2 Critical Path Optimizations (V1)

1. **Fixed shift per stage** — eliminates barrel shifter (~200 ps savings)
2. **Carry-select adder** — 2× faster than ripple-carry
3. **No mode MUX in datapath** — rotation-only removes 2:1 MUX on z-path
4. **Combinational LUT** — 0-cycle angle fetch

---

## 8. Parameterization

| Parameter | Default | Range | Scope |
|-----------|---------|-------|-------|
| `WIDTH` | 16 | 8, 16, 24, 32 | All modules |
| `FRACT_W` | 12 | 4..WIDTH-2 | All modules |
| `ITERATIONS` | 8 | 1..16 | `cordic_pipeline`, `cordic_lut`, `cordic_stage` |
| `K_FACTOR` | 0.60725... | Computed | `cordic_pkg`, `cordic_lut` |

**Parameter Propagation:**
```systemverilog
// In cordic_pipeline
cordic_stage #(
  .WIDTH(WIDTH),
  .FRACT_W(FRACT_W)
) stage_i (
  ...
);

// In cordic_lut
cordic_lut #(
  .WIDTH(WIDTH),
  .FRACT_W(FRACT_W),
  .ITERATIONS(ITERATIONS)
) lut_inst ( ... );
```

---

## 9. Clocking Strategy

| Domain | Clock | Reset | Modules |
|--------|-------|-------|---------|
| `clk` | Single global clock | `rst_n` (active-low, synchronous) | All RTL |

- **No clock gating in V1** (added via UPF in synthesis)
- **No CDC** — single clock domain
- **Clock uncertainty:** 10% period (conservative for STA)

---

## 10. Reset Strategy

| Signal | Type | Scope | Behavior |
|--------|------|-------|----------|
| `rst_n` | Active-low, synchronous | Global | All registers reset in 1 cycle |
| Pipeline valid | Synchronous | `cordic_pipeline` | Clears valid shift register |
| Config register | Synchronous | `cordic_top` | Resets to default config |

**No asynchronous resets in datapath.** All flops use:
```systemverilog
always_ff @(posedge clk) begin
  if (!rst_n) reg <= '0;
  else reg <= next;
end
```

---

## 11. Module Interactions

| Producer | Consumer | Interface | Protocol |
|----------|----------|-----------|----------|
| `cordic_top` (input) | `cordic_pipeline` | `cordic_in_t` + valid/ready | Valid/ready |
| `cordic_pipeline` | `cordic_stage[0]` | `x,y,z` + `stage_idx=0` | Direct (combinational LUT) |
| `cordic_stage[i]` | `cordic_stage[i+1]` | `x,y,z` + `stage_idx=i+1` | Registered |
| `cordic_lut` | `cordic_stage[i]` | `angle`, `k_prescale` | Combinational |
| `cordic_pipeline` | `cordic_top` (output) | `cordic_out_t` + valid/ready | Valid/ready |

---

## 12. Signal Flow Summary

```
Input:  (x_in, y_in, z_in) ──► [K-prescale LUT] ──► Stage 0 ──► Stage 1 ──► ... ──► Stage N-1 ──► Output Reg ──► (x_out, y_out, z_out)
            │                                                                                       │
            │                                                                                       │
            └───────────────────────── valid_pipe ──────────────────────────────────────────────────┘
                           (shifts each cycle, length = ITERATIONS+2)
```

---

**End of MICROARCHITECTURE.md**  
*This document defines the canonical microarchitecture. RTL implementation must match this specification exactly.*