# CORDIC Accelerator — DESIGN_REQUIREMENTS.md

**Project:** Parameterized Fixed-Point Pipelined CORDIC Accelerator (V1)  
**Document Version:** 1.0  
**Status:** APPROVED — Single Source of Truth  
**Derived From:** `SPECIFICATION.md`, Architecture Review Decisions

---

## 1. Engineering Constraints

| Constraint | Requirement | Rationale |
|------------|-------------|-----------|
| **Timeline** | One semester (15 weeks) | Academic schedule |
| **Team Size** | 3 agents + 1 Lead | Resource limit |
| **RTL Complexity** | < 1000 lines | Verifiable in timeline |
| **Verification Depth** | Unit + Integration + System | Industrial practice |
| **Tool Flow** | Open-source (Verilator, Yosys, OpenSTA) | Zero license cost |
| **Process Technology** | Generic 28nm / 45nm library | University flow |

---

## 2. Design Assumptions

| Assumption | Description | Impact if Wrong |
|------------|-------------|-----------------|
| **Single Clock Domain** | All logic on `clk` | CDC would require async FIFOs (+2 weeks) |
| **Synchronous Reset** | `rst_n` active-low, synchronous | Async reset needs CDC analysis |
| **No Analog/Mixed-Signal** | Pure digital | N/A |
| **Parameterizable** | WIDTH, FRACT_W, ITERATIONS | Fixed parameters reduce flexibility |
| **Rotation Mode Only** | V1 scope frozen | Vectoring adds 30% complexity |
| **LUT-based K-factor** | No multiplier needed | Multiplier adds 2-cycle latency |

---

## 3. Technology Assumptions

| Parameter | Assumed Value | Source |
|-----------|---------------|--------|
| **Process** | 28nm / 45nm standard cell | University PDK |
| **Voltage** | 0.9V / 1.0V | Typical |
| **Temperature** | -40°C to +125°C | Automotive |
| **Clock Frequency** | 100-300 MHz (post-P&R) | Measured, not targeted |
| **Standard Cells** | High-Vt, Low-Vt available | For power optimization |
| **SRAM/ROM** | Distributed LUTs only (V1) | No macro inference |
| **I/O Pads** | Not in scope (core only) | Top-level only |

---

## 4. ASIC Flow Assumptions

| Flow Step | Tool | Assumption |
|-----------|------|------------|
| **RTL Lint** | Verilator | Clean before synthesis |
| **Simulation** | Verilator | Cycle-accurate, fast |
| **Formal** | SymbiYosys + Z3 | Bounded model check |
| **Synthesis** | Yosys / DC | Generic library |
| **STA** | OpenSTA / PrimeTime | Post-synthesis netlist |
| **P&R** | OpenROAD / Innovus | If available |
| **DRC/LVS** | Magic / Calibre | Post-P&R |
| **Power** | UPF 3.0 + PowerArtist | Single domain |
| **Sign-off** | Gate 4 criteria | All must pass |

---

## 5. Success Metrics (Gate 4 — Tape-Out Readiness)

| Metric | Target | Measurement |
|--------|--------|-------------|
| **Functional Correctness** | 100% tests pass | Regression suite |
| **Numerical Accuracy** | < 0.15° angle error | Golden model co-sim |
| **Timing Closure** | WNS > 0, TNS < 0.1ns | STA report |
| **Area** | < 50k GE | Synthesis report |
| **Power** | Reported (no target) | Power report |
| **Coverage** | Stmt >95%, Branch >90% | Merged coverage |
| **Formal Proofs** | Key assertions proven | SymbiYosys log |
| **Lint** | Zero errors (waivers documented) | Verilator log |
| **CDC** | Zero violations | Single domain |
| **DRC/LVS** | Clean (if P&R run) | Tool report |

---

## 6. Quality Gates (Blocking)

| Gate | Criteria | Blocker If Failed |
|------|----------|-------------------|
| **Gate 0** | `cordic_pkg` compiles, lint clean, assertions bindable | No agent starts Wave 1 |
| **Gate 1** | Wave 1 modules: synth, unit tests, coverage >90% | Wave 2 cannot start |
| **Gate 2** | `cordic_stage` integration, formal proven | Wave 3 cannot start |
| **Gate 3** | `cordic_pipeline` 10k vectors, throughput verified | Top integration cannot start |
| **Gate 4** | Full regression, STA clean, coverage >95%, area <50k | No tape-out |

---

## 7. Risk Acceptance Criteria

| Risk | Acceptance Threshold |
|------|---------------------|
| **Fmax < 50 MHz** | Acceptable if functional; document limitation |
| **Area > 50k GE** | Acceptable if < 100k GE; investigate |
| **Coverage < Target** | Acceptable if >80% stmt with justification |
| **Formal Timeout** | Acceptable if bounded check passes at depth 20 |
| **Tool Bug** | Workaround documented; escalate to Lead |

---

## 8. Deliverables (V1)

| Deliverable | Format | Location |
|-------------|--------|----------|
| **RTL Source** | SystemVerilog | `rtl/` |
| **Testbench** | SystemVerilog + Python | `tb/` |
| **Constraints** | SDC | `constraints/` |
| **Documentation** | Markdown | `docs/` |
| **Scripts** | Python, Tcl, Make | `scripts/` |
| **Verification Results** | Logs, Coverage DB | `results/` |
| **Synthesis Reports** | Area, Timing, Power | `reports/` |
| **GDSII** | GDSII (if P&R) | `output/` |

---

## 9. Configuration Management

| Artifact | Version Control | Review Required |
|----------|-----------------|-----------------|
| **Specification Docs** | Git (master) | Lead + Architect |
| **RTL Source** | Git (feature branches) | Gate reviews |
| **Testbench** | Git (with RTL) | Gate reviews |
| **Constraints** | Git (with RTL) | Gate 4 |
| **Scripts** | Git (master) | Lead |
| **Reports** | Git LFS / Artifacts | Gate 4 |

---

## 10. Communication Protocol

| Event | Participants | Frequency |
|-------|--------------|-----------|
| **Gate Review** | Lead, Agents, Architect | At each gate |
| **Weekly Sync** | All | Weekly |
| **Blocker Escalation** | Agent → Lead | Immediate |
| **Scope Change** | Lead → Architect | Formal ADR |

---

**End of DESIGN_REQUIREMENTS.md**  
*These requirements define the boundaries of V1. All deviations require formal ADR.*