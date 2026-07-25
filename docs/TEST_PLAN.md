# CORDIC Accelerator — TEST_PLAN.md

**Project:** Parameterized Fixed-Point Pipelined CORDIC Accelerator (V1)  
**Document Version:** 1.0  
**Status:** APPROVED — Single Source of Truth  
**Derived From:** `VERIFICATION_PLAN.md`, `SPECIFICATION.md`

---

## 1. Test Organization

| Test Level | Directory | Trigger | Scope |
|------------|-----------|---------|-------|
| **Unit** | `tb/*_tb.sv` | Pre-commit, Gate 1-2 | Single module |
| **Integration** | `tb/cordic_pipeline_tb.sv` | Gate 2-3 | Module combinations |
| **System** | `tb/cordic_tb.sv` | Gate 4, Nightly | Full top-level |
| **Formal** | `tb/formal/` | Gate 0, 2 | Property proofs |
| **Regression** | `tb/` (all) | Nightly, Pre-tapeout | Full suite |

---

## 2. Directed Tests (Per Module)

### 2.1 `fp_add_sub` Tests

| Test ID | Description | Inputs | Expected |
|---------|-------------|--------|----------|
| FP_ADD_001 | Basic add | a=100, b=200, op=0, sat=1 | result=300, ovf=0 |
| FP_ADD_002 | Basic sub | a=500, b=200, op=1, sat=1 | result=300, ovf=0 |
| FP_ADD_003 | Saturation max | a=MAX, b=1, op=0, sat=1 | result=MAX, ovf=1 |
| FP_ADD_004 | Saturation min | a=MIN, b=-1, op=0, sat=1 | result=MIN, ovf=1 |
| FP_ADD_005 | Wrap mode | a=MAX, b=1, op=0, sat=0 | result=MIN, ovf=1 |
| FP_ADD_006 | Zero operands | a=0, b=0, op=0, sat=1 | result=0, ovf=0 |
| FP_ADD_007 | Negative add | a=-100, b=-200, op=0, sat=1 | result=-300, ovf=0 |
| FP_ADD_008 | Sign change | a=MAX, b=MIN, op=0, sat=1 | result=-1, ovf=0 |
| FP_ADD_009 | Max negative | a=MIN, b=0, op=1, sat=1 | result=MAX, ovf=1 |
| FP_ADD_010 | Overflow flag accuracy | Random + check | ovf=1 iff sat clamped |

### 2.2 `cordic_lut` Tests

| Test ID | Description | Input | Expected |
|---------|-------------|-------|----------|
| LUT_001 | Angle i=0 | stage_idx=0 | atan(1) = π/4 |
| LUT_002 | Angle i=1 | stage_idx=1 | atan(0.5) |
| LUT_003 | Angle i=7 | stage_idx=7 | atan(2⁻⁷) |
| LUT_004 | All 8 angles | stage_idx=0..7 | Match Python golden ±1 LSB |
| LUT_005 | K-prescale index 0 | k_lut_idx=0 | K × (-8.0) |
| LUT_006 | K-prescale index 8 | k_lut_idx=8 | K × (0.0) |
| LUT_007 | K-prescale index 15 | k_lut_idx=15 | K × (7.5) |
| LUT_008 | All 16 K-indices | k_lut_idx=0..15 | Match golden ±1 LSB |
| LUT_009 | Combinational | Toggle inputs | No glitches (sim) |

### 2.3 `cordic_stage` Tests

| Test ID | Description | Input | Expected |
|---------|-------------|-------|----------|
| STG_001 | Stage 0 rotation | x=1/K, y=0, z=atan(1), i=0 | x≈cos(π/4), y≈sin(π/4), z≈0 |
| STG_002 | Stage 1 rotation | x=cos(π/4), y=sin(π/4), z=atan(0.5), i=1 | z≈0 |
| STG_003 | All 8 stages chain | x=1/K, y=0, z=θ | x=Kcos(θ), y=Ksin(θ), z≈0 |
| STG_004 | Negative angle | x=1/K, y=0, z=-π/4, i=0 | y negative |
| STG_005 | Saturation in stage | x=MAX, y=MAX, z=0, i=0 | saturated, ovf=1 |
| STG_006 | Invariant x²+y² | Random x,y,z | |x²+y² - K²(x₀²+y₀²)| < 2 LSB |
| STG_007 | Valid pipeline | valid_in pulse | valid_out 1 cycle later |
| STG_008 | Stage index hardwired | Each instance fixed i | Correct shift amount |

### 2.4 `cordic_pipeline` Tests

| Test ID | Description | Input | Expected |
|---------|-------------|-------|----------|
| PIP_001 | Sin/Cos 0° | x=1/K, y=0, z=0 | x≈1, y≈0 |
| PIP_002 | Sin/Cos 45° | x=1/K, y=0, z=π/4 | x≈y≈0.707 |
| PIP_003 | Sin/Cos 90° | x=1/K, y=0, z=π/2 | x≈0, y≈1 |
| PIP_004 | Sin/Cos 180° | x=1/K, y=0, z=π | x≈-1, y≈0 |
| PIP_005 | Random vector | 100 random (x,y,z) | Match golden < 0.15° |
| PIP_006 | Back-to-back | 10 vectors continuous | valid_out every cycle |
| PIP_007 | Backpressure 1-cycle | ready_in=0 for 1 cycle | ready_out deasserts 1 cycle later |
| PIP_008 | Backpressure 5-cycle | ready_in=0 for 5 cycles | Pipeline stalls correctly |
| PIP_009 | Config handshake | config_valid pulse | config_ready next cycle |
| PIP_010 | Config applies next | Change ITERATIONS | Next vector uses new config |

### 2.5 `cordic_top` Tests

| Test ID | Description | Input | Expected |
|---------|-------------|-------|----------|
| TOP_001 | Full flow | x=1/K, y=0, z=π/4 | x≈y≈0.707, valid_out, irq |
| TOP_002 | Reset recovery | Assert rst_n during run | Clean restart |
| TOP_003 | Overflow flag | x=MAX, y=MAX, z=0 | overflow=1 |
| TOP_004 | Config + Data | Config then data | Config applies |
| TOP_005 | IRQ pulse | Any valid_out | irq=1 for 1 cycle |

---

## 3. Random Tests

### 3.1 Generation Strategy
```python
# tb/generate_random_tests.py
import random
random.seed(0xC0RD1C)  # Reproducible

def generate_random_vectors(count=10000):
    vectors = []
    for _ in range(count):
        x = random.randint(-32768, 32767)
        y = random.randint(-32768, 32767)
        z = random.randint(-32768, 32767)  # Full range
        saturate = random.choice([0, 1])
        vectors.append({'x': x, 'y': y, 'z': z, 'saturate': saturate})
    return vectors
```

### 3.2 Random Test Suites

| Suite | Count | Modules Tested | Pass Criteria |
|-------|-------|----------------|---------------|
| **Random Unit Adder** | 10,000 | `fp_add_sub` | Match golden (sat/wrap) |
| **Random Unit LUT** | 100 | `cordic_lut` | Match golden ±1 LSB |
| **Random Stage** | 1,000 | `cordic_stage` | Match golden, invariant |
| **Random Pipeline** | 10,000 | `cordic_pipeline` | Match golden < 0.15° |
| **Random Top** | 10,000 | `cordic_top` | Match golden, protocol |

---

## 4. Corner Case Tests

| Corner | Tested In | Description |
|--------|-----------|-------------|
| **Zero Vector** | All | x=0, y=0, any z |
| **Max Positive** | All | x=MAX, y=MAX, z=0 |
| **Max Negative** | All | x=MIN, y=MIN, z=0 |
| **Max Angle** | Pipeline, Top | z=±π, ±2π |
| **Subnormal** | Pipeline | x,y < 2⁻¹² (rounds to 0) |
| **Alternating Signs** | Adder, Stage | x=MAX, y=MIN, etc. |
| **Config Mid-Flight** | Pipeline | Config change between vectors |
| **Reset During Valid** | Top | rst_n asserted while valid_in=1 |
| **Ready In Oscillation** | Pipeline | ready_in toggles every cycle |

---

## 5. Stress Tests

| Stress Test | Duration | Condition | Monitor |
|-------------|----------|-----------|---------|
| **Throughput Max** | 1M cycles | valid_in=1, ready_in=1 | valid_out every cycle |
| **Backpressure Burst** | 100k cycles | ready_in random 0/1 | No data loss |
| **Config Storm** | 10k cycles | config_valid every 10 cycles | All configs applied |
| **Reset Storm** | 1k cycles | rst_n random pulses | Clean recovery |
| **Corner Vector Storm** | 100k cycles | Only corner cases | No overflow miss |

---

## 6. Error Injection Tests

| Error Type | Injection Point | Expected Detection |
|------------|-----------------|---------------------|
| **Bit Flip Input** | x_in, y_in, z_in | Output mismatch vs golden |
| **Bit Flip Internal** | Stage registers | Assertion fire (formal) |
| **Valid/Ready Protocol Violation** | valid_in without ready_out | Assertion fire |
| **Config Protocol Violation** | config_valid without ready | Assertion fire |
| **Overflow Missed** | Force adder overflow | overflow flag asserted |

---

## 7. Regression Checklist (Gate 4)

### 7.1 Pre-Regression
- [ ] All RTL lint clean (`make lint`)
- [ ] All formal proofs pass (`make formal`)
- [ ] Golden model updated to match RTL parameters
- [ ] Test vectors generated with fixed seed

### 7.2 Regression Execution
- [ ] `make sim_unit_fp_add_sub` — PASS
- [ ] `make sim_unit_cordic_lut` — PASS
- [ ] `make sim_unit_cordic_stage` — PASS
- [ ] `make sim_integration` — PASS
- [ ] `make sim_regression` — PASS (10k vectors)
- [ ] `make coverage_merge` — Stmt>95%, Branch>90%, Toggle>85%, FSM=100%

### 7.3 Post-Regression
- [ ] Coverage report reviewed
- [ ] Any uncovered code justified or tested
- [ ] Timing report (STA) attached
- [ ] Area report attached
- [ ] Power report attached
- [ ] All logs archived

### 7.4 Sign-Off
| Role | Name | Signature | Date |
|------|------|-----------|------|
| Lead Verification | | | |
| Technical Lead | | | |
| Principal Architect | | | |

---

## 8. Test Vector Format (JSON)

```json
{
  "test_suite": "regression_10k",
  "seed": 0xC0RD1C,
  "count": 10000,
  "vectors": [
    {
      "id": 0,
      "x_in": 2048,
      "y_in": 0,
      "z_in": 3217,
      "cfg_iterations": 8,
      "cfg_saturate": 1,
      "expected": {
        "x_out": 1450,
        "y_out": 1450,
        "z_out": 3,
        "overflow": 0
      }
    }
  ]
}
```

---

## 9. Test Environment Variables

| Variable | Values | Purpose |
|----------|--------|---------|
| `SEED` | Integer | Random test seed |
| `TEST_SUITE` | unit/integration/regression | Select test group |
| `COVERAGE` | 1/0 | Enable coverage |
| `ASSERT_ON` | 1/0 | Enable SVA in RTL |
| `VERBOSE` | 1/0 | Verbose simulation output |

---

## 10. CI Integration (GitHub Actions / GitLab CI)

```yaml
# .github/workflows/verify.yml
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: make lint
  
  unit_test:
    needs: lint
    runs-on: ubuntu-latest
    strategy:
      matrix:
        module: [fp_add_sub, cordic_lut, cordic_stage]
    steps:
      - run: make sim_unit_${{ matrix.module }}
  
  integration_test:
    needs: unit_test
    runs-on: ubuntu-latest
    steps:
      - run: make sim_integration
  
  regression:
    needs: integration_test
    runs-on: ubuntu-latest
    steps:
      - run: make sim_regression
      - run: make coverage_merge
      - run: make sta
```

---

**End of TEST_PLAN.md**  
*All tests traceable to SPECIFICATION.md requirements. No ad-hoc tests without test ID.*