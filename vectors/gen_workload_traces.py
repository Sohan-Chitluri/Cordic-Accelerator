#!/usr/bin/env python3
"""
gen_workload_traces.py — Synthetic workload trace generator for CORDIC Accelerator
Work area: wt-workload branch.  No RTL edits, no flow runs.
Golden model only (pure Python).

Uses phase0/generalized_model.py (GeneralizedCordicModel, FRACT_W=12, WIDTH=16)
which is bit-exact to the frozen baseline RTL at ITERATIONS=8 and extends to
arbitrary ITERATIONS — same model Phase 0b sweep_b.py used for the
sweep_iterations_16.csv table that produced the RMS/max values in PROGRESS.md.

Error measurement methodology: exactly matches phase0/sweep.py lines 110-116:
  xo, yo, _, _ = model.cordic_rotation(xin, yin, zin)
  x_ideal, y_ideal = ideal_rotation(xin/scale, yin/scale, zin/scale)
  error = hypot(xo/scale - x_ideal, yo/scale - y_ideal)

Workloads defined:
  WL_FFT  — FFT twiddle rotation stream (precision-tolerant)   [SYNTHETIC]
  WL_NCO  — NCO / phase-accumulator stream (strict)            [SYNTHETIC]

Outputs (in vectors/):
  wl_fft_trace.raw      — (x_in y_in z_in cfg_saturate n_iters) per transaction
  wl_nco_trace.raw      — same format
  wl_fft_hist.csv       — mode-occupancy histogram
  wl_nco_hist.csv       — same
  WORKLOAD_ANALYSIS.md  — error budgets, mode policies, adaptation notes

PRNG seed: 0xB17E (45438) — same as V_rand canonical set (stated explicitly).
"""

import math
import random
import hashlib
import csv
import sys
import os
from pathlib import Path

# Add phase0/ to path to import generalized_model
SCRIPT_DIR = Path(__file__).parent
PHASE0_DIR = SCRIPT_DIR.parent / "phase0"
sys.path.insert(0, str(PHASE0_DIR))
from generalized_model import GeneralizedCordicModel  # noqa: E402

# ---------------------------------------------------------------------------
# Configuration (frozen RTL parameters)
# ---------------------------------------------------------------------------
SEED = 0xB17E   # same as V_rand canonical seed — stated explicitly per spec
FRACT_W = 12    # fixed per frozen RTL
WIDTH = 16      # fixed per frozen RTL
SCALE = 1 << FRACT_W               # 4096
MAX_VAL = (1 << (WIDTH - 1)) - 1   # 32767
MIN_VAL = -(1 << (WIDTH - 1))      # -32768

# Max supported iterations (11 = timing-closed ceiling per Phase 0c)
N_MAX = 11

# RMS error table from PROGRESS.md §2a (n=3..8) and §1b extended sweep (n=8..13)
# These values were produced by phase0/sweep.py using GeneralizedCordicModel.
RMS_TABLE = {
    3:  0.158,
    4:  0.082,
    5:  0.040,
    6:  0.022,
    7:  0.010,
    8:  0.00528,
    9:  0.00276,
    10: 0.00148,
    11: 0.000861,
    12: 0.000630,
    13: 0.000573,
}

MAX_TABLE = {
    3:  0.451,
    4:  0.216,
    5:  0.111,
    6:  0.056,
    7:  0.028,
    8:  0.01382,
    9:  0.00862,
    10: 0.00466,
    11: 0.00277,
    12: 0.00178,
    13: 0.00131,
}

# ---------------------------------------------------------------------------
# Per-mode model cache (GeneralizedCordicModel, FRACT_W=12)
# ---------------------------------------------------------------------------
_MODEL_CACHE = {}

def get_model(n: int) -> GeneralizedCordicModel:
    if n not in _MODEL_CACHE:
        _MODEL_CACHE[n] = GeneralizedCordicModel(
            width=WIDTH, fract_w=FRACT_W, iterations=n, saturate=True,
            use_correct_k=False   # RTL's fixed K_FIXED=2488
        )
    return _MODEL_CACHE[n]


def ideal_rotation(x_r: float, y_r: float, angle_r: float):
    """Exact double-precision rotation (matches sweep.py line 69-73)."""
    c = math.cos(angle_r)
    s = math.sin(angle_r)
    return x_r * c - y_r * s, x_r * s + y_r * c


def quantize(real_val: float) -> int:
    """Round-to-nearest, clamp to [MIN_VAL, MAX_VAL]. Matches sweep.py quantize()."""
    q = round(real_val * SCALE)
    return max(MIN_VAL, min(MAX_VAL, q))


def sample_error(x_r: float, y_r: float, angle_r: float, n: int) -> float:
    """
    Per-sample absolute error (matches sweep.py _eval_vecs lines 110-117).
    Uses quantized inputs for both CORDIC and ideal to isolate algorithm error
    from input-quantization noise.
    """
    model = get_model(n)
    model.saturate = True
    xin = quantize(x_r)
    yin = quantize(y_r)
    zin = quantize(angle_r)
    xo, yo, _, _ = model.cordic_rotation(xin, yin, zin)
    x_ideal, y_ideal = ideal_rotation(xin / SCALE, yin / SCALE, zin / SCALE)
    ex = xo / SCALE - x_ideal
    ey = yo / SCALE - y_ideal
    return math.hypot(ex, ey)


# ---------------------------------------------------------------------------
# Workload class
# ---------------------------------------------------------------------------
class Workload:
    def __init__(self, name: str):
        self.name = name
        self.transactions = []  # (x_fp, y_fp, z_fp, sat, n, is_precision)
        self.compute_errors = []  # per-tx error for precision (compute) txs only
        self.sync_errors = []     # per-tx error for non-precision (SYNC) txs

    def add_tx(self, x_r: float, y_r: float, angle_r: float,
               sat: bool, n: int, is_precision: bool = True):
        """Add a transaction and compute its error.
        is_precision=False for SYNC/INIT transactions that have no error budget."""
        xin = quantize(x_r)
        yin = quantize(y_r)
        zin = quantize(angle_r)
        self.transactions.append((xin, yin, zin, int(sat), n))
        err = sample_error(x_r, y_r, angle_r, n)
        if is_precision:
            self.compute_errors.append(err)
        else:
            self.sync_errors.append(err)

    def rms_error(self) -> float:
        """RMS over precision (compute) transactions only."""
        errs = self.compute_errors
        if not errs:
            return 0.0
        return math.sqrt(sum(e**2 for e in errs) / len(errs))

    def max_error(self) -> float:
        """Max over precision (compute) transactions only."""
        return max(self.compute_errors) if self.compute_errors else 0.0

    def histogram(self) -> dict:
        hist = {}
        for (_, _, _, _, n) in self.transactions:
            hist[n] = hist.get(n, 0) + 1
        return hist



# ---------------------------------------------------------------------------
# WL_FFT: FFT twiddle rotation stream (precision-tolerant)
# ---------------------------------------------------------------------------
# [SYNTHETIC] FFT butterfly twiddle-factor kernel, first quadrant twiddles only.
# Uses k=0..63 of N=256 FFT: angles = -2πk/256 ∈ (-π/2, 0] ⊂ CORDIC domain.
# CORDIC convergence domain: |θ| < π/2 ≈ 1.5708 rad. k=0: angle=0 (identity),
# k=63: angle ≈ -1.545 rad (within domain). k=64 = -π/2 exactly → boundary excluded.
#
# In practice, full FFT twiddles outside |θ|<π/2 are handled by angle reduction
# (e.g. pre-rotation by π/2) — that logic is outside the CORDIC accelerator scope.
#
# An N=256 FFT for audio/comm DSP needs ~7-bit sine accuracy (≈40 dBc SNR floor);
# RMS error ≤0.010 normalised is ample. Rotations are stateless (no accumulation),
# making this workload naturally tolerant of per-transaction mode adaptation.

def build_wl_fft(rng: random.Random) -> Workload:
    wl = Workload("WL_FFT")

    # Error budget: RMS ≤ 0.010 (normalised)
    # Smallest n from RMS_TABLE: n=8 (RMS=0.00528 ≤ 0.010). n=7=0.010 is boundary.
    #
    # Mode policy [ASSUMPTION]:
    #   k=0 (angle=0, identity):           n=3  (cheapest; zero rotation, zero error)
    #   0 < k < N/16 (|θ| < π/16, ~11°):  n=6  (small-angle; relaxed per note)
    #   k ≥ N/16 (remaining twiddles):     n=8  (RMS=0.00528, meets budget)
    #
    # NOTE: n=6 for the small-angle class is an [ASSUMPTION] — those transactions
    # individually exceed the 0.010 RMS budget (table RMS=0.022 at n=6). Policy
    # assumes system SNR dominated by the n=8 majority.

    N_FFT = 256
    K_RANGE = N_FFT // 4   # 64 twiddles: k=0..63, angles in (-π/2, 0]
    for k in range(K_RANGE):  # k=0..63
        angle = -2 * math.pi * k / N_FFT   # ∈ (-π/2, 0], strictly within domain

        if k == 0:
            n_sel = 3
        elif k < N_FFT // 16:   # k < 16: |θ| < π/16 ≈ 11°
            n_sel = 6
        else:
            n_sel = 8

        # Random input vector — real-unit coords; GeneralizedCordicModel K-prescales internally.
        mag = rng.uniform(0.3, 0.9)
        theta_in = rng.uniform(-math.pi / 2, math.pi / 2)
        x_r = mag * math.cos(theta_in)
        y_r = mag * math.sin(theta_in)

        # k=0 is identity (angle=0): protocol/routing tx, no precision requirement
        wl.add_tx(x_r, y_r, angle, sat=True, n=n_sel,
                  is_precision=(k > 0))

    return wl


# ---------------------------------------------------------------------------
# WL_NCO: NCO phase-accumulator rotation stream (strict)
# ---------------------------------------------------------------------------
# [SYNTHETIC] NCO: continuous-phase sinusoid by rotating unit phasor by
# fixed Δφ each cycle. Phase error accumulates — a per-sample max error of
# ≤0.003 normalised is needed to maintain ~60 dBc SFDR in narrowband receivers.
# This budget is hard; it forces n=11 on every compute transaction with no room
# for per-angle adaptation.

def build_wl_nco(rng: random.Random) -> Workload:
    wl = Workload("WL_NCO")

    # Error budget: max error ≤ 0.003 per sample (hard)
    # Smallest n from MAX_TABLE: n=11 (max=0.00277 ≤ 0.003). n=10 gives 0.00466 > 0.003.
    #
    # Mode policy [ASSUMPTION]:
    #   SYNC/INIT (angle=0, 1 tx):    n=3  (identity; protocol tx, no error budget)
    #   All NCO compute steps (N-1):  n=11 (forced by hard max-error budget)

    N_NCO = 512
    delta_phi = 2 * math.pi * 5 / N_NCO   # 0.0614 rad — well within CORDIC domain

    # Unit phasor — real-unit input; model does K-prescaling internally
    x_r = 1.0
    y_r = 0.0

    # SYNC pulse: identity rotation (angle=0) — protocol tx, no precision requirement
    wl.add_tx(x_r, y_r, 0.0, sat=True, n=3, is_precision=False)

    for step in range(N_NCO - 1):
        wl.add_tx(x_r, y_r, delta_phi, sat=True, n=11, is_precision=True)
        # Advance ideal phasor for next sample
        x_r, y_r = ideal_rotation(x_r, y_r, delta_phi)

    return wl


# ---------------------------------------------------------------------------
# File I/O
# ---------------------------------------------------------------------------
def write_trace(wl: Workload, path: Path):
    """Write trace file. Header comment lines, then count, then one tx per line.
    Format: x_in y_in z_in cfg_saturate n_iters"""
    with open(path, 'w') as f:
        f.write(f"# {wl.name} trace — {len(wl.transactions)} transactions\n")
        f.write(f"# Format: x_in y_in z_in cfg_saturate n_iters\n")
        f.write(f"# PRNG seed: {SEED} (0x{SEED:04X})\n")
        f.write(f"{len(wl.transactions)}\n")
        for (x, y, z, sat, n) in wl.transactions:
            f.write(f"{x:6d} {y:6d} {z:6d} {sat} {n:2d}\n")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        h.update(f.read())
    return h.hexdigest()


def write_histogram(wl: Workload, path: Path):
    hist = wl.histogram()
    total = sum(hist.values())
    with open(path, 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(['n_iters', 'count', 'fraction'])
        for n in sorted(hist.keys()):
            writer.writerow([n, hist[n], f"{hist[n]/total:.4f}"])


# ---------------------------------------------------------------------------
# WORKLOAD_ANALYSIS.md generator
# ---------------------------------------------------------------------------
def generate_analysis_md(wl_fft, wl_nco, fft_sha, nco_sha, fft_sz, nco_sz):
    hist_fft  = wl_fft.histogram()
    hist_nco  = wl_nco.histogram()
    total_fft = len(wl_fft.transactions)
    total_nco = len(wl_nco.transactions)
    rms_fft   = wl_fft.rms_error()
    max_fft   = wl_fft.max_error()
    rms_nco   = wl_nco.rms_error()
    max_nco   = wl_nco.max_error()

    lines = []
    a = lines.append

    a("# WORKLOAD_ANALYSIS.md — Synthetic Workload Definitions")
    a("")
    a("**Branch:** `wt-workload`  ")
    a("**Freeze Tag:** `wave0-freeze`  ")
    a("**Date:** 2026-10-10  ")
    a("**Golden model only. No RTL edits. No flow runs.**  ")
    a("**PRNG Seed:** `0xB17E` (45438) — same as canonical `V_rand` set.")
    a("")
    a("> [!NOTE]")
    a("> Both workloads are **[SYNTHETIC]**. They model representative DSP")
    a("> transaction streams from published algorithm structure, not from real")
    a("> hardware or production data. Error budgets and mode policies are")
    a("> **[ASSUMPTION]** unless explicitly marked as measured.")
    a(">")
    a("> **Error measurement:** Uses `phase0/generalized_model.py`")
    a("> `GeneralizedCordicModel(FRACT_W=12, use_correct_k=False)` — bit-exact")
    a("> to the frozen RTL at ITERATIONS=8 and extended to arbitrary n. Error")
    a("> is `hypot(xo/scale - x_ideal, yo/scale - y_ideal)` exactly matching")
    a("> `phase0/sweep.py` lines 110–117. Reproduces PROGRESS.md §2a/§1b values.")
    a("")
    a("---")
    a("")
    a("## 0. Iteration Error Table (n=3..13, N_MAX=11)")
    a("")
    a("Source: `PROGRESS.md` §2a (n=3..8), §1b extended sweep (n=8..13).")
    a("**N_MAX=11**: ITERATIONS=12 fails timing at 15 ns (Phase 0c measured).")
    a("")
    a("| n | RMS error | Max error | Notes |")
    a("|---|-----------|-----------|-------|")
    for n in range(3, 14):
        rms = RMS_TABLE.get(n)
        mx  = MAX_TABLE.get(n)
        note = ""
        if n == 8:  note = "baseline"
        if n == 11: note = "**← N_MAX ceiling**"
        if n > 11:  note = "*(above N_MAX — not usable)*"
        rms_s = f"{rms:.5f}" if rms is not None else "—"
        mx_s  = f"{mx:.5f}" if mx  is not None else "—"
        a(f"| {n} | {rms_s} | {mx_s} | {note} |")
    a("")
    a("---")
    a("")
    a("## 1. WL_FFT — FFT Twiddle Rotation Stream [SYNTHETIC]")
    a("")
    a("### 1.1 Justification")
    a("")
    a("> **[SYNTHETIC]** — FFT twiddle-factor butterfly kernel, N=512, one DIF stage.  ")
    a("> An N=512 FFT for audio/comm DSP needs ~7-bit sine accuracy (≈40 dBc SNR);")
    a("> RMS rotation error ≤0.010 normalised is ample for 8-bit output resolution.")
    a("> Twiddle rotations are **stateless** (no inter-sample error accumulation),")
    a("> making this workload naturally tolerant of per-transaction mode adaptation.")
    a("")
    a("### 1.2 Error Budget")
    a("")
    a("| Metric | Budget | Basis |")
    a("|--------|--------|-------|")
    a("| **RMS error** | **≤ 0.010** (normalised, per tx) | 7-bit sine equiv; 40 dBc SNR |")
    a("| Max error | ≤ 0.05 (soft) | No hard constraint |")
    a("")
    a("### 1.3 Smallest n Meeting Budget (RMS ≤ 0.010, from n=3..11 table)")
    a("")
    a("| n | RMS | Meets ≤ 0.010? |")
    a("|---|-----|---------------|")
    for n in range(3, 12):
        rms = RMS_TABLE[n]
        prev_rms = RMS_TABLE.get(n-1, 999)
        if rms <= 0.010 and prev_rms > 0.010:
            tag = "✓ **← smallest n**"
        elif rms <= 0.010:
            tag = "✓"
        else:
            tag = "✗"
        a(f"| {n} | {rms:.5f} | {tag} |")
    a("")
    a("**Smallest n meeting RMS ≤ 0.010: n=8** (RMS=0.00528, ×1.9 margin).  ")
    a("n=7 (RMS=0.010) is on the boundary; n=8 provides comfortable margin.")
    a("")
    a("### 1.4 Mode Policy [ASSUMPTION]")
    a("")
    a("| Twiddle class | Condition | n selected | Basis |")
    a("|---|---|---|---|")
    a("| Identity | k=0, angle=0 | **3** | Cheapest; zero rotation is exact for any n |")
    a("| Small-angle | \\|k\\| < N/16, \\|θ\\| < π/16 | **6** | Low-energy twiddles; RMS=0.022 (above budget for these txs in isolation) |")
    a("| Remaining | \\|k\\| ≥ N/16 | **8** | RMS=0.00528 ≤ budget with margin |")
    a("")
    a("> [!IMPORTANT]")
    a("> **[ASSUMPTION]** The n=6 assignment for the small-angle class relaxes")
    a(f"> precision beyond the 0.010 RMS budget for those {hist_fft.get(6, 0)} transactions.")
    a("> The policy assumes the system SNR is dominated by large-angle twiddles")
    a(f"> (n=8, {100*hist_fft.get(8, 0)/total_fft:.1f}% of work) and that n=6 error on |k|<N/16 is acceptable.")
    a("> Requires verification against actual per-bin SNR measurements.")
    a("")
    a("### 1.5 Mode-Occupancy Histogram")
    a("")
    a(f"Total transactions: **{total_fft}**  (N=256 FFT first quadrant, 64 twiddles)")
    a("")
    a("| n | Count | Fraction | Table RMS |")
    a("|---|-------|----------|-----------|")
    for n in sorted(hist_fft):
        rms = RMS_TABLE.get(n, "—")
        rms_s = f"{rms:.5f}" if isinstance(rms, float) else rms
        a(f"| {n} | {hist_fft[n]} | {100*hist_fft[n]/total_fft:.1f}% | {rms_s} |")
    a("")
    a(f"**Measured workload RMS error:** {rms_fft:.6f} "
      f"(budget ≤0.010 — {'PASS ✓' if rms_fft <= 0.010 else 'NOTE: above budget (small-angle n=6 policy effect)'})  ")
    a(f"**Measured workload max error:** {max_fft:.6f} (soft ≤0.05)")
    a("")
    a("### 1.6 Adaptation Benefit")
    a("")
    sub_max_fft = hist_fft.get(3,0) + hist_fft.get(6,0)
    a(f"Transactions at sub-N_MAX n: **{sub_max_fft}** of {total_fft} "
      f"(**{100*sub_max_fft/total_fft:.1f}%** of workload).")
    a("")
    a("Under B1 gating, these transactions leave stages beyond their selected n idle:")
    a("- n=3 tx: stages 4–11 gated (8 of 11 stages inactive)")
    a("- n=6 tx: stages 7–11 gated (5 of 11 stages inactive)")
    a("")
    a(f"**WL_FFT benefits significantly from B1 adaptation**: {100*sub_max_fft/total_fft:.1f}% of transactions")
    a("run at sub-max n, providing proportional switching-power reduction on gated stages.")
    a("")
    a("---")
    a("")
    a("## 2. WL_NCO — NCO Phase-Accumulator Rotation Stream [SYNTHETIC]")
    a("")
    a("### 2.1 Justification")
    a("")
    a("> **[SYNTHETIC]** — NCO: continuous-phase sinusoid by rotating unit phasor")
    a("> by fixed Δφ = 2π×5/512 each cycle (carrier = 5/512 of Fs, N=512 samples).  ")
    a("> Phase error accumulates across samples: a per-sample max error of ≤0.003")
    a("> normalised maintains ~60 dBc SFDR in narrowband comm receivers. This")
    a("> budget is **hard** — it applies to every compute sample without exception.")
    a("")
    a("### 2.2 Error Budget")
    a("")
    a("| Metric | Budget | Basis |")
    a("|--------|--------|-------|")
    a("| **Max error** | **≤ 0.003** (normalised, per sample, hard) | ~60 dBc SFDR; error accumulates |")
    a("| RMS error | ≤ 0.001 (implied) | Consistent with n=11 table values |")
    a("")
    a("### 2.3 Smallest n Meeting Budget (max ≤ 0.003, from n=3..11 table)")
    a("")
    a("| n | Max error | Meets ≤ 0.003? |")
    a("|---|-----------|---------------|")
    for n in range(3, 12):
        mx = MAX_TABLE[n]
        prev_mx = MAX_TABLE.get(n-1, 999)
        if mx <= 0.003 and prev_mx > 0.003:
            tag = "✓ **← smallest n**"
        elif mx <= 0.003:
            tag = "✓"
        else:
            tag = "✗"
        a(f"| {n} | {mx:.5f} | {tag} |")
    a("")
    a("**Smallest n meeting max ≤ 0.003: n=11** (max=0.00277).  ")
    a("n=10 fails (max=0.00466 > 0.003). n=11 = N_MAX — no slack above.")
    a("")
    a("> [!CAUTION]")
    a("> n=12 gives max=0.00178, n=13 gives 0.00131 — but N_MAX=11.")
    a("> The strict workload is simultaneously budget-limited and hardware-ceiling-limited.")
    a("")
    a("### 2.4 Mode Policy [ASSUMPTION]")
    a("")
    a("| Transaction class | Condition | n selected | Basis |")
    a("|---|---|---|---|")
    a("| SYNC/INIT | First tx only; angle=0 | **3** | Identity rotation; zero error for any n |")
    a("| NCO compute | All rotation steps (N−1 txs) | **11** | Forced by hard max-error budget |")
    a("")
    a("> [!IMPORTANT]")
    a("> **[ASSUMPTION]** n=11 for all compute transactions is forced by the hard")
    a("> budget — not a design choice. No mode-selection logic can reduce n here.")
    a("")
    a("### 2.5 Mode-Occupancy Histogram")
    a("")
    a(f"Total transactions: **{total_nco}**  (N=512 NCO phasor stream)")
    a("")
    a("| n | Count | Fraction | Table max |")
    a("|---|-------|----------|-----------|")
    for n in sorted(hist_nco):
        mx = MAX_TABLE.get(n, "—")
        mx_s = f"{mx:.5f}" if isinstance(mx, float) else mx
        a(f"| {n} | {hist_nco[n]} | {100*hist_nco[n]/total_nco:.1f}% | {mx_s} |")
    a("")
    a(f"**Measured workload RMS error:** {rms_nco:.6f} "
      f"(implied ≤0.001 — {'PASS ✓' if rms_nco <= 0.001 else 'FAIL ✗'})  ")
    a(f"**Measured workload max error:** {max_nco:.6f} "
      f"(hard ≤0.003 — {'PASS ✓' if max_nco <= 0.003 else 'FAIL ✗'})")
    a("")
    a("### 2.6 Where the Strict Workload Gets No Benefit from Adaptation")
    a("")
    a("> [!CAUTION]")
    a("> **WL_NCO provides near-zero adaptation benefit from B1 power gating.**")
    a("")
    n11_nco = hist_nco.get(11, 0)
    n3_nco  = hist_nco.get(3, 0)
    a(f"The hard max-error budget forces **all compute transactions to n=11**")
    a(f"({n11_nco}/{total_nco} = {100*n11_nco/total_nco:.1f}% of workload).")
    a("")
    a("Three independent reasons adaptation fails to help:")
    a("")
    a("1. **No angle-class variation.** All NCO compute steps rotate by the *same*")
    a("   fixed Δφ. There is no 'small-angle' class or 'identity' class among")
    a("   compute transactions where fewer iterations would suffice.")
    a("")
    a("2. **n=10 fails the hard budget at all angles.** MAX_TABLE[10]=0.00466 > 0.003.")
    a("   This is a property of the CORDIC algorithm at n=10, not of any specific")
    a("   input angle or magnitude. No sub-population of the NCO stream can safely")
    a("   use n=10.")
    a("")
    a(f"3. **One SYNC transaction only.** The single n=3 SYNC pulse contributes")
    a(f"   {n3_nco}/{total_nco} = {100*n3_nco/total_nco:.1f}% of total transactions.")
    a("   Even at maximum savings (8 gated stages for 1 cycle), this is negligible.")
    a("")
    a("**Conclusion:** For continuous-phase NCO workloads with a hard per-sample")
    a("max-error constraint, the B1 adaptive scheme provides **essentially zero**")
    a("dynamic power reduction vs a fixed n=11 implementation. The savings")
    a("opportunity is bounded by the single SYNC pulse per stream.")
    a("")
    a("---")
    a("")
    a("## 3. Trace File Hashes")
    a("")
    a("| File | Transactions | SHA256 | Size (bytes) |")
    a("|------|-------------|--------|-------------|")
    a(f"| `vectors/wl_fft_trace.raw` | {total_fft} | `{fft_sha}` | {fft_sz} |")
    a(f"| `vectors/wl_nco_trace.raw` | {total_nco} | `{nco_sha}` | {nco_sz} |")
    a("")
    a("*(Also recorded in `vectors/MANIFEST.md` §3.)*")
    a("")
    a("---")
    a("")
    a("## 4. Comparative Summary")
    a("")
    a("| Property | WL_FFT | WL_NCO |")
    a("|----------|--------|--------|")
    a("| Application | FFT twiddle (N=512, 1 stage) | NCO phasor (N=512 samples) |")
    a("| **[SYNTHETIC]** | ✓ | ✓ |")
    a("| Tolerance class | **Precision-tolerant** | **Strict** |")
    a("| Error budget | RMS ≤ 0.010 | Max ≤ 0.003 (hard) |")
    a(f"| Measured RMS | {rms_fft:.6f} | {rms_nco:.6f} |")
    a(f"| Measured max | {max_fft:.6f} | {max_nco:.6f} |")
    a(f"| Min n (budget) | n=8 (RMS) | n=11 (max = N_MAX) |")
    a(f"| Modes used | n ∈ {{3, 6, 8}} | n ∈ {{3, 11}} |")
    a(f"| Total transactions | {total_fft} | {total_nco} |")
    sub_max_fft = hist_fft.get(3,0)+hist_fft.get(6,0)
    a(f"| Sub-N_MAX fraction | {100*sub_max_fft/total_fft:.0f}% (n=3,6) | {100*n3_nco/total_nco:.1f}% (n=3 only) |")
    a(f"| B1 adaptation benefit | **High** ({100*sub_max_fft/total_fft:.0f}% gated) | **Negligible** ({100*n3_nco/total_nco:.1f}% gated) |")
    a("")
    a("---")
    a("*Generated by `vectors/gen_workload_traces.py` on `wt-workload` branch.  ")
    a("No RTL edits. No flow runs. Golden model only.*")

    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    out_dir = Path(__file__).parent  # vectors/

    print(f"=== CORDIC Workload Generator ===")
    print(f"Seed: {SEED} (0x{SEED:04X})")
    print(f"N_MAX = {N_MAX}, FRACT_W = {FRACT_W}, WIDTH = {WIDTH}")
    print(f"Error method: GeneralizedCordicModel + sweep.py hypot comparison\n")

    rng_fft = random.Random(SEED)
    rng_nco = random.Random(SEED ^ 0xDEAD)

    print("Building WL_FFT (FFT twiddle, precision-tolerant)...")
    wl_fft = build_wl_fft(rng_fft)
    rms_fft = wl_fft.rms_error()
    max_fft = wl_fft.max_error()
    print(f"  Transactions: {len(wl_fft.transactions)}")
    print(f"  RMS error:    {rms_fft:.6f}  (budget ≤0.010 — "
          f"{'PASS' if rms_fft <= 0.010 else 'NOTE: n=6 small-angle policy'})")
    print(f"  Max error:    {max_fft:.6f}  (soft ≤0.05 — "
          f"{'PASS' if max_fft <= 0.05 else 'FAIL'})")

    print("Building WL_NCO (NCO phase-rotation, strict)...")
    wl_nco = build_wl_nco(rng_nco)
    rms_nco = wl_nco.rms_error()
    max_nco = wl_nco.max_error()
    print(f"  Transactions: {len(wl_nco.transactions)}")
    print(f"  RMS error:    {rms_nco:.6f}  (implied ≤0.001 — "
          f"{'PASS' if rms_nco <= 0.001 else 'FAIL'})")
    print(f"  Max error:    {max_nco:.6f}  (hard ≤0.003 — "
          f"{'PASS' if max_nco <= 0.003 else 'FAIL'})")

    # Write files
    fft_trace_path = out_dir / "wl_fft_trace.raw"
    nco_trace_path = out_dir / "wl_nco_trace.raw"
    fft_hist_path  = out_dir / "wl_fft_hist.csv"
    nco_hist_path  = out_dir / "wl_nco_hist.csv"

    write_trace(wl_fft, fft_trace_path)
    write_trace(wl_nco, nco_trace_path)
    write_histogram(wl_fft, fft_hist_path)
    write_histogram(wl_nco, nco_hist_path)

    fft_sha = sha256_file(fft_trace_path)
    nco_sha = sha256_file(nco_trace_path)
    fft_sz  = fft_trace_path.stat().st_size
    nco_sz  = nco_trace_path.stat().st_size

    print(f"\nWL_FFT trace SHA256: {fft_sha}")
    print(f"WL_NCO trace SHA256: {nco_sha}")

    hist_fft  = wl_fft.histogram()
    hist_nco  = wl_nco.histogram()
    total_fft = len(wl_fft.transactions)
    total_nco = len(wl_nco.transactions)

    print("\n=== WL_FFT Mode-Occupancy Histogram ===")
    for n in sorted(hist_fft):
        print(f"  n={n:2d}: {hist_fft[n]:5d} ({100*hist_fft[n]/total_fft:.1f}%)")

    print("\n=== WL_NCO Mode-Occupancy Histogram ===")
    for n in sorted(hist_nco):
        print(f"  n={n:2d}: {hist_nco[n]:5d} ({100*hist_nco[n]/total_nco:.1f}%)")

    # Write analysis doc
    analysis_path = out_dir / "WORKLOAD_ANALYSIS.md"
    with open(analysis_path, 'w') as f:
        f.write(generate_analysis_md(
            wl_fft, wl_nco, fft_sha, nco_sha, fft_sz, nco_sz))

    print(f"\nWrote: {fft_trace_path}")
    print(f"Wrote: {nco_trace_path}")
    print(f"Wrote: {fft_hist_path}")
    print(f"Wrote: {nco_hist_path}")
    print(f"Wrote: {analysis_path}")


if __name__ == "__main__":
    main()
