# WORKLOAD_ANALYSIS.md — Synthetic Workload Definitions

**Branch:** `wt-workload`  
**Freeze Tag:** `wave0-freeze`  
**Date:** 2026-10-10  
**Golden model only. No RTL edits. No flow runs.**  
**PRNG Seed:** `0xB17E` (45438) — same as canonical `V_rand` set.

> [!NOTE]
> Both workloads are **[SYNTHETIC]**. They model representative DSP
> transaction streams from published algorithm structure, not from real
> hardware or production data. Error budgets and mode policies are
> **[ASSUMPTION]** unless explicitly marked as measured.
>
> **Error measurement:** Uses `phase0/generalized_model.py`
> `GeneralizedCordicModel(FRACT_W=12, use_correct_k=False)` — bit-exact
> to the frozen RTL at ITERATIONS=8 and extended to arbitrary n. Error
> is `hypot(xo/scale - x_ideal, yo/scale - y_ideal)` exactly matching
> `phase0/sweep.py` lines 110–117. Reproduces PROGRESS.md §2a/§1b values.

---

## 0. Iteration Error Table (n=3..13, N_MAX=11)

Source: `PROGRESS.md` §2a (n=3..8), §1b extended sweep (n=8..13).
**N_MAX=11**: ITERATIONS=12 fails timing at 15 ns (Phase 0c measured).

| n | RMS error | Max error | Notes |
|---|-----------|-----------|-------|
| 3 | 0.15800 | 0.45100 |  |
| 4 | 0.08200 | 0.21600 |  |
| 5 | 0.04000 | 0.11100 |  |
| 6 | 0.02200 | 0.05600 |  |
| 7 | 0.01000 | 0.02800 |  |
| 8 | 0.00528 | 0.01382 | baseline |
| 9 | 0.00276 | 0.00862 |  |
| 10 | 0.00148 | 0.00466 |  |
| 11 | 0.00086 | 0.00277 | **← N_MAX ceiling** |
| 12 | 0.00063 | 0.00178 | *(above N_MAX — not usable)* |
| 13 | 0.00057 | 0.00131 | *(above N_MAX — not usable)* |

---

## 1. WL_FFT — FFT Twiddle Rotation Stream [SYNTHETIC]

### 1.1 Justification

> **[SYNTHETIC]** — FFT twiddle-factor butterfly kernel, N=512, one DIF stage.  
> An N=512 FFT for audio/comm DSP needs ~7-bit sine accuracy (≈40 dBc SNR);
> RMS rotation error ≤0.010 normalised is ample for 8-bit output resolution.
> Twiddle rotations are **stateless** (no inter-sample error accumulation),
> making this workload naturally tolerant of per-transaction mode adaptation.

### 1.2 Error Budget

| Metric | Budget | Basis |
|--------|--------|-------|
| **RMS error** | **≤ 0.010** (normalised, per tx) | 7-bit sine equiv; 40 dBc SNR |
| Max error | ≤ 0.05 (soft) | No hard constraint |

### 1.3 Smallest n Meeting Budget (RMS ≤ 0.010, from n=3..11 table)

| n | RMS | Meets ≤ 0.010? |
|---|-----|---------------|
| 3 | 0.15800 | ✗ |
| 4 | 0.08200 | ✗ |
| 5 | 0.04000 | ✗ |
| 6 | 0.02200 | ✗ |
| 7 | 0.01000 | ✓ **← smallest n** |
| 8 | 0.00528 | ✓ |
| 9 | 0.00276 | ✓ |
| 10 | 0.00148 | ✓ |
| 11 | 0.00086 | ✓ |

**Smallest n meeting RMS ≤ 0.010: n=8** (RMS=0.00528, ×1.9 margin).  
n=7 (RMS=0.010) is on the boundary; n=8 provides comfortable margin.

### 1.4 Mode Policy [ASSUMPTION]

| Twiddle class | Condition | n selected | Basis |
|---|---|---|---|
| Identity | k=0, angle=0 | **3** | Cheapest; zero rotation is exact for any n |
| Small-angle | \|k\| < N/16, \|θ\| < π/16 | **6** | Low-energy twiddles; RMS=0.022 (above budget for these txs in isolation) |
| Remaining | \|k\| ≥ N/16 | **8** | RMS=0.00528 ≤ budget with margin |

> [!IMPORTANT]
> **[ASSUMPTION]** The n=6 assignment for the small-angle class relaxes
> precision beyond the 0.010 RMS budget for those 15 transactions.
> The policy assumes the system SNR is dominated by large-angle twiddles
> (n=8, 75.0% of work) and that n=6 error on |k|<N/16 is acceptable.
> Requires verification against actual per-bin SNR measurements.

### 1.5 Mode-Occupancy Histogram

Total transactions: **64**  (N=256 FFT first quadrant, 64 twiddles)

| n | Count | Fraction | Table RMS |
|---|-------|----------|-----------|
| 3 | 1 | 1.6% | 0.15800 |
| 6 | 15 | 23.4% | 0.02200 |
| 8 | 48 | 75.0% | 0.00528 |

**Measured workload RMS error:** 0.006312 (budget ≤0.010 — PASS ✓)  
**Measured workload max error:** 0.022459 (soft ≤0.05)

### 1.6 Adaptation Benefit

Transactions at sub-N_MAX n: **16** of 64 (**25.0%** of workload).

Under B1 gating, these transactions leave stages beyond their selected n idle:
- n=3 tx: stages 4–11 gated (8 of 11 stages inactive)
- n=6 tx: stages 7–11 gated (5 of 11 stages inactive)

**WL_FFT benefits significantly from B1 adaptation**: 25.0% of transactions
run at sub-max n, providing proportional switching-power reduction on gated stages.

---

## 2. WL_NCO — NCO Phase-Accumulator Rotation Stream [SYNTHETIC]

### 2.1 Justification

> **[SYNTHETIC]** — NCO: continuous-phase sinusoid by rotating unit phasor
> by fixed Δφ = 2π×5/512 each cycle (carrier = 5/512 of Fs, N=512 samples).  
> Phase error accumulates across samples: a per-sample max error of ≤0.003
> normalised maintains ~60 dBc SFDR in narrowband comm receivers. This
> budget is **hard** — it applies to every compute sample without exception.

### 2.2 Error Budget

| Metric | Budget | Basis |
|--------|--------|-------|
| **Max error** | **≤ 0.003** (normalised, per sample, hard) | ~60 dBc SFDR; error accumulates |
| RMS error | ≤ 0.001 (implied) | Consistent with n=11 table values |

### 2.3 Smallest n Meeting Budget (max ≤ 0.003, from n=3..11 table)

| n | Max error | Meets ≤ 0.003? |
|---|-----------|---------------|
| 3 | 0.45100 | ✗ |
| 4 | 0.21600 | ✗ |
| 5 | 0.11100 | ✗ |
| 6 | 0.05600 | ✗ |
| 7 | 0.02800 | ✗ |
| 8 | 0.01382 | ✗ |
| 9 | 0.00862 | ✗ |
| 10 | 0.00466 | ✗ |
| 11 | 0.00277 | ✓ **← smallest n** |

**Smallest n meeting max ≤ 0.003: n=11** (max=0.00277).  
n=10 fails (max=0.00466 > 0.003). n=11 = N_MAX — no slack above.

> [!CAUTION]
> n=12 gives max=0.00178, n=13 gives 0.00131 — but N_MAX=11.
> The strict workload is simultaneously budget-limited and hardware-ceiling-limited.

### 2.4 Mode Policy [ASSUMPTION]

| Transaction class | Condition | n selected | Basis |
|---|---|---|---|
| SYNC/INIT | First tx only; angle=0 | **3** | Identity rotation; zero error for any n |
| NCO compute | All rotation steps (N−1 txs) | **11** | Forced by hard max-error budget |

> [!IMPORTANT]
> **[ASSUMPTION]** n=11 for all compute transactions is forced by the hard
> budget — not a design choice. No mode-selection logic can reduce n here.

### 2.5 Mode-Occupancy Histogram

Total transactions: **512**  (N=512 NCO phasor stream)

| n | Count | Fraction | Table max |
|---|-------|----------|-----------|
| 3 | 1 | 0.2% | 0.45100 |
| 11 | 511 | 99.8% | 0.00277 |

**Measured workload RMS error:** 0.000710 (implied ≤0.001 — PASS ✓)  
**Measured workload max error:** 0.001482 (hard ≤0.003 — PASS ✓)

### 2.6 Where the Strict Workload Gets No Benefit from Adaptation

> [!CAUTION]
> **WL_NCO provides near-zero adaptation benefit from B1 power gating.**

The hard max-error budget forces **all compute transactions to n=11**
(511/512 = 99.8% of workload).

Three independent reasons adaptation fails to help:

1. **No angle-class variation.** All NCO compute steps rotate by the *same*
   fixed Δφ. There is no 'small-angle' class or 'identity' class among
   compute transactions where fewer iterations would suffice.

2. **n=10 fails the hard budget at all angles.** MAX_TABLE[10]=0.00466 > 0.003.
   This is a property of the CORDIC algorithm at n=10, not of any specific
   input angle or magnitude. No sub-population of the NCO stream can safely
   use n=10.

3. **One SYNC transaction only.** The single n=3 SYNC pulse contributes
   1/512 = 0.2% of total transactions.
   Even at maximum savings (8 gated stages for 1 cycle), this is negligible.

**Conclusion:** For continuous-phase NCO workloads with a hard per-sample
max-error constraint, the B1 adaptive scheme provides **essentially zero**
dynamic power reduction vs a fixed n=11 implementation. The savings
opportunity is bounded by the single SYNC pulse per stream.

---

## 3. Trace File Hashes

| File | Transactions | SHA256 | Size (bytes) |
|------|-------------|--------|-------------|
| `vectors/wl_fft_trace.raw` | 64 | `f399dabc9bfd1cba96868c988a727fd72430fb3d2eaa078c03d1b2c35805b1b7` | 1776 |
| `vectors/wl_nco_trace.raw` | 512 | `068d2d63c76bcd78219c9761fa5f815fb6480145bbbe92edee0716d816a4f752` | 13426 |

*(Also recorded in `vectors/MANIFEST.md` §3.)*

---

## 4. Comparative Summary

| Property | WL_FFT | WL_NCO |
|----------|--------|--------|
| Application | FFT twiddle (N=512, 1 stage) | NCO phasor (N=512 samples) |
| **[SYNTHETIC]** | ✓ | ✓ |
| Tolerance class | **Precision-tolerant** | **Strict** |
| Error budget | RMS ≤ 0.010 | Max ≤ 0.003 (hard) |
| Measured RMS | 0.006312 | 0.000710 |
| Measured max | 0.022459 | 0.001482 |
| Min n (budget) | n=8 (RMS) | n=11 (max = N_MAX) |
| Modes used | n ∈ {3, 6, 8} | n ∈ {3, 11} |
| Total transactions | 64 | 512 |
| Sub-N_MAX fraction | 25% (n=3,6) | 0.2% (n=3 only) |
| B1 adaptation benefit | **High** (25% gated) | **Negligible** (0.2% gated) |

---
*Generated by `vectors/gen_workload_traces.py` on `wt-workload` branch.  
No RTL edits. No flow runs. Golden model only.*
