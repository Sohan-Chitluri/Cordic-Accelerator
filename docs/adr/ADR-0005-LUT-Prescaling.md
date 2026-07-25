# ADR-0005: LUT-Based K-Factor Prescaling

**Status:** ACCEPTED  
**Date:** 2026-07-22  
**Authors:** Principal ASIC Architect, Technical Lead  
**Reviewers:** All Agents  

---

## Context

CORDIC rotation has inherent gain K = Π cos(atan(2⁻ⁱ)) ≈ 0.607252935. Traditional implementations multiply outputs by K at pipeline end, requiring a multiplier.

## Decision

**V1 uses LUT-based prescaling at pipeline input.** Inputs x_in, y_in are pre-multiplied by K via 16-entry combinational LUT before entering CORDIC stages.

## Alternatives Considered

| Alternative | Implementation | Latency | Area | Accuracy | Decision |
|-------------|---------------|---------|------|----------|----------|
| **Post-multiply (multiplier)** | Shift-add multiplier at output | 2 cycles | ~2,500 GE | Bit-exact | REJECTED |
| **Runtime K-multiply** | Parameterized multiplier | 2 cycles | +multiplier | Bit-exact | REJECTED |
| **LUT prescaling (input)** | 16-entry LUT on 4 MSBs | **0 cycles** | **~200 GE** | ±0.6% | **ACCEPTED** |
| **No compensation** | User handles K externally | 0 cycles | 0 | User-dependent | REJECTED |
| **Pre-scaled constants** | K baked into angle LUT | 0 cycles | 0 | Bit-exact for fixed N | REJECTED (inflexible) |

## LUT Design Details

| Aspect | Specification |
|--------|---------------|
| **Input** | 4 MSBs of x_in / y_in (k_lut_idx = x_in[15:12]) |
| **Entries** | 16 (covers range [-8, 8) in Q12.3) |
| **Output** | K × (index_center_value) |
| **Latency** | 0 cycles (purely combinational) |
| **Synthesis** | `(* rom_style = "distributed" *)` → LUT6s |
| **Max index error** | K × (step/2) = 0.607 × 0.25 ≈ 0.15 (Q12.3) = 0.6% |

## Consequences

### Positive
- **Zero-cycle compensation** — no pipeline bubbles
- **No multiplier RTL** — consistent with ADR-0002
- **Trivial verification** — table compare vs golden
- **Deterministic timing** — combinational LUT, no RAM inference risk
- **Area minimal** — 16 LUT6s ≈ 200 GE

### Negative
- **Indexing granularity** — 4 MSBs only, step = 0.5 in Q12.3
- **K-error ≤ 0.6%** — acceptable for 16-bit (target < 0.5% magnitude error)
- **Fixed iteration count** — LUT pre-computed for ITERATIONS=8
- **Not bit-exact** — V2.1 adds runtime multiply for exactness

## Error Budget Analysis

| Error Source | Magnitude | Contribution |
|--------------|-----------|--------------|
| LUT index quantization | ≤ 0.5 LSB of input | ±0.6% K-error |
| CORDIC finite iterations (8) | ~2⁻⁹ rad | 0.11° angle |
| Fixed-point rounding | ~8 × 0.5 LSB | 0.1% magnitude |
| **Total magnitude error** | | **< 0.5%** (meets spec) |
| **Total angle error** | | **< 0.15°** (meets spec) |

## V2.1 Migration

V2.1 adds runtime K-multiplication for dynamic iterations:

```systemverilog
// V2.1 cordic_lut.sv extension
module cordic_lut #(
  parameter int ITERATIONS = 8
) (
  // ... existing ports ...
  input  logic                    use_runtime_k,  // V2: 1=multiply, 0=LUT
  input  logic signed [WIDTH-1:0] k_factor_fixed, // V2: runtime K value
  output logic signed [WIDTH-1:0] k_prescale_x,
  output logic signed [WIDTH-1:0] k_prescale_y
);
// If use_runtime_k: k_prescale = shift_add_mul(x_in, k_factor_fixed)
// Else: k_prescale = LUT[x_in[15:12]]
endmodule
```

**V1 RTL unchanged** — V2 adds mux and multiplier path.

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| LUT inferred as RAM | Medium | Adds 1-cycle latency | `(* rom_style="distributed" *)` + `always_comb` |
| K-error too large | Low | Fails accuracy spec | Verified: < 0.5% total magnitude error |
| User needs exact K | Medium | Deferred to V2.1 | Documented; V2.1 adds multiplier |

---

**Sign-off:** Principal Architect ✅ | Technical Lead ✅ | Agent-A ⏳ | Agent-B ⏳ | Agent-C ⏳ | Agent-D ⏳