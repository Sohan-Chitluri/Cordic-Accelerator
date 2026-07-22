# CORDIC Accelerator - RTL Implementation Tracker

**Project:** Parameterized Fixed-Point Pipelined CORDIC Accelerator  
**Target:** Full RTL-to-GDSII ASIC Flow  
**Tracking Method:** Industrial ASIC Development (parameterization, synthesizability, clean interfaces)  
**Status:** Planning Phase  
**Created:** 2026-07-22

---

## Executive Summary

This tracker defines the complete RTL implementation plan for a CORDIC accelerator supporting both rotation and vectoring modes. The design is decomposed into independent modules for parallel development with explicit integration ordering.

### Critical Path Analysis

The **critical path** for this project flows through:

1. **CORDIC Core Engine** (longest compute latency)
2. **Pipeline Control** (must coordinate with core)
3. **Fixed-Point Arithmetic** (shared across modules)
4. **Top-Level Integration** (cannot proceed without all subsystems)

*Reasoning:* The CORDIC algorithm inherently has O(N) iterations where N = number of stages. Pipeline control must match this timing. Fixed-point arithmetic primitives are used by 4+ modules, making them critical for integration. Synthesis cannot begin until timing is closed through all pipeline stages.

---

## Module Decomposition

### Wave 1: Foundational Primitives (Can start immediately)

| Module | Owner | Scope | Dependencies | Interface | Exit Criteria | Verification | Deliverables |
|--------|-------|-------|--------------|-----------|---------------|--------------|--------------|
| **FP_ADD_SUB** | Agent-Alpha | Parameterized N-bit adder/subtractor with carry-select optimization | None | `a[N], b[N], op(1), result[N+1]` | Passes all arithmetic tests, synthesizes < 500ps | FP testbench with corner cases (zeros, max, min, negatives) | `fp_add_sub.sv`, `fp_add_sub_pkg.sv` |
| **FP_MULT_CSN** | Agent-Beta | Shift-add multiplier with modular reduction | None | `a[N], b[M], result[N+M]` | Area < 2x ripple, timing < 400ps | MPR test with random inputs | `fp_mult_csn.sv` |
| **ARITH_PKG** | Agent-Gamma | Shared arithmetic package: typedefs, macros, functions | None | `localparam types, ROUND_MODES, SAT_FLAGS` | Compiles clean, lint pass | Package compilation check | `cordic_arithmetic_pkg.sv` |

### Wave 2: Angle/Vector Processing (Depends on Wave 1)

| Module | Owner | Scope | Dependencies | Interface | Exit Criteria | Verification | Deliverables |
|--------|-------|-------|--------------|-----------|---------------|--------------|--------------|
| **ANGLE_GEN** | Agent-Delta | Angle lookup ROM + phase accumulator | ARITH_PKG | `addr[ADDR_W], angle_out[FIXED_W]` | ROM initialization verified, timing < 300ps | Golden model comparison (atan lookup) | `angle_generator.sv` |
| **GAIN_COMP** | Agent-Epsilon | CORDIC gain compensation module (pre-computed or runtime) | ARITH_PKG | `x_in, y_in, x_out, y_out` | Gain accuracy < 0.1%, timing verified | MATLAB/Python golden comparison | `gain_compensator.sv` |

### Wave 3: CORDIC Engine Core (Depends on Waves 1-2)

| Module | Owner | Scope | Dependencies | Interface | Exit Criteria | Verification | Deliverables |
|--------|-------|-------|--------------|-----------|---------------|--------------|--------------|
| **CORDIC_STAGE** | Agent-Zeta | Single CORDIC pipeline stage (rotation or vectoring) | FP_ADD_SUB, FP_MULT_CSN | `x_in, y_in, z_in, x_out, y_out, z_out, opcode` | Correct rotation by known angle, synthesizable | Unit test with known-vector verification | `cordic_stage.sv` |
| **CORDIC_PIPE** | Agent-Eta | N-stage pipelined CORDIC engine with control FSM | CORDIC_STAGE, ANGLE_GEN, GAIN_COMP | AXI-Stream slave, config interface, result bus | All iterations execute correctly, backpressure handled | Co-simulation with golden model, random stimulus | `cordic_pipeline.sv` |

### Wave 4: Integration & Control (Depends on Waves 1-3)

| Module | Owner | Scope | Dependencies | Interface | Exit Criteria | Verification | Deliverables |
|--------|-------|-------|--------------|-----------|---------------|--------------|--------------|
| **REGFILE** | Agent-Theta | Configuration register file with sideband signals | None | AXI-Lite config interface | All registers read/write correct, reset values | UVM register model, back-to-back tests | `cordic_regfile.sv` |
| **TOP_MODULE** | Agent-Iota | Top-level integration with clock/reset/domain crossing | All modules above | Standard ASIC top-level ports | Integration clean, passes synthesis | Top-level integration test, timing closure | `cordic_top.sv`, `cordic_top_pkg.sv` |

---

## Integration Wave Dependencies

```
Wave 1 (Parallel, no deps):
  ARITH_PKG ──► FP_ADD_SUB, FP_MULT_CSN

Wave 2 (Parallel after Wave 1):
  ANGLE_GEN ──►
  GAIN_COMP ──►

Wave 3 (Parallel after Wave 2):
  CORDIC_STAGE ──► CORDIC_PIPE ◄── ANGLE_GEN, GAIN_COMP

Wave 4 (Sequential after Wave 3):
  REGFILE ──► TOP_MODULE ◄── CORDIC_PIPE, FP_ADD_SUB, FP_MULT_CSN

Verification Gate ──► Synthesis Gate
```

---

## Verification Gates

### Gate 1: Unit Verification (Pre-W3)
- Each Wave 1-2 module passes standalone tests
- Code coverage > 90% per module
- Synthesisable (checked via `yosys -p synth` or equivalent)

### Gate 2: Pipeline Integration Verification (Pre-W4)
- CORDIC_PIPE tested with all mode combinations
- Back-to-back data tested (consecutive iterations)
- Latency verified against parameter `NUM_STAGES`

### Gate 3: Top-Level Verification (Pre-Synthesis)
- All interfaces exercised (AXI-Stream, AXI-Lite)
- Reset recovery and domain crossing verified
- Timing constraint validated (`cordic.sdc`)

### Gate 4: Synthesis Readiness (Pre-GDSII)
- Area estimate < 50k gates (target)
- Timing closure at 500MHz (target)
- Power intent defined (`cordic.upf`)

---

## Expected Deliverables Summary

| Artifact | Location | Type |
|----------|----------|------|
| RTL Source | `rtl/*.sv` | SystemVerilog |
| Package Files | `rtl/pkg/*.sv` | SystemVerilog packages |
| Testbenches | `tb/*_tb.sv` | SystemVerilog |
| Constraints | `constraints/cordic.sdc` | Synopsys SDC |
| Assertions | `rtl/common/cordic_assertions.sv` | SVA |
| Documentation | `docs/` | Markdown |
| Build Scripts | `scripts/build.tcl` | Tcl scripts |

---

## File Ownership Matrix (Minimizes Merge Conflicts)

| Agent | Exclusive Files |
|-------|-----------------|
| Agent-Alpha | `rtl/fp_add_sub.sv`, `rtl/pkg/fp_add_sub_pkg.sv` |
| Agent-Beta | `rtl/fp_mult_csn.sv` |
| Agent-Gamma | `rtl/pkg/cordic_arithmetic_pkg.sv` |
| Agent-Delta | `rtl/angle_generator.sv` |
| Agent-Epsilon | `rtl/gain_compensator.sv` |
| Agent-Zeta | `rtl/cordic_stage.sv` |
| Agent-Eta | `rtl/cordic_pipeline.sv` |
| Agent-Theta | `rtl/cordic_regfile.sv` |
| Agent-Iota | `rtl/cordic_top.sv`, `rtl/pkg/cordic_top_pkg.sv` |

---

## Status Legend
- ⚪ Not Started
- 🟡 In Progress
- 🟢 Completed / Verified
- 🔴 Blocked
- ⚫ Deprecated

---

## Progress Tracking

| Module | Status | Notes |
|--------|--------|-------|
| ARITH_PKG | ⚪ | Waiting for Wave 1 start |
| FP_ADD_SUB | ⚪ | |
| FP_MULT_CSN | ⚪ | |
| ANGLE_GEN | ⚪ | |
| GAIN_COMP | ⚪ | |
| CORDIC_STAGE | ⚪ | |
| CORDIC_PIPE | ⚪ | |
| REGFILE | ⚪ | |
| TOP_MODULE | ⚪ | |

---

## Next Action

1. Create project structure with directories for `rtl/`, `tb/`, `docs/`, `constraints/`
2. Initialize git repository
3. Assign agents to Wave 1 modules
4. Execute parallel development on Wave 1