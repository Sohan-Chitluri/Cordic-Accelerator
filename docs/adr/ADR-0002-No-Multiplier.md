# ADR-0002: No General-Purpose Multiplier in V1

**Status:** ACCEPTED  
**Date:** 2026-07-22  
**Authors:** Principal ASIC Architect, Technical Lead  

---

## Context

The initial tracker included a Booth-encoded shift-add multiplier (`shift_add_mul.sv`) for:
1. K-factor gain compensation at pipeline output
2. Potential future hyperbolic/vectoring modes

Architecture review determined classical CORDIC rotation mode requires **zero multiplications** — only shifts and adds.

## Decision

**No multiplier in V1.** Gain compensation handled via LUT prescaling (ADR-0005). Multiplier deferred to V2.1 for runtime K-factor and hyperbolic mode.

## Alternatives Considered

| Alternative | Pros | Cons | Verdict |
|-------------|------|------|---------|
| **Include Booth multiplier** | Future-proof; exact K-factor | +2 cycles latency; 3× area; formal burden | ❌ Rejected |
| **Include ripple multiplier** | Simpler than Booth | Still +2 cycles; area; unused in V1 | ❌ Rejected |
| **LUT prescaling** | 0 cycles; zero multiplier; bit-exact for fixed N | Approximate (4 MSB indexing) | ✅ **Accepted** |
| **Defer entirely to V2** | Simplest V1 | Requires V2 for any gain compensation | ❌ Rejected |

## Technical Analysis

**Classical CORDIC Rotation Equations:**
```
x_{i+1} = x_i - σ_i × (y_i >> i)
y_{i+1} = y_i + σ_i × (x_i >> i)
z_{i+1} = z_i - σ_i × atan(2⁻ⁱ)
```

**No multiplication operations.** Only:
- Arithmetic right shift (by constant `i` per stage)
- Conditional add/subtract (σ_i = ±1)
- Angle lookup (constant per stage)

**K-factor gain:** K = Π cos(atan(2⁻ⁱ)) ≈ 0.60725
- Applied **once** at input (prescale) or output (post-scale)
- V1: LUT prescale at input (ADR-0005)

## Consequences

### Positive
- **Zero multiplier RTL** in V1
- **Critical path shortened** by ~1.2 ns (no multiplier)
- **Area reduced** ~30% (multiplier ~3× adder area)
- **Formal verification simpler** (no multiplier properties)

### Negative
- **K-factor approximate** (LUT indexing by 4 MSBs → ~0.6% max error)
- **V2.1 requires multiplier** for exact gain and hyperbolic mode

## Verification Impact

| Test | V1 (No Multiplier) | V2.1 (With Multiplier) |
|------|-------------------|------------------------|
| K-factor accuracy | LUT vs golden (<0.6%) | Exact multiply vs golden |
| Multiplier tests | None | Booth encoding, corners, overflow |
| Formal | Adder properties only | Multiplier equivalence |

## Future Work (V2.1)

```systemverilog
// V2.1: Runtime K-factor multiplication
module gain_compensator #(
  parameter int WIDTH = 16
) (
  input  logic signed [WIDTH-1:0] x_in,
  input  logic signed [WIDTH-1:0] y_in,
  output logic signed [WIDTH-1:0] x_out,
  output logic signed [WIDTH-1:0] y_out,
  input  logic                    valid_in,
  output logic                    valid_out
);
  // Uses shift_add_mul with K_FIXED constant
  // 2-cycle latency, bit-exact
endmodule
```

---

**Sign-off:** Principal Architect ✅ | Technical Lead ✅