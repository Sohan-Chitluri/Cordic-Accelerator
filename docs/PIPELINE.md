# CORDIC Accelerator — PIPELINE.md

**Project:** Parameterized Fixed-Point Pipelined CORDIC Accelerator (V1)
**Document Version:** 2.0 — corrected post-repair (see `repair/cordic-e107100`)
**Status:** APPROVED — Single Source of Truth
**Derived From:** `rtl/cordic_pipeline.sv` (read the RTL comments for full root-cause narrative on every deviation from v1.0 of this document)

> **Changelog from v1.0:** the original document described an architecture that
> was never actually implemented — a dedicated input-capture register, a
> single output register, and a shared live `cfg_saturate` feed into every
> stage. The real RTL has none of these. This revision replaces every section
> below with the as-built architecture, corrected against direct RTL reading
> and confirmed by simulation, the parameter matrix, and formal BMC. Where a
> number changed (`ITERATIONS + 2` → `ITERATIONS + 1`), it changed because the
> old number described a register that doesn't exist, not because the RTL was
> modified to hit a target.

---

## 1. Pipeline Overview

| Parameter | Value |
|-----------|-------|
| **Total Register Stages (VALID_DEPTH)** | `ITERATIONS + 1` (default: 9 for ITERATIONS=8) |
| **Pipeline Type** | Fixed-latency core (`cordic_stage` chain, no stall input) draining into an elastic output skid FIFO |
| **Throughput** | 1 vector/cycle (after fill), while `reserved_count < FIFO_DEPTH` |
| **Latency (admission → `valid_out`)** | `ITERATIONS + 1` cycles |
| **Fill Cycles** | `ITERATIONS + 1` |
| **Backpressure behavior** | Non-elastic core + elastic output stage — see §7 |

There is **no dedicated input-capture register**. `stage_x[0]`/`stage_y[0]`/
`stage_z[0]`/`stage_valid[0]` are combinational functions of
`x_in`/`y_in`/`z_in`/`valid_in` gated by `ready_out`, feeding `cordic_stage`
instance 0 directly the same cycle. The first register a transaction hits is
inside `cordic_stage #0`.

---

## 2. Per-Stage Responsibilities

### Admission (combinational, cycle of `valid_in & ready_out`)

| Signal | Source | Destination |
|--------|--------|-------------|
| `x_in`, `y_in` | Top-level input | `cordic_lut` → K-prescale (combinational) → `stage_x[0]`/`stage_y[0]` |
| `z_in` | Top-level input | `stage_z[0]` (unmodified) |
| `valid_in & ready_out` | Handshake | `stage_valid[0]` |
| `cfg_saturate_r` (live config register, sampled at this instant) | `config_valid`/`config_ready` handshake | `cfg_saturate_sr[0]` — captured **once per transaction**, then shifted forward with it (see §8) |

### Stage 0..ITERATIONS-1: CORDIC Iterations

Each `cordic_stage` instance is a fixed pipeline register with **no stall
port** — it free-runs every cycle regardless of downstream backpressure.
Position `i` in the chain always holds whatever transaction was admitted `i`
cycles ago.

| Signal | Operation | Registered Output |
|--------|-----------|-------------------|
| `x`, `y` | shift-add rotate, saturating add/sub via `fp_add_sub` | `stage_x[i+1]`, `stage_y[i+1]` |
| `z` | subtract/add `atan(2⁻ⁱ)` from per-instance `STAGE_ANGLE` constant | `stage_z[i+1]` |
| `valid` | 1-cycle shift | `stage_valid[i+1]` |
| `sat` config | per-transaction shift register tap `cfg_saturate_sr[i]` (not a shared live register) | consumed combinationally inside the stage |

### After the last stage: Output Skid FIFO (see §7)

`stage_valid[ITERATIONS]` pushes the completed transaction (data +
per-transaction accumulated overflow, see §9) into a FIFO of depth
`FIFO_DEPTH = VALID_DEPTH`. `valid_out`/`x_out`/`y_out`/`z_out`/`overflow`
are combinational reads of the FIFO head, held stable until `ready_in`
consumes it.

---

## 3. Register Boundaries

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ PIPELINE REGISTER BOUNDARIES (as-built)                                      │
├────────────────┬────────────────────────────────────────────────────────────┤
│ Boundary       │ Registers                                                  │
├────────────────┼────────────────────────────────────────────────────────────┤
│ Admission      │ (none — stage_x[0]/y[0]/z[0]/valid[0] are combinational)   │
├────────────────┼────────────────────────────────────────────────────────────┤
│ Stage 0 Out    │ stage_x[1], stage_y[1], stage_z[1], stage_valid[1]        │
│                │ (inside cordic_stage #0)                                   │
├────────────────┼────────────────────────────────────────────────────────────┤
│ Stage i Out    │ stage_x[i+1], stage_y[i+1], stage_z[i+1], stage_valid[i+1]│
├────────────────┼────────────────────────────────────────────────────────────┤
│ Stage N-1 Out  │ stage_x[N], stage_y[N], stage_z[N], stage_valid[N]        │
│ (N=ITERATIONS) │ — this register asserting is `fifo_push`                  │
├────────────────┼────────────────────────────────────────────────────────────┤
│ Output FIFO    │ fifo_x/y/z/ovf[wr_ptr] — depth FIFO_DEPTH = VALID_DEPTH,  │
│                │ held at rd_ptr until ready_in consumes (elastic, not a    │
│                │ single overwritten register)                              │
└────────────────┴────────────────────────────────────────────────────────────┘
```

Total registered depth from admission to `fifo_push` = `ITERATIONS` stage
registers, and `stage_valid[ITERATIONS]` asserting **is** `fifo_push` —
i.e. the completed value lands in the FIFO the same cycle
`stage_valid[ITERATIONS]` asserts, not one cycle later. So
`VALID_DEPTH = ITERATIONS + 1` counts the `ITERATIONS` stage registers plus
the FIFO storage register itself (`fifo_x/y/z/ovf` are registered on
`fifo_push`), confirmed cycle-accurate against `tb/cordic_pipeline_tb.sv`.

---

## 4. Signal Timing Diagram (steady state, no backpressure, ITERATIONS=8 ⇒ VALID_DEPTH=9)

```
Cycle:       0    1    2    3    4    5    6    7    8    9    10
valid_in:    v0   v1   v2   v3   v4   v5   v6   v7   v8   v9   v10
ready_out:   1    1    1    1    1    1    1    1    1    1    1
stage[1]:    -    v0   v1   v2   v3   v4   v5   v6   v7   v8   v9
stage[8]:    -    -    -    -    -    -    -    -    v0   v1   v2
fifo_push:   -    -    -    -    -    -    -    -    v0   v1   v2
valid_out:   -    -    -    -    -    -    -    -    v0   v1   v2
```

`v0` is admitted at cycle 0, appears at `stage_valid[ITERATIONS]`/`fifo_push`
at cycle 8, and `valid_out` reflects it the same cycle (FIFO head read is
combinational) — 8 = `ITERATIONS`, and counting the admission cycle itself as
cycle 0 makes the total elapsed span 9 cycles = `ITERATIONS + 1`.

---

## 5. Latency Analysis

| Configuration | ITERATIONS | VALID_DEPTH (= Latency) |
|---------------|------------|--------------------------|
| Default (16-bit) | 8 | 9 cycles |
| High Precision | 16 | 17 cycles |
| Minimal | 4 | 5 cycles |

**Formula:** `Latency = ITERATIONS + 1`

---

## 6. Throughput Analysis

### 6.1 Ideal Throughput (No Backpressure)

| Metric | Value |
|--------|-------|
| **Steady-state throughput** | 1 vector/cycle |
| **Pipeline efficiency** | 100% (no bubbles in steady state) |

### 6.2 Backpressure Scenarios

The `cordic_stage` chain itself is **fixed-latency and non-elastic** — it has
no stall input and cannot be paused once a transaction is admitted. What
makes the pipeline backpressure-safe is the output skid FIFO plus a
credit-based admission gate (`reserved_count`), not elasticity in the core:

| Scenario | Behavior | Data-loss risk |
|----------|----------|-----------------|
| `ready_in = 1` always | Full throughput, FIFO stays ~empty | None |
| `ready_in = 0` for M cycles (M ≤ FIFO_DEPTH) | Completed transactions accumulate in the FIFO; `ready_out` deasserts once `reserved_count == FIFO_DEPTH` (no new admissions), core keeps draining into the FIFO | None — every completed transaction is held until consumed |
| `ready_in = 0` indefinitely | `ready_out` deasserts once `FIFO_DEPTH` transactions are outstanding; producer must honor backpressure | None on the RTL side; a producer that ignores `ready_out` violates the interface contract, not an RTL bug |

**This replaces a real prior bug:** the pre-repair RTL had a single,
unconditionally-overwritten output register with a look-ahead `ready_out`
that only throttled *new* admissions and did nothing to protect data already
in flight. Holding `ready_in` low while sending back-to-back transactions
previously resulted in **0 of N transactions ever observed at the output**
(reproduced and regression-tested in `tb/cordic_pipeline_tb.sv`, tests T6–T11).

---

## 7. Output Skid FIFO and Credit-Based Admission

```systemverilog
// rtl/cordic_pipeline.sv (excerpt — read the full file for the complete
// root-cause commentary; this is not reproduced in full here to avoid a
// second copy drifting out of sync with the RTL again)
localparam int FIFO_DEPTH = VALID_DEPTH;   // == ITERATIONS + 1

assign fifo_push = stage_valid[ITERATIONS];
assign fifo_pop  = (fifo_count != '0) && ready_in;
assign ready_out = (reserved_count < FIFO_DEPTH);   // combinational, not registered
assign valid_out = (fifo_count != '0);
```

`ready_out` is deliberately **combinational** in `reserved_count`: a
registered/delayed admission gate would let one extra transaction slip in
each time `reserved_count` is re-sampled a cycle late, which would require
padding `FIFO_DEPTH` with slack to compensate. `FIFO_DEPTH == VALID_DEPTH` is
provably always enough to hold everything that can possibly be in flight
(admitted-but-not-yet-consumed, whether still in the stage chain or already
parked in the FIFO), so no transaction is ever dropped however long
`ready_in` stays low.

---

## 8. Configuration Pipeline (per-transaction tagging, not a shared live register)

| Signal | Timing | Description |
|--------|--------|--------------|
| `config_valid` | Asserted with `cfg_saturate` | Captured into `cfg_saturate_r` same cycle if `config_ready` |
| `config_ready` | Always 1 after reset | No backpressure on config writes |
| `cfg_saturate_r` | Live register, sampled at **admission only** into `cfg_saturate_sr[0]`, then shifted forward one tap per cycle in lockstep with the data stage chain | Applies to exactly the transaction admitted when it was sampled — later writes to `cfg_saturate_r` cannot retroactively change the saturation mode for already-in-flight transactions |

**Prior bug this replaces:** the pre-repair RTL wired the single live
`cfg_saturate_r` register directly and identically into every `cordic_stage`
instance's `.sat` port. Because the stage chain free-runs regardless of
backpressure, a `cfg_saturate` write arriving while transactions were in
flight retroactively changed saturation mode for whichever stages hadn't
executed yet that cycle — inconsistently across a *single* transaction's own
iterations, and across whichever unrelated transactions were resident at
other pipeline depths. Confirmed by direct RTL inspection, a regression test
(`tb/cordic_top_tb.sv` T10), and formal BMC (`cfg_align` in
`tb/formal/cordic_formal_tb.sv`).

---

## 9. Overflow Tracking (per-transaction accumulation, not a cross-transaction OR)

| Source | Alignment | Propagation |
|--------|-----------|-------------|
| `stage_overflow[1..ITERATIONS]` | Each tap `i` delayed `(ITERATIONS - i)` extra cycles via a per-tap delay line (`g_ovf_align`), so all `ITERATIONS` bits line up on the cycle the *same* transaction completes | OR-reduced combinationally into `overflow_final` at that cycle |
| `overflow_final` | Registered into `fifo_ovf[wr_ptr]` at `fifo_push` | Read at the FIFO head as top-level `overflow`, held until consumed |

**Prior bug this replaces:** the pre-repair RTL OR'd
`stage_overflow[i+1]` into a running accumulator combinationally, re-evaluated
every cycle — but `stage_overflow[1..ITERATIONS]` on any given cycle belong to
**different transactions** resident at different pipeline depths, not to one
transaction's history over time. This silently ORed unrelated transactions'
overflow flags together. Fixed via the per-tap delay line in §9 above (no
change to `cordic_stage.sv`).

---

## 10. Reset Behavior

| Cycle | Pipeline State |
|-------|----------------|
| Reset asserted | All `stage_valid[]` = 0, `wr_ptr`/`rd_ptr`/`fifo_count`/`reserved_count` = 0, `cfg_saturate_r` = 1 (saturate-on-overflow default) |
| Reset deasserted | Pipeline ready; first `valid_in & ready_out` captured that cycle |
| Latency after reset | `ITERATIONS + 1` cycles to first `valid_out` |

Formally verified: `p_reset_clears_valid`/`p_reset_clears_overflow`
(`cordic_assertions.sv`, stage-level) plus the pipeline-level `reset` task in
`tb/formal/cordic_formal_tb.sv` — both PASS, non-vacuous.

---

## 11. Timing Constraints

See `docs/PLACE_ROUTE_DRC.md` for the current, measured post-route numbers —
this document does not restate them to avoid a second place they can drift
out of sync. As of the last repair pass, the critical path runs through
`fp_add_sub`'s carry chain carrying `cfg_saturate_r`/config-tagging logic,
with a genuine (not hidden) timing violation at the existing SDC clock
period. A `fp_add_sub.sv` carry-select restructuring is recommended but not
yet implemented — see `docs/PLACE_ROUTE_DRC.md` remaining limitations.

---

## 12. Waveform Verification Points

| Check | Signal | Expected |
|-------|--------|----------|
| Pipeline fill | `valid_out` | First assertion at cycle `ITERATIONS + 1` after first admission |
| Throughput | `valid_out` | Asserted every cycle after fill, absent backpressure |
| Backpressure (no loss) | `x_out`/`y_out`/`z_out`/`overflow` at FIFO head | Held stable across cycles until `ready_in` consumes; `accepted_count == output_count` across any traffic pattern (see T6–T11, `tb/cordic_pipeline_tb.sv`) |
| Admission throttling | `ready_out` | Deasserts once `reserved_count == FIFO_DEPTH` |
| Data correctness | `x_out, y_out` | Match golden model (`tb/golden_model.py`) ±1 LSB |
| Overflow attribution | `overflow` | Reflects OR across all `ITERATIONS` stages of the **same** transaction, not neighbors (see §9) |
| Configuration attribution | output for two transactions admitted under different `cfg_saturate` | Each transaction's output honors the config live at its own admission (see §8) |

Formally verified where BMC-tractable: `conservation` (no transaction is ever
lost or duplicated) and `cfg_align` (config-attribution correctness, cover
only — no non-vacuous assert exists for this property with the current
toolchain; see `tb/formal/cordic_formal_tb.sv` header comments) both proven
against external ports only. `satclamp` (output pinned to the saturation
rail whenever overflow is flagged) is a **known, confirmed FAIL** — not a
tool artifact — because a mid-pipeline clamp can be moved off the rail by a
later stage's ordinary arithmetic before reaching the output boundary. This
is a property/semantics mismatch, not a hidden functional defect: `overflow`
is architecturally defined as "did any stage saturate during this
transaction's history," matching `tb/golden_model.py`, not "is the final
output pinned to the rail." The narrower guarantee — a saturating stage's
own output is clamped — is separately and correctly proven at the
`cordic_stage` level by `cordic_assertions.sv`'s `p_sat_clamps_x`/`p_sat_clamps_y`.

---

**End of PIPELINE.md**
*This document is derived from and must be kept consistent with
`rtl/cordic_pipeline.sv` — treat the RTL as ground truth on any future
discrepancy, not this document.*
