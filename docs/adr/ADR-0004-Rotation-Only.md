# ADR-0004: Rotation Mode Only in V1

**Status:** ACCEPTED  
**Date:** 2026-07-22  
**Authors:** Principal ASIC Architect, Technical Lead  
**Reviewers:** All Agents  

---

## Context

Classical CORDIC supports three modes:
1. **Rotation** — circular, compute sin/cos, rotate vector
2. **Vectoring** — circular, compute atan2, magnitude
3. **Hyperbolic** — sinh/cosh, sqrt, ln, exp (requires repeated iterations)

Initial tracker included all three modes in `cordic_stage` with mode MUX.

## Decision

**V1 implements Rotation Mode Only.** Vectoring and Hyperbolic deferred to V2.0.

## Alternatives Considered

| Alternative | Implementation Impact | Critical Path | Verification | Decision |
|-------------|----------------------|---------------|--------------|----------|
| **All 3 modes in V1** | Mode MUX in every stage, hyperbolic repeat logic | +2:1 MUX per stage | 3× test matrices | REJECTED |
| **Rotation + Vectoring** | Direction MUX on z-path only | +1 MUX | 2× tests | REJECTED |
| **Rotation only** | No mode MUX, fixed σ = sign(z) | **Baseline** | **Single test matrix** | **ACCEPTED** |

## Consequences

### Positive
- **Critical path simplified** — no mode MUX in x/y/z datapath
- **Single convergence behavior** — rotation always converges for |z| < π/2
- **Simpler formal** — x²+y² invariant only for rotation
- **No hyperbolic repeat logic** — iterations 4,13 (1-indexed) not needed
- **Smaller LUT** — only atan, not atanh

### Negative
- **No atan2/sqrt in V1** — core robotics primitives deferred
- **No sinh/cosh/ln/exp** — hyperbolic functions deferred
- **User must know mode limitation** — documented in spec

## Quantitative Impact

| Metric | All 3 Modes | Rotation Only | Savings |
|--------|-------------|---------------|---------|
| Stage MUXes | 3 per stage (x,y,z) | 0 | 24 MUXes (8 stages) |
| LUT entries | atan + atanh (16) | atan only (8) | 50% LUT size |
| Verification vectors | 3 mode × 10k | 1 mode × 10k | 66% reduction |
| Formal properties | 3 invariants | 1 invariant | 66% reduction |
| RTL lines (est.) | ~1,500 | ~980 | 35% reduction |

## V2.0 Migration

V2.0 adds modes with minimal V1 impact:

```systemverilog
// cordic_pkg.sv extension (V2)
typedef enum logic [1:0] {
  CORDIC_ROTATE     = 2'b00,  // V1
  CORDIC_VECTOR     = 2'b01,  // V2.0
  CORDIC_HYPERBOLIC = 2'b10   // V2.0
} cordic_mode_e;

// cordic_stage.sv changes (V2)
input cordic_mode_e mode;
// σ_i = (mode == VECTOR) ? -sign(y) : sign(z)
// z update: (mode == VECTOR) ? z + σ×atan : z - σ×atan
// Hyperbolic: repeat iterations 4,13 (1-indexed)
```

**V1 RTL unchanged** — V2 wraps or extends modules.

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| User needs vectoring | High | Medium | Documented limitation; V2.0 prioritized |
| Hyperbolic required | Low | Low | Not in 1-semester scope |
| Scope creep | High | High | **Frozen at Gate 0** — no mode MUX added |

---

**Sign-off:** Principal Architect ✅ | Technical Lead ✅ | Agent-A ⏳ | Agent-B ⏳ | Agent-C ⏳ | Agent-D ⏳