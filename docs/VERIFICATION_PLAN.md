# CORDIC Accelerator — VERIFICATION_PLAN.md

**Project:** Parameterized Fixed-Point Pipelined CORDIC Accelerator (V1)  
**Document Version:** 1.0  
**Status:** APPROVED — Single Source of Truth  
**Derived From:** `SPECIFICATION.md`, `MICROARCHITECTURE.md`, `INTERFACE_SPECIFICATION.md`

---

## 1. Verification Strategy Overview

| Level | Scope | Method | Tools | Gate |
|-------|-------|--------|-------|------|
| **Unit** | Individual modules | Directed + Random + Formal | Verilator, SymbiYosys | 1, 2 |
| **Integration** | Module combinations | Co-simulation + Assertions | Verilator + Python | 2, 3 |
| **System** | Full pipeline + top | Regression + Coverage | Verilator + Coverage Merge | 4 |
| **Formal** | Critical properties | Bounded Model Checking | SymbiYosys | 0, 2 |
| **STA** | Timing closure | Static Timing Analysis | OpenSTA / Vendor | 4 |

---

## 2. Unit Verification (Gates 1, 2)

### 2.1 Module: `fp_add_sub` (Agent-A)

| Test Category | Test Cases | Method | Coverage Target |
|---------------|------------|--------|-----------------|
| **Basic Add** | Random a,b with op=0 | Random (10k) | Statement 100% |
| **Basic Sub** | Random a,b with op=1 | Random (10k) | Branch 100% |
| **Saturation** | MAX+MAX, MIN+MIN, MAX-MIN | Directed | Toggle 95% |
| **Overflow Flag** | Verify overflow=1 exactly when sat | Assertion | FSM 100% |
| **Corner Cases** | 0, ±MAX, ±1, alternating signs | Directed | |
| **Formal Equiv** | vs Ripple-carry adder | SymbiYosys prove | |

**Formal Properties:**
```systemverilog
// sat mode: |result| <= MAX_POS
// wrap mode: result == a + b (mod 2^WIDTH)
// overflow asserted iff saturation occurred
```

### 2.2 Module: `cordic_lut` (Agent-B)

| Test Category | Test Cases | Method | Coverage Target |
|---------------|------------|--------|-----------------|
| **Angle LUT** | All 8 stage indices | Directed (8 cases) | Statement 100% |
| **K-Prescale** | All 16 LUT indices | Directed (16 cases) | Branch 100% |
| **Golden Match** | vs Python atan(2⁻ⁱ) & K×center | Co-sim | Toggle 90% |
| **Combinational** | No registers inferred | Lint + Synthesis | |

**Golden Reference:** `tb/golden_model.py` — pre-computed constants

### 2.3 Module: `cordic_stage` (Agent-C)

| Test Category | Test Cases | Method | Coverage Target |
|---------------|------------|--------|-----------------|
| **Known Angles** | Rotate by atan(2⁻ⁱ) for i=0..7 | Directed (8 cases) | Statement 100% |
| **Random Vectors** | 1000 random x,y,z | Random + Golden | Branch 95% |
| **Invariant** | x²+y² preserved (rotation) | Assertion + Formal | Toggle 90% |
| **Saturation** | Input near MAX_POS | Directed | FSM 100% |

**Formal Properties:**
```systemverilog
// x_out² + y_out² == x_in² + y_in² (within rounding)
// valid_out == valid_in (1-cycle latency)
// σ_i = sign(z_in) correctly implemented
```

### 2.4 Module: `cordic_pipeline` (Agent-D)

| Test Category | Test Cases | Method | Coverage Target |
|---------------|------------|--------|-----------------|
| **Sin/Cos Gen** | z_in = angle, x_in=1/K, y_in=0 | Directed (16 angles) | Statement 100% |
| **Random Vectors** | 10k random x,y,z | Co-sim vs Golden | Branch 95% |
| **Throughput** | Back-to-back valid_in | Directed | Toggle 90% |
| **Backpressure** | ready_in=0 patterns | Directed | FSM 100% |
| **Config** | config_valid handshake | Directed | |

---

## 3. Integration Verification (Gates 2, 3)

### 3.1 Stage + LUT + Adder Integration (Gate 2)

| Test | Description | Pass Criteria |
|------|-------------|---------------|
| **Stage 0 standalone** | `cordic_stage` with `cordic_lut` + `fp_add_sub` | Matches golden for stage 0 |
| **Stage chain (2)** | Stage 0 → Stage 1 connected | Matches 2-stage golden |
| **Stage chain (N)** | All N stages connected | Matches N-stage golden |

### 3.2 Pipeline Integration (Gate 3)

| Test | Description | Pass Criteria |
|------|-------------|---------------|
| **Full Pipeline** | `cordic_pipeline` with all stages | 10k random vectors vs golden |
| **Corner Angles** | 0, π/4, π/2, π, -π/4, -π/2 | Max error < 0.15° |
| **Throughput** | Continuous valid_in, ready_in=1 | valid_out every cycle after fill |
| **Backpressure** | ready_in random 0/1 | No data loss, protocol correct |
| **Config Change** | config_valid between vectors | New config applies correctly |

---

## 4. System Verification (Gate 4)

### 4.1 Top-Level Regression

| Test Suite | Size | Method | Pass Criteria |
|------------|------|--------|---------------|
| **Directed** | 50 cases | Verilator | All pass |
| **Random** | 10,000 vectors | Verilator + Golden | Max error < 0.15° |
| **Backpressure** | 100 patterns | Verilator | No protocol violation |
| **Config** | 20 sequences | Verilator | Config applies correctly |
| **Reset** | 5 scenarios | Verilator | Clean recovery |
| **Overflow** | 10 corner cases | Verilator | Overflow flag correct |

### 4.2 Coverage Merge (Gate 4)

| Coverage Type | Target | Merge Method |
|---------------|--------|--------------|
| **Statement** | > 95% | `vcover merge` |
| **Branch** | > 90% | `vcover merge` |
| **Toggle** | > 85% | `vcover merge` |
| **FSM** | 100% | `vcover merge` |

**Coverage Database:** Per-module `.ucdb` merged at Gate 4.

---

## 5. Golden Model Strategy

### 5.1 Reference Implementation (`tb/golden_model.py`)

```python
# Bit-exact fixed-point CORDIC reference
def cordic_golden(x, y, z, iterations=8, fract_w=12, saturate=True):
    K = 0.6072529350088813
    MAX_POS = (1 << (15)) - 1
    MIN_NEG = -(1 << (15))
    
    # K-prescale (matches LUT)
    x = round(K * x)
    y = round(K * y)
    x = clamp(x, MIN_NEG, MAX_POS) if saturate else x & 0xFFFF
    y = clamp(y, MIN_NEG, MAX_POS) if saturate else y & 0xFFFF
    
    for i in range(iterations):
        sigma = 1 if z >= 0 else -1
        shift_x = arithmetic_shift_right(x, i, round=True)
        shift_y = arithmetic_shift_right(y, i, round=True)
        x_new = x - sigma * shift_y
        y_new = y + sigma * shift_x
        z_new = z - sigma * atan_lut[i]
        x, y, z = clamp(x_new), clamp(y_new), z_new
    
    return x, y, z
```

### 5.2 Co-Simulation Flow

```bash
# Verilator compiles DUT + C++ wrapper
# Python drives test vectors, compares results
# Mismatch → detailed diff with cycle accuracy
```

---

## 6. Assertion-Based Verification

### 6.1 Bindable Assertions (`rtl/common/cordic_assertions.sv`)

| Assertion | Module | Type | Description |
|-----------|--------|------|-------------|
| `p_reset_clears_valid` | `cordic_stage` | Reset | `!rst_n |=> !valid_out` |
| `p_reset_clears_overflow` | `cordic_stage` | Reset | `!rst_n |=> !overflow` |
| `p_sat_clamps_x` | `cordic_stage` | Safety | `sat && overflow |-> (x_out == MAX_POS || x_out == MIN_NEG)` |
| `p_sat_clamps_y` | `cordic_stage` | Safety | `sat && overflow |-> (y_out == MAX_POS || y_out == MIN_NEG)` |
| `p_valid_propagates` | `cordic_stage` | Protocol | `valid_in |=> valid_out` |

### 6.2 Formal Verification (SymbiYosys)

```yaml
# tb/formal/cordic_formal.sby
[options]
mode bmc
depth 20

[engines]
smtbmc z3

[script]
read -formal -DFORMAL rtl/pkg/cordic_pkg.sv
read -formal -DFORMAL rtl/fp_add_sub.sv
read -formal -DFORMAL rtl/cordic_stage.sv
read -formal -DFORMAL tb/formal/cordic_formal_tb.sv
prep -top cordic_formal_tb

[files]
rtl/pkg/cordic_pkg.sv
rtl/fp_add_sub.sv
rtl/cordic_stage.sv
tb/formal/cordic_formal_tb.sv
```

**Formal Properties Proven (BMC depth 20):**

| Property | Description | Status |
|----------|-------------|--------|
| **P4** | `sat && overflow && valid_out → x_out clamped` | ✅ PASS |
| **P5** | `sat && overflow && valid_out → y_out clamped` | ✅ PASS |
| **P6** | `rst_n && valid_out → x_out in range` | ✅ PASS |
| **P7** | `rst_n && valid_out → y_out in range` | ✅ PASS |

**Simulation-Verified Properties (via `cordic_assertions.sv` + `ASSERT_ON`):**

| Property | Description | Status |
|----------|-------------|--------|
| **P1** | Reset clears `valid_out` within 1 cycle | ✅ PASS (simulation) |
| **P2** | Reset clears `overflow` within 1 cycle | ✅ PASS (simulation) |
| **P3** | `valid_in` propagates to `valid_out` with 1-cycle latency | ✅ PASS (simulation) |

> **Note:** P1–P3 are verified by simulation testbenches (all 5 unit/integration TBs pass). The SVA `property...endproperty` syntax is not supported by Yosys 0.67, so they are not included in the formal BMC run. P4–P7 are proven by bounded model checking (depth 20) using Z3.

---

## 7. Verification Environment

### 7.1 Directory Structure

```
tb/
├── cordic_tb.sv              # Top-level testbench
├── fp_add_sub_tb.sv          # Unit TB
├── cordic_lut_tb.sv          # Unit TB
├── cordic_stage_tb.sv        # Unit TB
├── cordic_pipeline_tb.sv     # Integration TB
├── golden_model.py           # Python reference
├── test_vectors/
│   ├── directed.json         # Directed test cases
│   ├── random_10k.json       # 10k random vectors
│   └── corner_cases.json     # Overflow, max, zero
├── coverage/
│   └── merge.tcl             # Coverage merge script
└── formal/
    ├── cordic_assertions.sv  # SVA bind module
    └── config.sby            # SymbiYosys config
```

### 7.2 Make Targets

```makefile
# Simulation
make sim_unit_fp_add_sub      # Unit test fp_add_sub
make sim_unit_cordic_lut      # Unit test cordic_lut
make sim_unit_cordic_stage    # Unit test cordic_stage
make sim_integration          # Pipeline integration
make sim_regression           # Full regression (Gate 4)

# Coverage
make coverage_unit            # Per-module coverage
make coverage_merge           # Merge all (Gate 4)

# Formal
make formal_fp_add_sub        # Prove fp_add_sub assertions
make formal_cordic_stage      # Prove stage invariants

# Lint
make lint                     # Verilator lint all RTL
```

---

## 8. Coverage Goals

| Coverage Type | Target | Measurement |
|---------------|--------|-------------|
| **Statement** | > 95% | Every line executed |
| **Branch** | > 90% | Every if/else/case branch |
| **Toggle** | > 85% | Every signal 0→1 and 1→0 |
| **FSM** | 100% | All states, all transitions |
| **Assertion** | 100% pass | All SVA proven or covered |

---

## 9. Regression Strategy

| Trigger | Scope | Frequency |
|---------|-------|-----------|
| **Pre-commit** | Lint + Unit (changed module) | Every push |
| **Gate Review** | All unit + integration for wave | At each gate |
| **Nightly** | Full regression + coverage merge | Daily (CI) |
| **Pre-Tapeout** | Full regression + STA + DRC/LVS | Gate 4 |

---

## 10. Test Data Management

| Artifact | Format | Generated By |
|----------|--------|--------------|
| Directed tests | JSON | Manual (spec-driven) |
| Random vectors | JSON | Python script (seeded) |
| Golden outputs | JSON | Golden model |
| Coverage DB | UCDB | Verilator |
| Formal results | Log + VCD | SymbiYosys |

---

## 11. Pass/Fail Criteria per Gate

| Gate | Required Pass | Blocking Failures |
|------|---------------|-------------------|
| **Gate 0** | `cordic_pkg` compiles, lint clean, assertions bindable | Any compile error, lint error |
| **Gate 1** | `fp_add_sub` + `cordic_lut` unit tests pass, coverage >90% | Any unit test fail, coverage <90% |
| **Gate 2** | `cordic_stage` integration pass, formal proven | Golden mismatch, formal fail |
| **Gate 3** | `cordic_pipeline` 10k vectors pass, throughput verified | Any mismatch, throughput <1/cycle |
| **Gate 4** | Top regression pass, STA clean, coverage >95%, area <50k GE | Any fail |

---

**End of VERIFICATION_PLAN.md**  
*This plan is mandatory. All verification must follow this methodology.*