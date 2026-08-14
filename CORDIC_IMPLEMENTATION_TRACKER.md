# CORDIC Accelerator - RTL Implementation Tracker

**Project:** Parameterized Fixed-Point Pipelined CORDIC Accelerator  
**Target:** Full RTL-to-GDSII ASIC Flow (1 semester)  
**Architecture Review:** Principal ASIC Architect / Technical Lead  
**Status:** Post-Architecture-Review — Approved for Execution  
**Repository:** `~/projects/cordic-accelerator-asic/`  
**Git Branch:** `master` (commit: `701ece2`)

---

## Executive Summary

This tracker is the result of a formal architecture review of the initial implementation plan. The review applied industrial ASIC development principles to maximize probability of successful RTL→GDSII completion within one semester while preserving clean extensibility for a future Robotics Mathematics Accelerator.

### Key Architecture Decisions (Post-Review)

| Decision | Rationale |
|----------|-----------|
| **No general-purpose multiplier in V1** | Classical CORDIC uses shift-add only; Booth multiplier adds 2-cycle latency, ~3× area, formal verification burden for zero benefit in rotation/vectoring modes |
| **Gain compensation = shift-add constant K-prescaling (V1)** | Zero-cycle, zero multiplier, full input precision, 0.028% K-error; original 4-MSB LUT rejected (discards fractional bits). See ADR-0005. |
| **No AXI-Lite register file (V1)** | Hardened registers via simple `config_valid`/`config_ready` handshake eliminates protocol compliance risk; AXI-Lite added in V2 |
| **Fmax target removed** | Measure actual Fmax post-synthesis; design for correct-by-construction timing at reasonable frequency (100-200 MHz typical for student ASIC flow) |
| **3 pipeline stages → 2** | V1 implements rotation mode only (vectoring in V2); eliminates mode MUX in critical path, reduces stages from 16→8 for 16-bit |
| **Angle ROM → Combinational LUT** | 16 entries × 16 bits = 256 bits; distributed ROM synthesizes to LUTs with zero cycle latency, no RAM inference risk |

---

## Critical Path Analysis (Revised)

```
                    ┌─────────────────────┐
                    │  CORDIC Core        │  ← CRITICAL PATH
                    │  (N stages of       │     N × (shift + mux + add)
                    │   shift-add-mux)    │
                    └──────────┬──────────┘
                               │
              ┌────────────────┼────────────────┐
              ▼                ▼                ▼
       ┌─────────────┐  ┌─────────────┐  ┌─────────────┐
       │ Input       │  │ Pipeline    │  │ Gain        │
       │ Prescaler   │  │ Registers   │  │ Compensation│
       │ (LUT, 0-cycle)│  │ (N+1 cycles)│  │ (LUT, 0-cycle)│
       └─────────────┘  └─────────────┘  └─────────────┘
```

**Critical path = N × (barrel_shifter + 2:1_mux + adder)** where N = `ITERATIONS` (default 8 for 16-bit V1).

**Optimization:** Barrel shifter → fixed shift per stage (hardwired) eliminates shifter from critical path. Each stage becomes: `mux + adder` only.

---

## Module Decomposition — Version 1 Scope

### V1 Modules (9 total — all required for GDSII)

| # | Module | Owner | Wave | File | Lines (est) | Purpose |
|---|--------|-------|------|------|-------------|---------|
| 1 | `cordic_pkg.sv` | Lead | 0 | `rtl/pkg/cordic_pkg.sv` | 120 | Single source of truth: types, constants, functions |
| 2 | `cordic_assertions.sv` | Lead | 0 | `rtl/common/cordic_assertions.sv` | 80 | SVA: overflow, valid/ready, monotonic angle, K-factor bounds |
| 3 | `fp_add_sub.sv` | Agent-A | 1 | `rtl/fp_add_sub.sv` | 180 | Saturating adder/subtractor, carry-select, 1-cycle |
| 4 | `cordic_lut.sv` | Agent-B | 1 | `rtl/cordic_lut.sv` | 80 | Combinational atan(2⁻ⁱ) LUT + K-factor prescaler LUT |
| 5 | `cordic_stage.sv` | Agent-C | 2 | `rtl/cordic_stage.sv` | 150 | Single CORDIC iteration: fixed shift + mux + fp_add_sub |
| 6 | `cordic_pipeline.sv` | Agent-D | 3 | `rtl/cordic_pipeline.sv` | 200 | N-stage pipeline, valid/ready handshake, rotation mode only |
| 7 | `cordic_top.sv` | Lead | 4 | `rtl/cordic_top.sv` | 120 | Top-level: pipeline + config handshake + I/O |
| 8 | `cordic.sdc` | Lead | 4 | `constraints/cordic.sdc` | 50 | Clock, I/O delays, false paths (none in V1) |
| 9 | `cordic_tb.sv` + golden_model.py | Lead | 1-4 | `tb/cordic_tb.sv` | 300 | Self-checking testbench with Python golden model |

### V1 Explicitly Excluded (Deferred to V2)

| Feature | Module | Reason |
|---------|--------|--------|
| Vectoring mode | `cordic_stage` mode MUX | Adds critical path MUX; separate datapath in V2 |
| Hyperbolic mode | Repeat iteration logic | Requires iteration 4,13 repeat; separate V2 pipeline |
| Gain compensation multiplier | `shift_add_mul` | Not needed — shift-add constant K-prescaling is multiplier-free for fixed N |
| AXI-Lite register file | `cordic_regfile` | Protocol compliance risk; simple handshake in V1 |
| AXI-Stream data interfaces | `cordic_top` ports | Valid/ready handshake sufficient for V1 verification |
| Matrix/vector ops | New modules | Robotics Accelerator V2+ scope |
| Coordinate transforms | New modules | Robotics Accelerator V2+ scope |
| Inverse kinematics | New modules | Robotics Accelerator V2+ scope |

---

## Interface Contracts (Frozen at Wave 0)

### `cordic_pkg.sv` — Single Source of Truth

```systemverilog
package cordic_pkg;
  // =========================================================================
  // PARAMETERS (overridable at top level)
  // =========================================================================
  parameter int WIDTH       = 16;
  parameter int FRACT_W     = 12;
  parameter int ITERATIONS  = 8;          // V1: 8 stages for 16-bit rotation
  parameter real K_FACTOR   = 0.6072529350088813;

  // =========================================================================
  // TYPES
  // =========================================================================
  typedef logic signed [WIDTH-1:0]     fixed_t;
  typedef logic signed [WIDTH:0]       fixed_ext_t;  // +1 for overflow
  typedef logic [WIDTH-1:0]            fixed_u_t;
  typedef logic [$clog2(ITERATIONS):0] stage_idx_t;

  typedef struct packed {
    fixed_t x;
    fixed_t y;
    fixed_t z;
  } cordic_in_t;

  typedef struct packed {
    fixed_t x;
    fixed_t y;
    fixed_t z;
    logic   valid;
    logic   overflow;
  } cordic_out_t;

  // Configuration (simple handshake, no AXI)
  typedef struct packed {
    logic [3:0]  iterations;   // 1-16, default = ITERATIONS
    logic        saturate;     // 1 = saturate, 0 = wrap
    logic [1:0]  reserved;
  } cordic_cfg_t;

  // =========================================================================
  // CONSTANTS (pre-computed at elaboration)
  // =========================================================================
  localparam fixed_t MAX_POS  = (1 << (WIDTH-1)) - 1;
  localparam fixed_t MIN_NEG  = -(1 << (WIDTH-1));
  localparam fixed_t ONE_FIX  = (1 << FRACT_W);
  localparam fixed_t HALF_FIX = (1 << (FRACT_W-1));

  // =========================================================================
  // FUNCTIONS
  // =========================================================================
  function automatic fixed_t sat_add(input fixed_t a, input fixed_t b, input bit sat);
  function automatic fixed_t sat_sub(input fixed_t a, input fixed_t b, input bit sat);
  function automatic fixed_t arith_shift_right(input fixed_t val, input int shamt, input bit round);
  function automatic fixed_u_t real_to_fixed(input real val);
  function automatic real fixed_to_real(input fixed_t val);
  function automatic fixed_t k_factor_prescale(input fixed_t val);  // × K_FACTOR via LUT
endpackage
```

### Module Interfaces (Frozen)

| Module | Interface | Direction | Signals |
|--------|-----------|-----------|---------|
| `fp_add_sub` | `fp_add_sub_if` | In | `a`, `b`, `op` (0=add,1=sub), `sat` |
| | | Out | `result`, `overflow` |
| `cordic_lut` | `cordic_lut_if` | In | `x_in`, `y_in` (full-width, signed) |
| | | Out | `k_prescale_x`, `k_prescale_y` |
| `cordic_stage` | `cordic_stage_if` | In | `x_in`, `y_in`, `z_in`, `stage_idx`, `valid_in`, `sat` |
| | | Out | `x_out`, `y_out`, `z_out`, `valid_out`, `overflow` |
| `cordic_pipeline` | `cordic_pipe_if` | In | `x_in`, `y_in`, `z_in`, `cfg`, `valid_in`, `ready_out` |
| | | Out | `x_out`, `y_out`, `z_out`, `valid_out`, `ready_in`, `overflow` |
| `cordic_top` | Top-level ports | In | `clk`, `rst_n`, `x_in`, `y_in`, `z_in`, `valid_in`, `ready_out`, `cfg`, `config_valid`, `ready_in` |
| | | Out | `x_out`, `y_out`, `z_out`, `valid_out`, `ready_in`, `overflow`, `irq` |

---

## Integration Waves

### Wave 0 — Foundation (Week 1) — **Lead Integration Only**

| Task | Owner | Exit Criteria | Deliverable |
|------|-------|---------------|-------------|
| Create `cordic_pkg.sv` | Lead | ✅ Compiles, lint clean, all types used downstream | `rtl/pkg/cordic_pkg.sv` |
| Create `cordic_assertions.sv` | Lead | ✅ All assertions provable (bounded model check) | `rtl/common/cordic_assertions.sv` |
| Define all interface contracts | Lead | ✅ Documented in tracker, reviewed by all agents | This tracker (Section: Interface Contracts) |
| Setup verification infrastructure | Lead | ✅ `make sim` runs, Python golden model available | `scripts/sim.py`, `tb/golden_model.py` |

**Gate 0:** All agents have `cordic_pkg.sv` and interface contracts. No RTL written yet.

---

### Wave 1 — Primitives (Week 2) — **Parallel: 2 Agents**

| Module | Owner | Scope | Dependencies | Exit Criteria | Verification |
|--------|-------|-------|--------------|---------------|--------------|
| `fp_add_sub.sv` | Agent-A | Saturating adder/subtractor, carry-select, 1-cycle combinational | `cordic_pkg` | ✅ Synthesizes, timing @ 200MHz, area < 2× RCA, all SAT modes verified | Exhaustive corners (0, ±MAX, overflow), random vs golden, formal equivalence vs RCA |
| `cordic_lut.sv` | Agent-B | Combinational atan(2⁻ⁱ) LUT (8 entries) + K-factor prescaler LUT | `cordic_pkg` | ✅ LUT values match Python golden ±1 LSB, 0-cycle latency, synthesizes to LUTs not RAM | All 8 addresses tested, K-factor LUT verified for all input ranges |

**Gate 1:** Both modules pass unit verification, synthesis timing clean, coverage > 95%.

---

### Wave 2 — Core Stage (Week 3) — **Single Agent**

| Module | Owner | Scope | Dependencies | Exit Criteria | Verification |
|--------|-------|-------|--------------|---------------|--------------|
| `cordic_stage.sv` | Agent-C | Single CORDIC iteration: fixed shift (hardwired per stage) + 2:1 mux (dir) + `fp_add_sub` for x/y/z update | `cordic_pkg`, `fp_add_sub`, `cordic_lut` | ✅ Known-angle rotation test passes, vectoring convergence verified (for V2), 1-cycle latency, no timing violations | Rotation by atan(2⁻ⁱ) for all 8 stages, random vs golden CORDIC model, formal: x²+y² invariant (rotation mode) |

**Gate 2:** Stage verified in isolation; integrates cleanly with `fp_add_sub` and `cordic_lut`.

---

### Wave 3 — Pipeline Assembly (Week 4) — **Single Agent**

| Module | Owner | Scope | Dependencies | Exit Criteria | Verification |
|--------|-------|-------|--------------|---------------|--------------|
| `cordic_pipeline.sv` | Agent-D | N-stage pipeline (N=ITERATIONS): instantiates `cordic_stage[N]`, connects `cordic_lut`, valid/ready handshake, config handshake | All Wave 1-2 modules | ✅ Full rotation mode verified: sin/cos generation error < 0.1%, latency = N+1 cycles, throughput = 1/cycle, backpressure works | Co-simulation with Python golden model: 10k random vectors, corner angles (0, π/4, π/2, π), throughput test, reset recovery |

**Gate 3:** Pipeline passes full integration verification; timing clean at target frequency.

---

### Wave 4 — Top-Level & Sign-Off (Week 5) — **Lead Integration Only**

| Module | Owner | Scope | Dependencies | Exit Criteria | Verification |
|--------|-------|-------|--------------|---------------|--------------|
| `cordic_top.sv` | Lead | Top-level: `cordic_pipeline` + config handshake + I/O registers + IRQ | `cordic_pipeline`, `cordic_pkg` | ✅ Integration clean, all ports connected, synthesis passes, STA clean | Full top-level testbench, CDC check (none in V1), reset sequence |
| `cordic.sdc` | Lead | Clock definition, input/output delays (set_input_delay/set_output_delay), clock uncertainty | `cordic_top` | ✅ STA passes: zero setup/hold violations, slack > 0 | `make sta` → report |
| `cordic_tb.sv` | All | Regression testbench: all prior tests + coverage merge | All modules | ✅ Merged coverage > 95%, all tests pass | `make regress` |

**Gate 4 (Tape-Out Readiness):** STA clean, DRC/LVS clean (post-synthesis netlist), full regression passes, area < 20k gates (est).

---

## Dependency Graph

```
WAVE 0 (Lead)
┌─────────────────────┐
│ cordic_pkg.sv       │ ◄── Frozen interface contracts
│ cordic_assertions.sv│
└──────────┬──────────┘
           │
     ┌─────┴─────┐
     ▼           ▼
WAVE 1      WAVE 1
(Agent-A)   (Agent-B)
┌─────────┐ ┌─────────┐
│fp_add_sub│ │cordic_  │
│.sv       │ │lut.sv   │
└────┬────┘ └────┬────┘
     │           │
     └─────┬─────┘
           ▼
      WAVE 2
    (Agent-C)
┌────────────────┐
│cordic_stage.sv │
└───────┬────────┘
        ▼
      WAVE 3
    (Agent-D)
┌──────────────────┐
│cordic_pipeline.sv│
└────────┬─────────┘
         ▼
      WAVE 4
     (Lead)
┌──────────────┐  ┌──────────┐  ┌────────────┐
│cordic_top.sv │  │cordic.sdc│  │cordic_tb.sv│
└──────────────┘  └──────────┘  └────────────┘
         │
         ▼
   ┌───────────┐
   │  GDSII    │
   └───────────┘
```

**Parallelism:** Wave 1 (2 agents), Waves 2-3-4 sequential (critical path). Total: 5 weeks.

---

## Module Ownership Matrix (Exclusive File Ownership)

| Agent | Exclusive Files | Shared Files (Read-Only) |
|-------|-----------------|--------------------------|
| Lead | `rtl/pkg/cordic_pkg.sv`, `rtl/common/cordic_assertions.sv`, `rtl/cordic_top.sv`, `constraints/cordic.sdc`, `tb/cordic_tb.sv` | All |
| Agent-A | `rtl/fp_add_sub.sv`, `tb/fp_add_sub_tb.sv` | `cordic_pkg.sv` |
| Agent-B | `rtl/cordic_lut.sv`, `tb/cordic_lut_tb.sv` | `cordic_pkg.sv` |
| Agent-C | `rtl/cordic_stage.sv`, `tb/cordic_stage_tb.sv` | `cordic_pkg.sv`, `fp_add_sub.sv`, `cordic_lut.sv` |
| Agent-D | `rtl/cordic_pipeline.sv`, `tb/cordic_pipeline_tb.sv` | All prior modules |

**Merge Conflict Prevention:** Zero shared RTL files. Packages owned by Lead only. Testbenches owned by module owner.

---

## Verification Strategy (Undergraduate ASIC Flow)

| Level | Method | Tool | Gate |
|-------|--------|------|------|
| **Unit** | Directed + random + formal equivalence | Verilator / Yosys / SymbiYosys | Gates 1, 2 |
| **Integration** | Co-simulation with Python golden model | Verilator + pytest | Gate 3 |
| **Top-Level** | Self-checking testbench, coverage merge | Verilator | Gate 4 |
| **Formal** | SVA assertions: overflow, valid/ready, x²+y² invariant | SymbiYosys (bounded) | Gates 0, 2 |
| **STA** | Post-synthesis timing analysis | OpenSTA / vendor | Gate 4 |
| **CDC** | None in V1 (single clock domain) | — | — |

**Coverage Targets:** Statement > 95%, Branch > 90%, Toggle > 85%, FSM > 100%.

**Golden Model:** Python `cordic_golden.py` — bit-exact fixed-point CORDIC reference for co-simulation.

---

## Risk Analysis & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| **Timing closure failure** | Medium | High (blocks GDSII) | Fixed shifts per stage (no barrel shifter), carry-select adder, measure Fmax early (Wave 1), reduce ITERATIONS to 8 |
| **Functional bug in pipeline** | Medium | High | Co-simulation at every wave; golden model from Day 1; formal x²+y² invariant |
| **Merge conflicts** | Low | Medium | Exclusive file ownership; Lead-only package edits; git feature branches per wave |
| **Scope creep** | High | High | **V1 scope frozen** — no AXI, no vectoring, no hyperbolic, no multiplier. V2 roadmap documented but not implemented. |
| **Tool flow issues** | Medium | Medium | Use Verilator for simulation (fast, free); Yosys for synthesis check; OpenSTA for timing; document all scripts |
| **Area > target** | Low | Medium | Estimate: 8 stages × (~200 gates) + adder + LUT ≈ 12k gates. Well under 20k budget. |
| **Student availability** | High | High | 5-week plan with 1-week buffer; Lead can absorb any single agent delay in Waves 2-3 |

---

## Version 2 Roadmap (Post-GDSII)

> **Not part of V1.** Documented here to preserve interface stability and architectural intent.

### V2.1 — Vectoring & Hyperbolic Modes (2 weeks)
| Feature | Module Changes | Interface Impact |
|---------|----------------|------------------|
| Vectoring mode (atan2, √(x²+y²)) | `cordic_stage`: add `mode` input, conditional `z` update direction | `cordic_pkg`: add `cordic_mode_e {ROTATE, VECTOR, HYPERBOLIC}`; `cordic_cfg_t`: add `mode` field |
| Hyperbolic mode (sinh, cosh, √) | `cordic_stage`: repeat iterations 4,13 (1-indexed); `cordic_lut`: add `atanh` LUT | `cordic_lut_if`: add `atanh_out` |
| Dynamic iteration count | `cordic_pipeline`: variable-stage enable mask | `cordic_cfg_t`: `iterations` already exists |

### V2.2 — AXI Interfaces (1 week)
| Feature | Module Changes | Interface Impact |
|---------|----------------|------------------|
| AXI-Lite config register file | New `cordic_regfile.sv` wrapping `cordic_top` config | Top-level: add `axi_lite_slave` port; internal: config handshake → AXI-Lite adapter |
| AXI-Stream data interfaces | `cordic_top`: wrap `cordic_pipeline` valid/ready in AXI-Stream | Top-level: `s_axis`, `m_axis` ports; TLAST/TUSER for frame delimiting |

### V2.3 — Robotics Mathematics Accelerator (4-6 weeks)
| Feature | New Modules | Description |
|---------|-------------|-------------|
| 2D/3D Rotation Matrix | `rot_matrix_2d.sv`, `rot_matrix_3d.sv` | Compose 3× CORDIC rotations for Euler/quaternion |
| Coordinate Transforms | `coord_transform.sv` | World↔Body, ENU↔NED, spherical↔Cartesian |
| Vector Operations | `vec_norm.sv`, `vec_dot.sv`, `vec_cross.sv` | Fixed-point vector math using CORDIC √ and multiply |
| Matrix Operations | `mat_mul_3x3.sv`, `mat_inv_3x3.sv` | Small matrix ops for pose estimation |
| Inverse Kinematics | `ik_solver_2link.sv`, `ik_solver_6link.sv` | CORDIC-based analytic IK for robot arms |
| Trajectory Generation | `traj_gen.sv` | Polynomial/spline trajectory with CORDIC trig |

### V2.4 — Advanced Features (Ongoing)
- **Parameterized precision:** 16/24/32-bit via `WIDTH`/`FRACT_W`
- **Multi-core CORDIC:** Array of pipelines with shared LUT
- **Power optimization:** Clock gating per stage, operand isolation
- **Formal verification:** Full proof of x²+y² invariant, overflow freedom

---

## Implementation Checklist (Track in Git Issues)

```
[ ] Wave 0: cordic_pkg.sv, cordic_assertions.sv, interface contracts, sim infra
[ ] Wave 1: fp_add_sub.sv (Agent-A) ──► Gate 1
[ ] Wave 1: cordic_lut.sv (Agent-B)  ──► Gate 1
[ ] Wave 2: cordic_stage.sv (Agent-C) ──► Gate 2
[ ] Wave 3: cordic_pipeline.sv (Agent-D) ──► Gate 3
[ ] Wave 4: cordic_top.sv, cordic.sdc, cordic_tb.sv (Lead) ──► Gate 4 (Tape-Out)
[ ] STA sign-off, DRC/LVS clean, area report, final regression
[ ] Tag release: v1.0-tapeout
```

---

## Git Workflow

```bash
# Wave 0 (Lead only)
git checkout -b wave0-foundation
# ... implement packages ...
git commit -am "Wave 0: Foundation packages"
git tag wave0-frozen
git push origin wave0-frozen

# Wave 1 (3 agents in parallel)
git checkout wave0-frozen
git checkout -b wave1-fp_add_sub     # Agent-A
git checkout -b wave1-cordic_lut     # Agent-B
# ... implement ...
# Each agent pushes branch, Lead merges after Gate 1 pass

# Wave 2-4 follow same pattern
```

---

**End of Implementation Tracker** — Approved for execution. All agents begin Wave 0 package review.