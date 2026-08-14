# CORDIC Accelerator — SPECIFICATION.md

**Project:** Parameterized Fixed-Point Pipelined CORDIC Accelerator (V1)  
**Target:** RTL→GDSII ASIC Flow (One Semester)  
**Document Version:** 1.0  
**Status:** APPROVED — Single Source of Truth  
**Review Date:** 2026-07-22  
**Architecture Review:** See `architecture_review_decisions.md` and `adr/`

---

## 1. Project Objectives

| Objective | Description |
|-----------|-------------|
| **Primary** | Deliver a synthesizable, verifiable, timing-closed RTL implementation of a parameterized fixed-point CORDIC accelerator capable of full RTL→GDSII flow completion within one academic semester. |
| **Secondary** | Establish clean architectural foundation for future expansion into a Robotics Mathematics Accelerator (V2+). |
| **Tertiary** | Demonstrate industrial ASIC development workflow: specification → microarchitecture → RTL → verification → synthesis → STA → P&R → GDSII. |

---

## 2. Functional Requirements (V1)

| ID | Requirement | Description |
|----|-------------|-------------|
| FR-01 | **Rotation Mode** | Compute `x_out = K × (x_in cos(z_in) - y_in sin(z_in))`, `y_out = K × (x_in sin(z_in) + y_in cos(z_in))`, `z_out ≈ 0` for input vector `(x_in, y_in)` and angle `z_in`. **Input angle range restricted to approximately ±1.74 rad (~±99.5°)** — the standard CORDIC convergence zone for 8 iterations. Inputs outside this range produce undefined results. Full ±π range via quadrant folding is deferred to V2. |
| FR-02 | **Parameterized Precision** | Data width `WIDTH` (default 16), fractional bits `FRACT_W` (default 12), iteration count `ITERATIONS` (default 8) all parameterizable at elaboration. |
| FR-03 | **Pipelined Execution** | One input vector accepted per cycle after pipeline fill; latency = `ITERATIONS + 2` cycles; throughput = 1 vector/cycle. |
| FR-04 | **Configurable Saturation** | Saturating or wrap-around arithmetic selectable via configuration. |
| FR-05 | **K-Factor Prescaling** | Input vector automatically scaled by CORDIC gain `K ≈ 0.607252935` via a multiplier-free shift-add constant network (K_FACTOR = 2488/4096, 0.028% error vs. true K), eliminating post-processing multiplication. |
| FR-06 | **Simple Configuration** | Runtime configuration via `config_valid/ready` handshake (no AXI). |
| FR-07 | **Standard I/O Handshake** | Valid/ready handshake on input and output data interfaces. |

---

## 3. Non-Functional Requirements

| ID | Requirement | Target |
|----|-------------|--------|
| NFR-01 | **Synthesizability** | SystemVerilog (IEEE 1800-2012) ASIC-safe subset: `logic`, `always_ff`/`always_comb`, `package`, `typedef`, `$clog2`, SVA. No `interface`, `class`, or dynamic constructs in synthesized RTL. |
| NFR-02 | **Timing Closure** | Zero setup/hold violations at target frequency (measured post-synthesis). |
| NFR-03 | **Area Budget** | < 50k gate equivalents (post-synthesis estimate). |
| NFR-04 | **Power Intent** | Single voltage domain; clock gating enabled on pipeline registers (UPF V2.0). |
| NFR-05 | **CDC** | None in V1 (single clock domain). |
| NFR-06 | **Reset Strategy** | Active-low synchronous reset globally; no asynchronous resets in datapath. |
| NFR-07 | **Verification Coverage** | Statement >95%, Branch >90%, Toggle >85%, FSM 100%. |
| NFR-08 | **Formal Verification** | Key assertions proven (bounded model check): overflow freedom, valid/ready protocol, x²+y² invariant. |
| NFR-09 | **Documentation** | All interfaces, parameters, and behaviors documented in this specification suite. |
| NFR-10 | **Reproducibility** | `make sim`, `make synth`, `make sta` produce deterministic results. |

---

## 4. Supported Features (V1)

| Feature | Description |
|---------|-------------|
| **Rotation Mode** | Sine/cosine generation, vector rotation by angles in ≈ [−1.74, +1.74] rad (~±99.5°). No quadrant folding in V1. |
| **Parameterized Datapath** | `WIDTH`, `FRACT_W`, `ITERATIONS` as elaboration-time parameters. |
| **Pipelined Datapath** | `ITERATIONS` stages + input/output registers. |
| **Fixed Per-Stage Shifts** | Shift amount hardwired per stage (eliminates barrel shifter). |
| **LUT-Based Angle Table** | Combinational `atan(2⁻ⁱ)` for `i = 0..ITERATIONS-1`. |
| **Shift-Add Constant K-Factor Prescaling** | Input vector pre-multiplied by `K ≈ 2488/4096` via a multiplier-free shift-add network. See ADR-0005. |
| **Saturating Arithmetic** | Selectable per configuration. |
| **Valid/Ready Handshake** | Backpressure support on input and output. |

---

## 5. Explicitly Unsupported Features (V1)

| Feature | Deferred To | Reason |
|---------|-------------|--------|
| **Full ±π Angle Range** | V2.0 | Requires quadrant folding pre-stage (detect quadrant, fold z into ±π/2, negate x when needed). Adds 1 cycle pre-processing. |
| **Vectoring Mode** (atan2, magnitude) | V2.0 | Adds mode MUX in critical path; separate convergence behavior. |
| **Hyperbolic Mode** (sinh, cosh, sqrt, ln, exp) | V2.0 | Requires repeated iterations (4, 13); different datapath. |
| **Runtime K-Factor Multiplication** | V2.1 | V1 uses shift-add constant K-prescaling; a general multiplier adds latency/area. |
| **AXI-Lite Configuration** | V2.2 | Protocol compliance risk; simple handshake sufficient for V1. |
| **AXI-Stream Data Interfaces** | V2.2 | Valid/ready handshake sufficient for V1 verification. |
| **Dynamic Iteration Count** | V2.0 | Fixed at elaboration in V1; simplifies pipeline control. |
| **Multi-Precision (24/32-bit)** | V2.1 | Parameterizable but only 16-bit verified in V1. |
| **Matrix/Vector Operations** | V2.3 | Robotics Accelerator scope. |
| **Coordinate Transforms** | V2.4 | Robotics Accelerator scope. |
| **Inverse Kinematics** | V2.4 | Robotics Accelerator scope. |

---

## 6. Inputs / Outputs

### 6.1 Top-Level Ports (`cordic_top`)

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| `clk` | Input | 1 | Rising-edge clock |
| `rst_n` | Input | 1 | Active-low synchronous reset |
| `x_in` | Input | `WIDTH` | X input (fixed-point) |
| `y_in` | Input | `WIDTH` | Y input (fixed-point) |
| `z_in` | Input | `WIDTH` | Z input (angle, fixed-point) |
| `valid_in` | Input | 1 | Input data valid |
| `ready_out` | Output | 1 | Ready to accept input |
| `cfg` | Input | `cordic_cfg_t` | Configuration struct |
| `config_valid` | Input | 1 | Configuration valid |
| `config_ready` | Output | 1 | Ready for configuration |
| `x_out` | Output | `WIDTH` | X output (fixed-point) |
| `y_out` | Output | `WIDTH` | Y output (fixed-point) |
| `z_out` | Output | `WIDTH` | Z output (residual angle ≈ 0) |
| `valid_out` | Output | 1 | Output data valid |
| `ready_in` | Input | 1 | Downstream ready |
| `overflow` | Output | 1 | Saturation occurred |
| `irq` | Output | 1 | Interrupt (pipeline done) |

---

## 7. Performance Requirements

| Metric | Target | Notes |
|--------|--------|-------|
| **Throughput** | 1 vector/cycle | After pipeline fill |
| **Latency** | `ITERATIONS + 2` cycles | Default: 10 cycles (8 iterations + 1 input reg + 1 output reg) |
| **Numerical Accuracy** | ≤ 0.1° angle error | 8 iterations, 16-bit, Q12 format |
| **Gain Accuracy** | < 0.1% K-factor error | Shift-add K-prescaling: K = 2488/4096, 0.028% vs. true K; within spec NFR-05 |
| **Fmax** | Measured post-synthesis | No fixed target; design for correct timing at reasonable frequency |
| **Area** | < 50k GE | Post-synthesis estimate |
| **Pipeline Fill** | `ITERATIONS + 2` cycles | First valid output |

---

## 8. Latency Analysis

```
Cycle 0:    Input register (x_in, y_in, z_in) + K-prescale (shift-add, combinational)
Cycle 1:    Stage 0 (shift by 0, add/sub)
Cycle 2:    Stage 1 (shift by 1, add/sub)
...
Cycle N:    Stage N-1 (shift by N-1, add/sub)
Cycle N+1:  Output register
```

**Total Latency = ITERATIONS + 2 cycles** (input reg + N stages + output reg)

---

## 9. Throughput Analysis

| Scenario | Throughput |
|----------|------------|
| Continuous back-to-back | 1 vector/cycle |
| With backpressure (ready_in = 0) | Stalls at pipeline output; input ready deasserts after 1 cycle |
| Configuration update | 1 cycle (config handshake) |

---

## 10. Numerical Accuracy Requirements

| Parameter | Requirement | Verification Method |
|-----------|-------------|---------------------|
| **Angle Error (Rotation)** | ≤ 0.1° max for `|z_in| ≤ 1.74 rad` | Co-simulation vs Python golden model (10k random vectors within convergence zone) |
| **Magnitude Preservation** | `|x_out|² + |y_out|² ≈ K²(|x_in|² + |y_in|²)` | Formal invariant: x²+y² preserved within rounding |
| **K-Factor Error** | < 0.1% | Shift-add K-prescaling verified by full 65,536-value sweep (`cordic_lut_tb`) |
| **Saturation Correctness** | No wraparound when enabled | Directed tests at min/max boundaries |
| **Rounding Error** | Convergent rounding | Verified vs golden model |

---

## 11. Acceptance Criteria (Gate 4 — Tape-Out)

| Criterion | Pass Condition |
|-----------|----------------|
| **Synthesis** | `yosys` / vendor synthesis completes without errors |
| **STA** | Zero setup/hold violations at target clock; slack > 0 |
| **DRC/LVS** | Clean on post-synthesis netlist (or post-P&R if flow supports) |
| **Area** | < 50k GE reported |
| **Functional** | All regression tests pass (10k random + directed) |
| **Coverage** | Merged coverage > 95% statement, > 90% branch |
| **Formal** | Key assertions proven (bounded) |
| **Documentation** | All spec documents versioned and consistent |

---

## 12. Traceability Matrix

| Spec Section | Verification Method | Gate |
|--------------|---------------------|------|
| FR-01..FR-07 | Unit TB + Integration TB + Golden Co-sim | Gates 1-4 |
| NFR-01 | Lint check (`verilator --lint-only`) | Gate 0 |
| NFR-02 | STA sign-off | Gate 4 |
| NFR-03 | Area report | Gate 4 |
| NFR-04 | UPF lint + power-aware sim | Gate 4 |
| NFR-07 | Coverage merge report | Gate 4 |
| NFR-08 | SymbiYosys prove | Gate 0, 2 |

---

**End of SPECIFICATION.md**  
*This document is the single source of truth for V1 functional and non-functional requirements. All downstream documents (microarchitecture, interfaces, verification) derive from this.*