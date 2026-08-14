# CORDIC Accelerator — Parameterized Fixed-Point Pipelined CORDIC

**Target:** RTL→GDSII ASIC Flow (One Semester)  
**Status:** v0.1.0-bootstrap — Repository infrastructure complete, SystemVerilog RTL placeholders ready for agent implementation  
**Architecture:** Frozen (see `docs/adr/`)  
**Language:** SystemVerilog (IEEE 1800-2012) — ASIC-safe subset

---

## Project Overview

A parameterized fixed-point pipelined CORDIC accelerator implementing **rotation mode only** (sin/cos generation, vector rotation). Designed for industrial ASIC development practices with frozen interfaces, exclusive file ownership, and formal verification gates.

### Key Architecture Decisions (V1 Scope)

| Decision | Rationale |
|----------|-----------|
| **No multiplier** | Classical CORDIC rotation uses only shifts and adds |
| **Shift-add constant K-factor prescaling** | 0-cycle, zero multiplier, 0.028% K-error, full input precision (see ADR-0005) |
| **No AXI-Lite** | Simple valid/ready config handshake eliminates protocol compliance risk |
| **No fixed Fmax target** | Measure post-synthesis; design for correct-by-construction timing |
| **8 iterations (16-bit)** | Converges to <0.15°; halves pipeline depth vs 16 iterations |
| **Combinational angle LUTs** | `atan(2⁻ⁱ)` constants embedded per stage (distributed ROM), 0-cycle latency; K-factor via shift-add |
| **Fixed shift per stage** | Hardwired shift amount eliminates barrel shifter from critical path |
| **SystemVerilog 2012** | `logic`, `always_ff`/`always_comb`, packages, `$clog2`, SVA; full Yosys 0.13+/Verilator 5+ support |

---

## Repository Structure

```
cordic-accelerator-asic/
├── CORDIC_IMPLEMENTATION_TRACKER.md   # Master execution tracker (frozen gates)
├── Makefile                           # lint, sim, test, synth, sta, clean, coverage
├── .github/workflows/verify.yml       # CI: lint → build → test → coverage
├── .gitignore                         # Excludes build artifacts, VCD, coverage
├── .editorconfig                      # Consistent formatting across editors
├── README.md                          # This file
├── rtl/
│   ├── pkg/
│   │   └── cordic_pkg.sv              # Single source of truth: package, types, functions
│   ├── common/
│   │   └── cordic_assertions.sv       # Bindable SVA assertions
│   ├── fp_add_sub.sv                  # Carry-select saturating adder/subtractor (Agent: Arithmetic)
│   ├── cordic_lut.sv                  # K-factor prescaler (shift-add constant, Agent: Datapath)
│   ├── cordic_stage.sv                # Single CORDIC iteration (Agent: Datapath)
│   ├── cordic_pipeline.sv             # N-stage pipeline + valid/ready + config (Agent: Pipeline)
│   └── cordic_top.sv                  # Top-level I/O + config handshake (Agent: Integration)
├── tb/
│   ├── golden_model.py                # Bit-exact Python reference for co-simulation
│   ├── fp_add_sub_tb.sv               # Unit test: adder
│   ├── cordic_lut_tb.sv               # Unit test: LUTs
│   ├── cordic_stage_tb.sv             # Unit test: stage
│   ├── cordic_pipeline_tb.sv          # Integration test: pipeline
│   ├── cordic_top_tb.sv               # Regression test: top-level
│   ├── formal/                        # SymbiYosys configs
│   ├── test_vectors/                  # JSON test vectors
│   └── coverage/                      # Coverage merge scripts
├── constraints/
│   └── cordic.sdc                     # SDC template: clock, I/O delays, uncertainty
├── scripts/
│   ├── synth.tcl                      # Yosys synthesis script
│   ├── sta.tcl                        # OpenSTA script template
│   └── sim.py                         # Python simulation runner
├── docs/
│   ├── SPECIFICATION.md               # FR/NFR, I/O, performance, acceptance criteria
│   ├── MICROARCHITECTURE.md           # Datapath, pipeline, control, critical path
│   ├── PIPELINE.md                    # Per-stage timing, register boundaries, latency
│   ├── FIXED_POINT_ANALYSIS.md        # Q-format, K-factor, error budget, saturation
│   ├── INTERFACE_SPECIFICATION.md     # All signal descriptions, handshake timing
│   ├── RTL_CODING_GUIDELINES.md       # Naming, template, lint rules, reset policy
│   ├── VERIFICATION_PLAN.md           # Unit/integration/system/formal/STA strategy
│   ├── TEST_PLAN.md                   # Directed, random, corner, stress, error injection
│   ├── TIMING_BUDGET.md               # Critical path breakdown, STA methodology
│   ├── DESIGN_REQUIREMENTS.md         # Constraints, assumptions, success metrics
│   ├── architecture_review_decisions.md # Decision log with rationale
│   └── adr/                           # Architecture Decision Records
│       ├── ADR-0001-V1-Scope.md
│       ├── ADR-0002-No-Multiplier.md
│       ├── ADR-0003-No-AXI.md
│       ├── ADR-0004-Rotation-Only.md
│       └── ADR-0005-LUT-Prescaling.md
├── physical/                          # P&R outputs (V2+)
└── output/                            # Synthesis/STA reports (git-ignored)
```

---

## Quick Start

### Prerequisites

- **Verilator** ≥ 5.0 (simulation, lint)
- **Yosys** ≥ 0.13 (synthesis)
- **OpenSTA** ≥ 2.6 (static timing analysis)
- **SymbiYosys** + Z3 (formal verification)
- **Python** ≥ 3.9 (golden model, test vectors)
- **GNU Make** ≥ 4.0

```bash
# Ubuntu/Debian
sudo apt-get install verilator yosys opensta python3 python3-pip make g++

# SymbiYosys (formal)
pip3 install symbiyosys
# Requires Z3: sudo apt-get install z3
```

### Common Make Targets

```bash
# Lint only (fast, runs on every PR)
make lint

# Build and run top-level simulation
make sim
make sim-run

# Run all unit tests + golden model
make test

# Generate 10k random test vectors
make test-vectors

# Run simulation with coverage
make coverage

# Yosys synthesis (generic library)
make synth

# Static timing analysis (requires synthesized netlist)
make sta

# Formal verification (SymbiYosys)
make formal

# Full CI pipeline
make ci

# Clean all build artifacts
make clean
```

---

## Development Workflow

### Agent Roles & Ownership

| Agent | Discipline | Owned Files |
|-------|------------|-------------|
| **Architecture** (Lead) | Specification, ADRs, gate reviews | `docs/adr/`, `docs/SPECIFICATION.md`, `CORDIC_IMPLEMENTATION_TRACKER.md` |
| **Arithmetic RTL** | `fp_add_sub.sv` | `rtl/fp_add_sub.sv`, `tb/fp_add_sub_tb.sv` |
| **Datapath RTL** | `cordic_lut.sv`, `cordic_stage.sv` | `rtl/cordic_lut.sv`, `rtl/cordic_stage.sv`, corresponding TBs |
| **Pipeline RTL** | `cordic_pipeline.sv` | `rtl/cordic_pipeline.sv`, `tb/cordic_pipeline_tb.sv` |
| **Integration RTL** | `cordic_top.sv`, SDC, synthesis scripts | `rtl/cordic_top.sv`, `constraints/`, `scripts/` |
| **Verification** | Golden model, formal, coverage, CI | `tb/golden_model.py`, `tb/formal/`, `tb/coverage/`, `.github/workflows/` |
| **Documentation** | Specs, traceability, release notes | `docs/` (non-ADR), `CHANGELOG.md` |

### Branch & Merge Strategy

```bash
# Architecture freezes interfaces
git checkout -b wave0-foundation
# ... implement cordic_pkg.sv, cordic_assertions.sv
git commit -am "Wave 0: Foundation packages"
git tag wave0-frozen
git push origin wave0-frozen

# Parallel Wave 1
git checkout wave0-frozen
git checkout -b wave1-arith      # Arithmetic agent
git checkout -b wave1-datapath   # Datapath agent

# Sequential waves
# Wave 2: cordic_stage (depends on Wave 1)
# Wave 3: cordic_pipeline (depends on Wave 2)
# Wave 4: cordic_top (depends on Wave 3)
```

**Merge Rules:**
- No direct pushes to `main` — all changes via PR
- PR requires: lint clean, unit tests pass, coverage targets met, Lead approval
- Gates 0–4 are blocking — next wave cannot start until current gate passes
- Architecture Agent owns `cordic_pkg.sv` and `cordic_assertions.sv` exclusively

---

## Verification Strategy

| Level | Method | Tools | Gate |
|-------|--------|-------|------|
| **Unit** | Directed + random + formal equivalence | Verilator, SymbiYosys | Gates 1, 2 |
| **Integration** | Co-simulation with Python golden model | Verilator + pytest | Gate 3 |
| **System** | Regression (10k vectors), backpressure, config | Verilator | Gate 4 |
| **Formal** | SVA assertions: overflow, valid/ready, x²+y² invariant | SymbiYosys (BMC) | Gates 0, 2 |
| **STA** | Post-synthesis timing analysis | OpenSTA / vendor | Gate 4 |
| **CDC** | None in V1 (single clock domain) | — | — |

**Coverage Targets:** Statement >95%, Branch >90%, Toggle >85%, FSM 100%

**Golden Model:** Python `cordic_golden.py` — bit-exact fixed-point CORDIC reference for co-simulation

---

## Interface Contracts (Frozen)

All interfaces defined in `docs/INTERFACE_SPECIFICATION.md` and implemented in `rtl/pkg/cordic_pkg.sv`.

### Top-Level Ports (`cordic_top`)

| Signal | Dir | Width | Description |
|--------|-----|-------|-------------|
| `clk` | In | 1 | Rising-edge clock |
| `rst_n` | In | 1 | Active-low synchronous reset |
| `x_in`, `y_in`, `z_in` | In | `WIDTH` | Input vector (Q-format) |
| `valid_in` | In | 1 | Input data valid |
| `ready_out` | Out | 1 | Ready to accept input |
| `cfg_iterations` | In | 4 | Iteration count (1-16) |
| `cfg_saturate` | In | 1 | 1=saturate, 0=wrap |
| `config_valid` | In | 1 | Configuration valid |
| `config_ready` | Out | 1 | Ready for configuration |
| `x_out`, `y_out`, `z_out` | Out | `WIDTH` | Output vector |
| `valid_out` | Out | 1 | Output data valid |
| `ready_in` | In | 1 | Downstream ready |
| `overflow` | Out | 1 | Saturation occurred |
| `irq` | Out | 1 | Pipeline completion pulse |

---

## License

Proprietary — Internal ASIC Project

---

## Version

**v0.1.0-bootstrap** — Infrastructure complete, SystemVerilog RTL placeholders ready for agent implementation.  
Architecture frozen per ADR-0001 through ADR-0005.