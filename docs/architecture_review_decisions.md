# Architecture Review Decisions — CORDIC Accelerator V1

**Review Date:** 2026-07-22  
**Reviewer:** Principal ASIC Architect / Technical Lead  
**Status:** APPROVED — Execution Authorized

---

## Review Objectives

1. Maximize probability of RTL→GDSII completion in one semester
2. Minimize unnecessary RTL complexity
3. Preserve clean extensibility for Robotics Mathematics Accelerator (V2+)
4. Maintain industrial ASIC development workflow

---

## Decisions Summary

| # | Decision | Status | Rationale |
|---|----------|--------|-----------|
| 1 | **No general-purpose multiplier in V1** | APPROVED | Classical CORDIC rotation/vectoring uses shift-add only. Booth multiplier adds 2-cycle latency, ~3× area, formal verification burden for zero functional benefit in V1 modes. |
| 2 | **Gain compensation = LUT prescaling** | APPROVED | Pre-scale inputs by K-factor (0.60725...) via 16-entry LUT. Zero cycles, zero multiplier, bit-exact, trivially verifiable. Runtime K-factor multiplication → V2. |
| 3 | **No AXI-Lite register file in V1** | APPROVED | AXI-Lite compliance adds 50+ cycles of protocol verification risk. V1 uses simple `config_valid/ready` handshake with hardened registers. AXI-Lite → V2. |
| 4 | **Remove Fmax target (500 MHz)** | APPROVED | Student ASIC flows typically achieve 100-200 MHz post-P&R. Design for correct-by-construction timing; measure actual Fmax after synthesis. Target becomes "timing closure at reasonable frequency." |
| 5 | **Rotation mode only (V1)** | APPROVED | Vectoring mode adds mode MUX in critical path and hyperbolic iteration complexity. V1 = rotation (sin/cos generation). Vectoring + hyperbolic → V2. |
| 6 | **8 iterations default (16-bit)** | APPROVED | 16 iterations for 16-bit is overkill (convergence ~N/2). 8 iterations gives ~0.1° accuracy, halves pipeline depth and critical path. Parameterizable for V2. |
| 7 | **Angle ROM → Combinational LUT** | APPROVED | 16 entries × 16 bits = 256 bits. Distributed ROM synthesizes to LUTs with 0-cycle latency. Eliminates RAM inference risk, cycle latency, and address generation logic. |
| 8 | **Barrel shifter → Fixed shift per stage** | APPROVED | Each stage shifts by constant `i`. Hardwire shift amount per stage — eliminates barrel shifter from critical path. Stage = MUX + adder only. |
| 9 | **4 agents → 3 agents (V1)** | APPROVED | Reduced module count enables 3 parallel agents + Lead. Agent-D owns pipeline integration (was Agent-D + Agent-E). |
| 10 | **Single shared package (`cordic_pkg.sv`)** | APPROVED | Replaced 3 packages (`arithmetic_pkg`, `top_pkg`, `iterator_pkg`) with one. Single source of truth, no package dependency cycles, Lead-owned. |

---

## Rejected Proposals (from Initial Tracker)

| Proposal | Reason for Rejection |
|----------|---------------------|
| `shift_add_mul.sv` (Booth multiplier) | Not used by classical CORDIC rotation; gain compensation handled by LUT prescaling |
| `gain_compensator.sv` (multiplier-based) | Replaced by LUT prescaling in `cordic_lut.sv` |
| `cordic_regfile.sv` (AXI-Lite) | Protocol compliance risk; simple handshake sufficient for V1 config |
| `cordic_pipeline_ctrl.sv` (separate FSM) | Merged into `cordic_pipeline.sv` — pipeline control is trivial (valid shifting) |
| `cordic_top_pkg.sv` (separate package) | Merged into `cordic_pkg.sv` |
| `cordic_assertions.sv` (separate file) | Kept but moved to `rtl/common/` — bindable SVA module |

---

## V1 Module Inventory (9 files)

| File | Owner | Lines (est) | Dependencies |
|------|-------|-------------|--------------|
| `rtl/pkg/cordic_pkg.sv` | Lead | 120 | — |
| `rtl/common/cordic_assertions.sv` | Lead | 80 | `cordic_pkg` |
| `rtl/fp_add_sub.sv` | Agent-A | 180 | `cordic_pkg` |
| `rtl/cordic_lut.sv` | Agent-B | 80 | `cordic_pkg` |
| `rtl/cordic_stage.sv` | Agent-C | 150 | `cordic_pkg`, `fp_add_sub`, `cordic_lut` |
| `rtl/cordic_pipeline.sv` | Agent-D | 200 | All above |
| `rtl/cordic_top.sv` | Lead | 150 | `cordic_pipeline` |
| `constraints/cordic.sdc` | Lead | 50 | `cordic_top` |
| `tb/cordic_tb.sv` + golden_model.py | Lead | 300 | All |

**Total RTL: ~980 lines** — achievable in one semester with 3 agents + Lead.

---

## Dependency Graph (V1)

```
cordic_pkg.sv ◄──────────────────────────────────┐
       │                                        │
       ▼                                        │
┌──────────────┐    ┌──────────────┐            │
│ fp_add_sub   │    │ cordic_lut   │            │
└──────┬───────┘    └──────┬───────┘            │
       │                   │                    │
       ▼                   │                    │
┌──────────────────────────┘                    │
│           cordic_stage                         │
└──────────────┬────────────────────────────────┘
               │
               ▼
┌──────────────────────────┐
│     cordic_pipeline      │  (instantiates N×cordic_stage + cordic_lut)
└──────────────┬───────────┘
               │
               ▼
┌──────────────────────────┐
│        cordic_top        │  (pipeline + config handshake + I/O)
└──────────────────────────┘
```

**Critical Path:** `cordic_stage` (shift + mux + fp_add_sub) × N stages

---

## Verification Gates (V1)

| Gate | Trigger | Criteria | Blocker |
|------|---------|----------|---------|
| **Gate 0** | Wave 0 complete | `cordic_pkg` compiles, all types resolved, assertions bindable | No agent starts Wave 1 without this |
| **Gate 1** | Wave 1 complete | `fp_add_sub` + `cordic_lut` synthesize, pass unit TB, coverage >90% | Wave 2 cannot start |
| **Gate 2** | Wave 2 complete | `cordic_stage` passes rotation test vs golden model, 1-cycle latency | Wave 3 cannot start |
| **Gate 3** | Wave 3 complete | `cordic_pipeline` co-sim passes 10k random vectors, throughput = 1/cycle | Top integration cannot start |
| **Gate 4** | Wave 4 complete | `cordic_top` synthesizes, STA clean, DRC/LVS clean, area < 50k GE | Tape-out authorization |

---

## Risk Register (V1)

| ID | Risk | Probability | Impact | Mitigation |
|----|------|-------------|--------|------------|
| R1 | Synthesis infers RAM for `cordic_lut` | Medium | High (adds cycle latency) | Use `(* rom_style = "distributed" *)` + combinational `always_comb` |
| R2 | `fp_add_sub` carry-select doesn't meet timing | Low | Medium | Fallback: ripple-carry + register stage (2-cycle adder, verified) |
| R3 | Pipeline valid shifting breaks at boundaries | Medium | High | Formal verification of valid pipeline; directed TB for back-to-back |
| R4 | Student flow Fmax < 50 MHz post-P&R | Medium | Medium | Design for 100 MHz; measure actual; no frequency target in tracker |
| R5 | Agent scope creep (adding features) | High | High | **Frozen interfaces at Gate 0** — any interface change = architecture review |
| R6 | Golden model mismatch (CORDIC convergence) | Low | High | Python golden model in `tb/golden_model.py` — co-sim every wave |

---

## Version 2 Roadmap (Post-Tapeout)

| Version | Theme | Key Additions | Prerequisites |
|---------|-------|---------------|---------------|
| **V2.0** | Vectoring & Hyperbolic | Vectoring mode, hyperbolic CORDIC (sqrt, ln, exp), 16 iterations | V1 tapeout success |
| **V2.1** | Gain Compensation | Runtime K-factor multiplication, dynamic precision | V2.0 |
| **V2.2** | AXI Interfaces | AXI-Lite config, AXI-Stream data, CDC synchronization | V2.1 |
| **V2.3** | Matrix/Vector Ops | 2×2 matrix multiply, vector dot/cross, coordinate transforms | V2.2 |
| **V2.4** | Robotics Primitives | SE(2)/SE(3) transforms, 2-link/6-link IK, trajectory gen | V2.3 |
| **V3.0** | Multi-Core Array | Parameterized N-core CORDIC array, shared LUT, task queue | V2.4 |

---

## Sign-Off

| Role | Name | Signature | Date |
|------|------|-----------|------|
| Principal Architect | | ✅ Approved | 2026-07-22 |
| Technical Lead | | ✅ Approved | 2026-07-22 |
| Agent-A (fp_add_sub) | | ⏳ Pending | |
| Agent-B (cordic_lut) | | ⏳ Pending | |
| Agent-C (cordic_stage) | | ⏳ Pending | |
| Agent-D (cordic_pipeline) | | ⏳ Pending | |

---

**Next Action:** Lead publishes `cordic_pkg.sv` and `cordic_assertions.sv` (Wave 0). Agents review and acknowledge interface contracts. Gate 0 review scheduled for Week 1 end.