# CORDIC Accelerator — V2 Parameterization Analysis

**Project:** Parameterized Fixed-Point Pipelined CORDIC Accelerator  
**Document Version:** 1.0  
**Status:** ANALYSIS ONLY — Do not implement  
**Derived From:** V1 RTL (frozen), `SPECIFICATION.md`, `MICROARCHITECTURE.md`

---

## 1. Scope

This document analyzes the feasibility of extending the V1 CORDIC accelerator to support multiple precision configurations (8/16/32-bit) and flexible pipeline staging for a future V2 release.

**V1 Baseline (Frozen):**
- `DATA_WIDTH` = 16
- `FRACTION_WIDTH` = 12
- `ITERATIONS` = 8
- `PIPELINE_STAGES` = `ITERATIONS` = 8 (1:1 mapping)
- Rotation mode only
- Shift-add K prescaling (Q12.3 constants)
- Single clock domain, synchronous reset

---

## 2. Parameter Definitions

| Parameter | V1 Value | V2 Range | Notes |
|-----------|----------|----------|-------|
| `DATA_WIDTH` | 16 | 8, 16, 32 | Total bit width including sign |
| `FRACTION_WIDTH` | 12 | 4..`DATA_WIDTH`-2 | Fractional bits; integer bits = `DATA_WIDTH` - `FRACTION_WIDTH` - 1 |
| `ANGLE_WIDTH` | = `DATA_WIDTH` | `FRACTION_WIDTH`..`DATA_WIDTH` | May differ for high-precision angle |
| `ITERATIONS` | 8 | 1..`ANGLE_WIDTH`-1 | CORDIC iterations; ≤ `ANGLE_WIDTH` for convergence |
| `PIPELINE_STAGES` | = `ITERATIONS` | 1..`ITERATIONS` | Stages in pipeline; ≤ `ITERATIONS` |

---

## 3. Critical Distinction: ITERATIONS vs PIPELINE_STAGES

### V1 Architecture (Current)
```
ITERATIONS = 8
PIPELINE_STAGES = 8
Stage 0: iter 0
Stage 1: iter 1
...
Stage 7: iter 7
Latency = 10 cycles (input + 8 stages + output)
```

### V2 Architecture (Proposed)
```
ITERATIONS = 8
PIPELINE_STAGES = 3

Stage 0: iter 0,1,2  (combinational chain of 3 iterations)
Stage 1: iter 3,4,5
Stage 2: iter 6,7
Latency = 5 cycles (input + 3 stages + output)
```

### Tradeoff Analysis

| Metric | V1 (8 stages) | V2 (3 stages) | Impact |
|--------|---------------|---------------|--------|
| **Latency** | 10 cycles | 5 cycles | **Better** — lower latency |
| **Throughput** | 1/cycle | 1/cycle | **Same** — still 1 vector/cycle |
| **Register Count** | 48 FFs | ~18 FFs | **Better** — fewer registers |
| **Critical Path** | ~1.5 ns | ~3-4 ns | **Worse** — longer combinational chain |
| **Fmax** | ~400 MHz | ~200 MHz | **Worse** — may not meet 100 MHz easily |
| **Area** | ~12k gates | ~10k gates | **Better** — fewer pipeline registers |
| **Valid Pipeline** | 10-deep | 5-deep | **Simpler** |

---

## 4. Parameter Legality Rules

| Rule | Rationale |
|------|-----------|
| `ITERATIONS` ≤ `ANGLE_WIDTH` - 1 | CORDIC convergence requires enough angle bits |
| `FRACTION_WIDTH` ≥ 4 | Minimum fractional precision for K-factor |
| `PIPELINE_STAGES` ≤ `ITERATIONS` | Cannot have more stages than iterations |
| `PIPELINE_STAGES` ≥ 1 | At least 1 stage required |
| `DATA_WIDTH` ∈ {8, 16, 32} | Recommended; 4-bit dropped (see §9) |

---

## 5. Impact on Key Components

### 5.1 `cordic_pkg.sv` — Constants & Types

**Current (V1):**
```systemverilog
parameter int WIDTH = 16;
parameter int FRACT_W = 12;
parameter int ITERATIONS = 8;
localparam fixed_t K_FACTOR = 16'sd2488;  // Hardcoded Q12
```

**V2 Required:**
```systemverilog
parameter int DATA_WIDTH = 16;
parameter int FRACTION_WIDTH = 12;
parameter int ANGLE_WIDTH = 16;
parameter int ITERATIONS = 8;
parameter int PIPELINE_STAGES = 8;  // Default = ITERATIONS (V1 compat)

// K-factor: computed at elaboration
function automatic real k_factor(input int iterations);
    real k = 1.0;
    for (int i = 0; i < iterations; i++) 
        k *= cos(atan(2.0**(-i)));
    return k;
endfunction

localparam real K_FACTOR_REAL = k_factor(ITERATIONS);
localparam fixed_t K_FACTOR = real_to_fixed(K_FACTOR_REAL);

// atan LUT: generated at elaboration
function automatic fixed_t atan_fixed(input int i);
    return real_to_fixed(atan(2.0**(-i)));
endfunction

fixed_t ATAN_LUT [0:ITERATIONS-1];
// Fill at elaboration
```

### 5.2 `cordic_lut.sv` — K-Prescale & Angle LUT

**V1:** Hardcoded 8-entry angle LUT + 16-entry K-prescale (4 MSBs)  
**V2:** 
- `ITERATIONS`-entry angle LUT (parameterized)
- Full-precision K-prescale (shift-add constant multiply by computed `K_FACTOR`)
- No MSB LUT — full precision preserved

### 5.3 `cordic_stage.sv` — Single Iteration

**V1:** Hardwired `STAGE_IDX` per instance, shift amount = `STAGE_IDX`  
**V2:** Parameterized `STAGE_IDX`, shift amount = `STAGE_IDX` (still hardwired per instance)

```systemverilog
module cordic_stage #(
    parameter int DATA_WIDTH = 16,
    parameter int FRACT_W = 12,
    parameter int STAGE_IDX = 0,
    parameter fixed_t STAGE_ANGLE = 0
) (...);
```

### 5.4 `cordic_pipeline.sv` — N-Stage Pipeline

**V1:** `generate` loop instantiating `ITERATIONS` stages  
**V2:** Need iteration-to-stage mapping:

```systemverilog
localparam int ITER_PER_STAGE = ITERATIONS / PIPELINE_STAGES;
localparam int REM_ITER = ITERATIONS % PIPELINE_STAGES;

generate
    for (genvar s = 0; s < PIPELINE_STAGES; s++) begin : g_stages
        localparam int iter_start = s * ITER_PER_STAGE + (s < REM_ITER ? s : REM_ITER);
        localparam int iter_end = iter_start + ITER_PER_STAGE + (s < REM_ITER ? 1 : 0) - 1;
        
        // Instantiate chain of (iter_end - iter_start + 1) cordic_stage
        // Or single multi-iteration stage module
    end
endgenerate
```

---

## 6. Arithmetic Width Analysis

### Shift-Add K Prescaling

**V1:** `K = 2488/4096` (Q12), implemented as:
```systemverilog
// v * 2488 = (v<<11) + (v<<9) - (v<<6) - (v<<3)
// k = (v*2488 + 2048) >>> 12
```

**V2:** General K depends on `ITERATIONS`:
```
K(ITERATIONS) = Π cos(atan(2⁻ⁱ)) for i=0..ITERATIONS-1

K(8)  ≈ 0.607252935 → 2488/4096 (Q12)
K(16) ≈ 0.607252935 → 2488/4096 (same for Q12, more bits for higher Q)
K(4)  ≈ 0.608833913 → different constant
```

**Implementation Options:**
1. **Elaboration-time constant:** Pre-compute K × 2^FRACTION_WIDTH, implement shift-add
2. **Runtime multiply:** Use multiplier (violates V1 multiplier-free goal)
3. **Shift-add approximation:** Always use fixed K(∞) ≈ 0.607252935, small error for N<∞

**Recommendation:** Option 1 — elaboration-time shift-add constant (multiplier-free, exact for given ITERATIONS/FRACT_W)

### 5.5 Arithmetic Extension Widths

| Operation | V1 Width | V2 General Formula |
|-----------|----------|-------------------|
| K-prescale accumulator | `WIDTH + FRACT_W + 2` | `DATA_WIDTH + FRACTION_WIDTH + 2` |
| Stage shift (sign-extend) | `WIDTH + 1` | `DATA_WIDTH + 1` |
| Adder inputs (sign-extend) | `WIDTH + 1` | `DATA_WIDTH + 1` |
| Adder result | `WIDTH + 1` | `DATA_WIDTH + 1` |
| Overflow detection | MSB vs MSB-1 | MSB vs MSB-1 |

---

## 7. K-Factor & atan LUT Generation

### K-Factor Elaboration Function

```systemverilog
function automatic fixed_t compute_k_factor(
    input int iterations,
    input int fract_w
);
    real k = 1.0;
    for (int i = 0; i < iterations; i++) begin
        k *= cos(atan(2.0**(-i)));
    end
    return real_to_fixed(k, fract_w);
endfunction
```

### atan LUT Elaboration Function

```systemverilog
function automatic fixed_t atan_fixed(
    input int i,
    input int fract_w
);
    return real_to_fixed(atan(2.0**(-i)), fract_w);
endfunction
```

**Generated Constants (Example for DATA_WIDTH=16, FRACT_W=12):**

| Iterations | K (real) | K (fixed) | Shift-Add Constant |
|------------|----------|-----------|---------------------|
| 4 | 0.6088339 | 2494 | (v<<11)+(v<<9)-(v<<6)-(v<<3)+... |
| 8 | 0.6072529 | 2488 | 2488 = 2¹¹+2⁹-2⁶-2³ |
| 16 | 0.6072529 | 2488 | Same (converged) |
| 32 | 0.6072529 | 2488 | Same |

---

## 8. Pipeline Latency & Throughput

| Configuration | ITERATIONS | PIPELINE_STAGES | Latency (cycles) | Throughput |
|---------------|------------|-----------------|------------------|------------|
| V1 (baseline) | 8 | 8 | 10 | 1/cycle |
| V2 Option A | 8 | 4 | 6 | 1/cycle |
| V2 Option B | 8 | 3 | 5 | 1/cycle |
| V2 Option C | 16 | 8 | 18 | 1/cycle |
| V2 Option D | 16 | 4 | 6 | 1/cycle |

**Latency Formula:** `PIPELINE_STAGES + 2` (input reg + stages + output reg)  
**Throughput:** Always 1 vector/cycle after pipeline fill

---

## 9. 4-bit Analysis: RECOMMEND DROP

| Issue | 4-bit Impact |
|-------|--------------|
| **Signed range** | ±8 (3 integer bits) — too small for CORDIC |
| **Fractional precision** | 1-2 bits — K-factor ≈ 0.5 or 1.0, huge error |
| **Angle representation** | atan(1) = π/4 ≈ 0.785 → 12 in Q1.2 (large quantization) |
| **Convergence** | ITERATIONS max = 2-3 — no meaningful convergence |
| **Saturation** | Triggers constantly — no useful dynamic range |
| **Numerical usefulness** | None — cannot represent meaningful trigonometric values |

**Conclusion:** 4-bit provides **no meaningful numerical accuracy** for CORDIC. Drop from V2.

---

## 10. Recommended V2 Precisions

| Precision | DATA_WIDTH | FRACTION_WIDTH | ITERATIONS (default) | Use Case |
|-----------|------------|----------------|---------------------|----------|
| **8-bit** | 8 | 5 | 4 | Ultra-low area, coarse trig |
| **16-bit** | 16 | 12 | 8 | **V1 baseline** — balanced |
| **32-bit** | 32 | 24 | 16 | High precision, robotics |

---

## 11. Architectural Change Summary

| Component | V1 | V2 | Change Type |
|-----------|----|----|-------------|
| `cordic_pkg` | Hardcoded constants | Elaboration-time generation | **Moderate** |
| `cordic_lut` | 4-MSB K-LUT + 8-entry angle | Full-precision K + parameterized angle | **Moderate** |
| `cordic_stage` | Hardwired per instance | Parameterized per instance | **Minor** |
| `cordic_pipeline` | 1 iter/stage generate | Iteration-to-stage mapping | **Moderate** |
| `cordic_top` | Pass-through | Parameter passing | **Minor** |
| `cordic_assertions` | V1-specific | Parameterized | **Minor** |
| `fp_add_sub` | Unchanged | Unchanged | **None** |

---

## 12. Current V1 vs Future V2 Compatibility

| V1 Feature | V2 Status |
|------------|-----------|
| `WIDTH` parameter | → `DATA_WIDTH` (rename) |
| `FRACT_W` parameter | → `FRACTION_WIDTH` (rename) |
| `ITERATIONS` parameter | Kept |
| `PIPELINE_STAGES` parameter | **New** (default = `ITERATIONS`) |
| `ANGLE_WIDTH` parameter | **New** (default = `DATA_WIDTH`) |
| `K_FACTOR` constant | → computed at elaboration |
| `ATAN_LUT` array | → generated at elaboration |
| 1 iter/stage pipeline | **Optional** (default for V1 compat) |

---

## 13. Open Questions for V2 Implementation

1. **Multi-iteration stage module:** Create `cordic_multi_stage` or chain `cordic_stage`?
2. **K-factor accuracy:** Use exact K(ITERATIONS) or K(∞) approximation?
3. **Angle LUT storage:** Distributed ROM (combinational) vs block RAM?
4. **Formal verification:** Re-prove P4–P7 for parameterized widths?
4. **Test coverage:** Update test vectors for all precision targets?

---

## 14. Conclusion

The V1 architecture **naturally supports** parameterization of `DATA_WIDTH`, `FRACTION_WIDTH`, `ITERATIONS` via existing elaboration-time parameters. 

**Decoupling `PIPELINE_STAGES` from `ITERATIONS` requires moderate RTL changes** in `cordic_pipeline` (iteration-to-stage mapping) and `cordic_stage` (parameterization).

**4-bit should be dropped** — no meaningful CORDIC convergence possible.

**V2 implementation should not begin until V1 Gate 4 is complete** (STA + coverage + DRC/LVS).

---

**End of V2 Parameterization Analysis**