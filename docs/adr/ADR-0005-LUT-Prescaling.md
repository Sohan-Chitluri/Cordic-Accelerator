# ADR-0005: Shift-Add Constant K-Factor Prescaling

**Status:** SUPERSEDED (was: LUT-Based K-Factor Prescaling, ACCEPTED 2026-07-22)  
**Revised:** 2026-08-14  
**Authors:** Principal ASIC Architect, Technical Lead  

---

## Context

CORDIC rotation has inherent gain K = Π cos(atan(2⁻ⁱ)) ≈ 0.607252935 (8 iterations). Inputs must
be pre-multiplied by K before entering the CORDIC stage chain so that the output magnitude is correct.

The original design used a 16-entry LUT indexed by the 4 MSBs of the input
(`k_lut_idx = x_in[15:12]`). This was found to be architecturally incorrect: indexing only 4 MSBs
quantizes the input to 16 levels and **discards all 12 fractional bits**. The golden model's own
code flagged this as a "known design issue." The claimed ±0.6% error was for the LUT step size,
not the true precision loss (which destroys sub-integer information entirely).

## Decision

**V1 uses a shift-add constant multiplier for K-factor prescaling.** The correction factor is
K ≈ 2488/4096 (0.028% vs. true K), realized as:

```
v × 2488 = (v << 11) + (v << 9) − (v << 6) − (v << 3)
k        = round(v × 2488 / 4096) = (v × 2488 + 2048) >>> 12
```

This is purely combinational (0-cycle latency), requires no multiplier (4 shifts + 3 add/subs,
consistent with ADR-0002), and preserves full input precision.

## Alternatives Considered

| Alternative | Implementation | Area | Accuracy | Decision |
|-------------|----------------|------|----------|----------|
| **4-MSB LUT (original)** | 16-entry ROM on input[15:12] | ~200 GE | Destroys fractional bits | **REJECTED** |
| **Shift-add constant** | 4 shifts + 3 add/subs | ~150 GE | 0.028% vs. true K | **ACCEPTED** |
| **Post-multiply (multiplier)** | Shift-add multiplier at output | ~2,500 GE | Bit-exact | REJECTED (ADR-0002) |
| **No compensation** | User handles K externally | 0 | User-dependent | REJECTED |

## Implementation Details

| Aspect | Specification |
|--------|---------------|
| **K approximation** | 2488/4096 = 0.607421875 (0.028% vs. true K=0.607252935) |
| **CSD decomposition** | 2488 = 2¹¹ + 2⁹ − 2⁶ − 2³ |
| **Accumulator width** | WIDTH + FRACT_W + 2 = 30 bits (prevents intermediate overflow) |
| **Rounding** | Round-to-nearest: bias (+2048) added before arithmetic right shift |
| **Latency** | 0 cycles (purely combinational) |
| **Synthesis** | Adder tree, no RAM/ROM inference risk |
| **Input precision** | Full WIDTH-bit precision preserved (no quantization) |

```systemverilog
function automatic cordic_data_t k_prescale(input cordic_data_t v);
  logic signed [ACC_W-1:0] ext, acc;
  ext = ACC_W'(v);
  acc = (ext <<< 11) + (ext <<< 9) - (ext <<< 6) - (ext <<< 3);
  acc = acc + (1 <<< (FRACT_W-1));   // round-to-nearest
  acc = acc >>> FRACT_W;
  return cordic_data_t'(acc[WIDTH-1:0]);
endfunction
```

Golden model match: `k_prescale(v) = (v * 2488 + 2048) >> 12` (bit-exact, verified by
`cordic_lut_tb.sv` sweeping all 65,536 input values).

## Consequences

### Positive
- **Full input precision** — all 12 fractional bits preserved
- **No multiplier** — ADR-0002 preserved; synthesizes to adder tree
- **0-cycle latency** — purely combinational, fits pipeline input stage
- **Bit-exact with golden model** — RTL and Python reference agree on every value
- **Simpler interface** — ports `k_lut_idx_x/y [3:0]` removed; full-width `x_in/y_in` used directly
- **Verified** — full sweep by `cordic_lut_tb.sv`

### Negative
- **0.028% K-error** — acceptable per SPECIFICATION NFR-05 (< 0.5% magnitude error)
- **Adder depth ~4** — slightly deeper than LUT, but well within timing for target frequency

## Error Budget Analysis

| Error Source | Magnitude |
|--------------|-----------|
| K approximation (2488 vs. 2488.02…) | 0.028% |
| CORDIC 8-iteration truncation | ~2⁻⁹ rad ≈ 0.11° |
| Round-to-nearest (per stage) | ≤ 0.5 LSB |
| **Total magnitude error** | **< 0.1%** (well within spec) |

---

**Revision note:** Original 4-MSB LUT approach (ACCEPTED 2026-07-22) was found to destroy
fractional-bit precision. Replaced with shift-add constant multiplier (2026-08-14).
ADR-0002 (no multiplier in synthesized datapath) is preserved.
