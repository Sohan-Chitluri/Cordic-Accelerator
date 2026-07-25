# Repository Migration Plan — CORDIC Accelerator ASIC Project

**Date:** 2026-07-22  
**Status:** APPROVED — Execute Before RTL Implementation  
**Author:** Principal ASIC Architect / Technical Lead

---

## 1. Current State Audit

### Canonical Documents (Keep — Single Source of Truth)

| File | Purpose | Authority |
|------|---------|-----------|
| `CORDIC_IMPLEMENTATION_TRACKER_v2.md` | Master execution tracker | **HIGHEST** |
| `docs/SPECIFICATION.md` | Functional & non-functional requirements | Requirements |
| `docs/MICROARCHITECTURE.md` | Datapath, pipeline, control, critical path | Architecture |
| `docs/PIPELINE.md` | Per-stage timing, register boundaries, latency | Architecture |
| `docs/FIXED_POINT_ANALYSIS.md` | Q-format, scaling, K-factor, error budget | Numerics |
| `docs/INTERFACE_SPECIFICATION.md` | All module interfaces, handshakes, timing | Interfaces |
| `docs/RTL_CODING_GUIDELINES.md` | Naming, style, synthesizable constructs, lint | Implementation |
| `docs/VERIFICATION_PLAN.md` | Strategy, gates, formal, coverage, golden model | Verification |
| `docs/TEST_PLAN.md` | Directed, random, corner, stress, error injection tests | Verification |
| `docs/TIMING_BUDGET.md` | Critical paths, stage budgets, STA methodology | Timing |
| `docs/DESIGN_REQUIREMENTS.md` | Constraints, assumptions, success metrics, gates | Project Mgmt |
| `docs/architecture_review_decisions.md` | Decision log with rationale | Architecture |
| `docs/adr/ADR-0001-V1-Scope.md` | V1 scope freeze | ADR |
| `docs/adr/ADR-0002-No-Multiplier.md` | No multiplier in V1 | ADR |
| `docs/adr/ADR-0003-No-AXI.md` | No AXI in V1 | ADR |
| `docs/adr/ADR-0004-Rotation-Only.md` | Rotation mode only | ADR |
| `docs/adr/ADR-0005-LUT-Prescaling.md` | LUT-based K-factor | ADR |

---

### Obsolete Documents (Archive → Delete)

| File | Reason | Superseded By |
|------|--------|---------------|
| `CORDIC_IMPLEMENTATION_TRACKER.md` | Initial tracker with 17 modules, 5 waves, multiplier, AXI | `CORDIC_IMPLEMENTATION_TRACKER_v2.md` |
| `docs/module_spec_cordic_arithmetic_pkg.md` | Old package spec (3 packages, hyperbolic, 16 iterations) | `SPECIFICATION.md`, `cordic_pkg` in tracker v2 |
| `docs/module_spec_fp_add_sub.md` | Old module spec (different interface, separate pkg) | `INTERFACE_SPECIFICATION.md`, tracker v2 |
| `docs/module_spec_shift_add_mul.md` | **DELETED MODULE** — Booth multiplier (ADR-0002) | **NONE — removed from V1** |
| `docs/module_spec_cordic_iterator.md` | **DELETED MODULE** — monolithic iterator (ADR-0004/0005) | `cordic_stage` + `cordic_lut` |

---

## 2. Contradiction Analysis

### Resolved Contradictions (Architecture Review Decisions)

| Contradiction | Resolution | ADR |
|---------------|------------|-----|
| 16 iterations vs 8 iterations | **8 iterations** (V1 default) | ADR-0001 |
| Multiplier for K-factor vs LUT prescale | **LUT prescale** (0-cycle, no multiplier) | ADR-0002, ADR-0005 |
| AXI-Lite config vs simple handshake | **Simple handshake** (valid/ready) | ADR-0003 |
| Vectoring + hyperbolic modes vs rotation only | **Rotation only** (V1) | ADR-0004 |
| Barrel shifter vs fixed per-stage shift | **Fixed shift** (hardwired per stage) | ADR-0004, MICROARCHITECTURE |
| Angle ROM (RAM) vs combinational LUT | **Combinational LUT** (0-cycle, distributed) | ADR-0005 |
| 3 packages vs 1 package | **Single `cordic_pkg.sv`** | ADR-0001 |
| 5 waves vs 4 waves | **4 waves** (3 agents + Lead) | ADR-0001 |

### No Outstanding Contradictions

All v2 documents are internally consistent and traceable to ADRs.

---

## 3. Migration Actions

### Phase 1: Delete Obsolete Files (Immediate)

```bash
# Delete old tracker
rm ~/projects/cordic-accelerator-asic/CORDIC_IMPLEMENTATION_TRACKER.md

# Delete obsolete module specs
rm ~/projects/cordic-accelerator-asic/docs/module_spec_cordic_arithmetic_pkg.md
rm ~/projects/cordic-accelerator-asic/docs/module_spec_fp_add_sub.md
rm ~/projects/cordic-accelerator-asic/docs/module_spec_shift_add_mul.md
rm ~/projects/cordic-accelerator-asic/docs/module_spec_cordic_iterator.md
```

### Phase 2: Rename Tracker to Canonical Name

```bash
mv ~/projects/cordic-accelerator-asic/CORDIC_IMPLEMENTATION_TRACKER_v2.md \
   ~/projects/cordic-accelerator-asic/CORDIC_IMPLEMENTATION_TRACKER.md
```

### Phase 3: Verify No Stale References

- Grep for deleted module names in remaining docs
- Update any cross-references
- Ensure all documents reference `cordic_pkg` not `cordic_arithmetic_pkg`

### Phase 4: Git Commit

```bash
git add -A
git commit -m "Architecture Review: migrate to V1 canonical docs

- Delete obsolete tracker and module specs (multiplier, iterator, old pkg)
- Rename tracker v2 to canonical name
- All architectural decisions frozen in ADRs
- Single source of truth established for RTL implementation"
```

---

## 4. Post-Migration Repository Structure

```
cordic-accelerator-asic/
├── CORDIC_IMPLEMENTATION_TRACKER.md     ← Single master tracker
├── Makefile
├── scripts/
│   ├── sim.py
│   ├── synth.tcl
│   └── sta.tcl
├── rtl/
│   ├── pkg/
│   │   └── cordic_pkg.sv                ← Lead (Wave 0)
│   ├── common/
│   │   └── cordic_assertions.sv         ← Lead (Wave 0)
│   ├── fp_add_sub.sv                    ← Agent-A (Wave 1)
│   ├── cordic_lut.sv                    ← Agent-B (Wave 1)
│   ├── cordic_stage.sv                  ← Agent-C (Wave 2)
│   ├── cordic_pipeline.sv               ← Agent-D (Wave 3)
│   └── cordic_top.sv                    ← Lead (Wave 4)
├── tb/
│   ├── cordic_tb.sv                     ← Lead (Gate 4)
│   ├── fp_add_sub_tb.sv                 ← Agent-A
│   ├── cordic_lut_tb.sv                 ← Agent-B
│   ├── cordic_stage_tb.sv               ← Agent-C
│   ├── cordic_pipeline_tb.sv            ← Agent-D
│   └── golden_model.py                  ← Lead
├── constraints/
│   └── cordic.sdc                       ← Lead (Gate 4)
└── docs/
    ├── SPECIFICATION.md                 ← Requirements
    ├── MICROARCHITECTURE.md             ← Architecture
    ├── PIPELINE.md                      ← Pipeline details
    ├── FIXED_POINT_ANALYSIS.md          ← Numerics
    ├── INTERFACE_SPECIFICATION.md       ← Interfaces
    ├── RTL_CODING_GUIDELINES.md         ← Coding rules
    ├── VERIFICATION_PLAN.md             ← Verification strategy
    ├── TEST_PLAN.md                     ← Test cases
    ├── TIMING_BUDGET.md                 ← Timing analysis
    ├── DESIGN_REQUIREMENTS.md           ← Project constraints
    ├── architecture_review_decisions.md ← Decision log
    └── adr/
        ├── ADR-0001-V1-Scope.md
        ├── ADR-0002-No-Multiplier.md
        ├── ADR-0003-No-AXI.md
        ├── ADR-0004-Rotation-Only.md
        └── ADR-0005-LUT-Prescaling.md
```

---

## 5. Canonical Reference Map

| Question | Answer In |
|----------|-----------|
| What are the V1 requirements? | `SPECIFICATION.md` |
| How does the datapath work? | `MICROARCHITECTURE.md` |
| What is the pipeline timing? | `PIPELINE.md` |
| What Q-format and K-factor? | `FIXED_POINT_ANALYSIS.md` |
| What are module interfaces? | `INTERFACE_SPECIFICATION.md` |
| How to write RTL? | `RTL_CODING_GUIDELINES.md` |
| How to verify? | `VERIFICATION_PLAN.md` + `TEST_PLAN.md` |
| What are timing budgets? | `TIMING_BUDGET.md` |
| What are project constraints? | `DESIGN_REQUIREMENTS.md` |
| Why these decisions? | `architecture_review_decisions.md` + `adr/` |
| What is the execution plan? | `CORDIC_IMPLEMENTATION_TRACKER.md` |

**No other documents answer these questions.**

---

## 6. Agent Onboarding (Post-Migration)

Each agent receives **only** these documents:

| Agent | Required Reading |
|-------|------------------|
| **All** | `SPECIFICATION.md`, `INTERFACE_SPECIFICATION.md`, `RTL_CODING_GUIDELINES.md`, `CORDIC_IMPLEMENTATION_TRACKER.md` |
| **Lead** | All documents |
| **Agent-A (fp_add_sub)** | + `MICROARCHITECTURE.md` §2.3, `TIMING_BUDGET.md` §2.2, `VERIFICATION_PLAN.md` §2.1 |
| **Agent-B (cordic_lut)** | + `MICROARCHITECTURE.md` §2.3, `FIXED_POINT_ANALYSIS.md` §6, `VERIFICATION_PLAN.md` §2.2 |
| **Agent-C (cordic_stage)** | + `MICROARCHITECTURE.md` §3-4, `PIPELINE.md` §2-3, `VERIFICATION_PLAN.md` §2.3 |
| **Agent-D (cordic_pipeline)** | + `MICROARCHITECTURE.md` §3, `PIPELINE.md` §1,5-7, `VERIFICATION_PLAN.md` §2.4, §3.2 |

---

## 7. Sign-Off

| Role | Name | Approved |
|------|------|----------|
| Principal Architect | | ✅ |
| Technical Lead | | ✅ |
| Agent-A | | ⏳ |
| Agent-B | | ⏳ |
| Agent-C | | ⏳ |
| Agent-D | | ⏳ |

**Execute migration. Then Wave 0 begins.**