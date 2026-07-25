# ADR-0001: V1 Scope Definition

**Status:** ACCEPTED  
**Date:** 2026-07-22  
**Authors:** Principal ASIC Architect, Technical Lead  
**Reviewers:** All Agents  

---

## Context

The initial implementation tracker proposed 17 RTL modules with 5 integration waves. Architecture review identified significant scope reduction opportunities to maximize RTL→GDSII completion probability within one semester.

## Decision

**V1 scope frozen to 9 RTL modules, 4 waves, 5-week timeline.** All other features explicitly deferred to V2+.

## V1 Scope (INCLUDED)

| Module | File | Owner | Purpose |
|--------|------|-------|---------|
| Package | `rtl/pkg/cordic_pkg.sv` | Lead | Types, constants, functions |
| Assertions | `rtl/common/cordic_assertions.sv` | Lead | Bindable SVA |
| Adder/Sub | `rtl/fp_add_sub.sv` | Agent-A | Saturating adder/subtractor |
| LUT | `rtl/cordic_lut.sv` | Agent-B | atan(2⁻ⁱ) + K-prescale |
| Stage | `rtl/cordic_stage.sv` | Agent-C | Single CORDIC iteration |
| Pipeline | `rtl/cordic_pipeline.sv` | Agent-D | N-stage pipeline |
| Top | `rtl/cordic_top.sv` | Lead | Integration, I/O, config |
| Constraints | `constraints/cordic.sdc` | Lead | Timing constraints |
| Testbench | `tb/cordic_tb.sv` + golden | Lead | Regression suite |

**Total RTL: ~980 lines**

## V1 Explicitly EXCLUDED (Deferred)

| Feature | Module | Deferred To | ADR |
|---------|--------|-------------|-----|
| General multiplier | `shift_add_mul.sv` | V2.1 | ADR-0002 |
| Vectoring mode | `cordic_stage` mode MUX | V2.0 | ADR-0004 |
| Hyperbolic mode | Repeat iterations, atanh LUT | V2.0 | ADR-0004 |
| AXI-Lite config | `cordic_regfile.sv` | V2.2 | ADR-0003 |
| AXI-Stream data | `cordic_top` ports | V2.2 | ADR-0003 |
| Runtime K-multiply | `cordic_lut` multiplier path | V2.1 | ADR-0005 |
| Dynamic iterations | Pipeline enable mask | V2.0 | — |
| Matrix/vector ops | New modules | V2.3 | — |
| Coordinate transforms | New modules | V2.4 | — |
| Inverse kinematics | New modules | V2.4 | — |

## Scope Freeze Policy

- **Gate 0 (Week 1):** All interfaces frozen in `cordic_pkg.sv` and `INTERFACE_SPECIFICATION.md`
- **No scope additions** after Gate 0 without formal ADR
- **Scope reductions** allowed at any gate (simplification only)
- **V2 features** documented in roadmap but **zero RTL written** in V1

## Rationale

| Factor | Initial Plan | V1 Plan | Improvement |
|--------|--------------|---------|-------------|
| RTL modules | 17 | 9 | -47% |
| Integration waves | 5 | 4 | -20% |
| Parallel agents | 4 | 3 | Focused |
| Critical path | Multiplier + CORDIC | CORDIC only | Simplified |
| Verification burden | 3 modes × protocols | 1 mode × simple | -70% |
| GDSII probability | Medium | **High** | Scope fit |

## Consequences

### Positive
- **Achievable in 5 weeks** with 3 agents + Lead
- **Single critical path** (CORDIC stages only)
- **No protocol compliance risk** (no AXI)
- **Formal verification tractable** (1 invariant)
- **Clean V2 extension points** (all interfaces parameterized)

### Negative
- **Limited functionality** (rotation only)
- **Approximate K-factor** (LUT, not exact)
- **Non-standard interfaces** (requires V2.2 adapters)
- **No dynamic reconfiguration** (fixed iterations)

## Risk Mitigation

| Risk | Mitigation |
|------|------------|
| Stakeholder expects more | V2 roadmap documented; demo shows sin/cos generation |
| Accuracy insufficient | Error budget verified: <0.15° angle, <0.5% magnitude |
| Timeline slips | 1-week buffer in Week 5; Lead absorbs Wave 2-3 delays |

---

**Sign-off:** Principal Architect ✅ | Technical Lead ✅ | Agent-A ⏳ | Agent-B ⏳ | Agent-C ⏳ | Agent-D ⏳