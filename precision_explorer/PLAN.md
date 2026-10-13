# Adaptive-11 Precision Explorer — Implementation Plan

**Objective:** Build a reproducible experiment harness for the frozen Adaptive-11 CORDIC candidate (`6eb0de2`) to measure numerical accuracy across iteration modes 1–11 against the Fixed-11 reference.

---

## 1. Existing Infrastructure Reused

1. **Reference Model & Golden Outputs:**
   - **File:** `tb/golden_model.py` (`CordicGoldenModel`)
   - **Vector File:** `phase0/vectors/bitexact_check_iter11.mem` (920 canonical vectors: 120 directed + 800 random with seed `0xB17E`).
   - **Rationale:** `bitexact_check_iter11.mem` provides identical input vectors $(x_i, y_i, z_i, sat_i)$ and the bit-exact Fixed-11 reference outputs $(x_{11}, y_{11}, z_{11}, ovf_{11})$. `CordicGoldenModel(iterations=11)` provides bit-exact validation.

2. **RTL Testbench Architecture:**
   - **File:** `tb/adaptive_equiv_tb.sv`
   - **Rationale:** Demonstrates verified Verilator-compatible stimulus driving for `cordic_top`, cycle-accurate handshake protocols, and multi-mode sequential testing.

3. **Plotting Pattern:**
   - **File:** `phase0/sweep.py`
   - **Rationale:** Dependency-free Python SVG generation (`svg_line_chart`) to generate high-resolution, vector-graphics error curves without requiring external pip dependencies.

---

## 2. Precision Explorer Architecture

```
precision_explorer/
├── PLAN.md                     # This architecture plan
├── adaptive_precision_tb.sv    # SystemVerilog RTL simulation harness for cordic_top
├── precision_explorer.py       # Python metric engine, CSV & Markdown report & SVG generator
├── test_precision_explorer.py  # Harness self-test suite (metrics, monotonicity, schema)
├── run_explorer.sh             # Documented single command to regenerate all artifacts
├── precision_metrics.csv       # Machine-readable per-mode metrics
├── PRECISION_REPORT.md         # Comprehensive experiment report
└── precision_error_curves.svg  # Error vs Mode plot (MaxAbs & RMS, log scale)
```

---

## 3. Metric Definitions

For each mode $N \in [1, 11]$ across $M = 920$ vectors:
- **Bit-Exact Match Count:** Count of vectors where $x_{out} == x_{11} \land y_{out} == y_{11} \land z_{out} == z_{11}$.
- **Mismatch Count:** $M - \text{Bit-Exact Match Count}$.
- **Absolute Error (LSBs):**
  $$e_x[i] = |x_{out}[i] - x_{11}[i]|, \quad e_y[i] = |y_{out}[i] - y_{11}[i]|, \quad e_z[i] = |z_{out}[i] - z_{11}[i]|$$
- **Max Absolute Error:** $\text{MaxAbs}_v = \max_{i} e_v[i]$ (in LSBs and Q3.12 real: $\text{LSB}/4096$).
- **RMS Error:** $\text{RMS}_v = \sqrt{\frac{1}{M} \sum_{i=0}^{M-1} (e_v[i])^2}$ (in LSBs and Q3.12 real: $\text{LSB}/4096$).

---

## 4. Separation of Latency & Throughput

- **Latency:** Dedicated test confirms the fixed 12-cycle unstalled latency (`ITERATIONS + 1`) across all modes.
- **Throughput:** Separate burst admission test measures the credit reservation bubble (12 admissions per 13 cycles = 92.3%) without altering production RTL.
- Latency and throughput figures are maintained strictly separate from numerical precision metrics.
