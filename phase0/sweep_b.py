#!/usr/bin/env python3
"""Phase 0b sweeps. No RTL changes. Supersedes phase0/sweep.py's items 2b/2c
(the FRACT_W-rescaling GeneralizedCordicModel) with an LSB-masking model on
the real, fixed FRACT_W=12 datapath (phase0/masked_model.py). Item 2a
(iteration sweep) is extended from 8 to 16, using the SAME real,
RTL-verified arithmetic as Phase 0 (see phase0/gen_bitexact_vectors.py run
for iterations in {8,10,12,14,16}: 920/920 bit-exact against actual
Verilator builds of cordic_pipeline at each ITERATIONS value, all legal
under cordic_stage.sv's own STAGE_IDX<16 guard).

Error reference (item 4): every error number in this file is measured
against the exact real-valued (floating point) ideal rotation
`x*cosθ - y*sinθ, x*sinθ + y*cosθ` -- NOT against tb/golden_model.py. Where
the model IS the golden model (mask_bits=0, iterations<=8, FRACT_W=12), that
is verified separately below (a handful of direct A/B comparisons; expected
0 difference by construction, reported to make the distinction explicit).
"""
import csv
import json
import math
import os
import random
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tb"))
sys.path.insert(0, os.path.dirname(__file__))
from golden_model import CordicGoldenModel          # noqa: E402
from masked_model import MaskedCordicModel, cordic_gain  # noqa: E402

RESULTS = os.path.join(os.path.dirname(__file__), "results")
os.makedirs(RESULTS, exist_ok=True)

WIDTH = 16
FRACT_W = 12
MAX_ITER = 16                      # extended from Phase 0's 8
Z_CONV_LIMIT_RAD = 1.7433

ANGLES_DEG = [0, 5, 10, 15, 30, 45, 60, 75, 89, 95, 99]
MAGNITUDES = [0.0, 0.25, 0.5, 1.0, 1.4648]

N_RANDOM = 500
random.seed(0x9E3779B9)
RANDOM_REAL_VECS = [
    (random.uniform(-1.5, 1.5), random.uniform(-1.5, 1.5),
     random.uniform(-Z_CONV_LIMIT_RAD, Z_CONV_LIMIT_RAD),
     random.choice([True, False]))
    for _ in range(N_RANDOM)
]


def directed_real_vecs():
    out = []
    for deg in ANGLES_DEG:
        theta = math.radians(deg)
        for mag in MAGNITUDES:
            for sat in (True, False):
                out.append((mag, 0.0, theta, sat))
    return out


DIRECTED_REAL_VECS = directed_real_vecs()
ALL_REAL_VECS = DIRECTED_REAL_VECS + RANDOM_REAL_VECS
N_DIRECTED = len(DIRECTED_REAL_VECS)
SCALE = 1 << FRACT_W  # fixed: real datapath, FRACT_W=12 always


def ideal_rotation(x, y, theta):
    c, s = math.cos(theta), math.sin(theta)
    return x * c - y * s, x * s + y * c


def quantize(real_val, max_pos, min_neg):
    q = round(real_val * SCALE)
    return max(min_neg, min(max_pos, q))


def dynamic_edge_vecs(model):
    max_r = model.MAX_POS / SCALE
    min_r = model.MIN_NEG / SCALE
    out = []
    for theta_deg in (0, 45, 89, 99):
        theta = math.radians(theta_deg)
        for sat in (True, False):
            out.append((max_r, 0.0, theta, sat))
            out.append((min_r, 0.0, theta, sat))
            out.append((max_r, max_r, theta, sat))
            out.append((min_r, min_r, theta, sat))
            out.append((max_r, min_r, theta, sat))
    return out


def _eval_vecs(model, vecs):
    errs_abs = []
    ovf_count = 0
    for (x_r, y_r, theta_r, sat) in vecs:
        model.saturate = sat
        xin = quantize(x_r, model.MAX_POS, model.MIN_NEG)
        yin = quantize(y_r, model.MAX_POS, model.MIN_NEG)
        zin = quantize(theta_r, model.MAX_POS, model.MIN_NEG)
        xo, yo, zo, ovf = model.cordic_rotation(xin, yin, zin)
        x_ideal, y_ideal = ideal_rotation(xin / SCALE, yin / SCALE, zin / SCALE)
        ex = xo / SCALE - x_ideal
        ey = yo / SCALE - y_ideal
        errs_abs.append(math.hypot(ex, ey))
        if ovf:
            ovf_count += 1
    return errs_abs, ovf_count


def run_grid_point(iterations, mask_bits, use_correct_k=False):
    model = MaskedCordicModel(width=WIDTH, fract_w=FRACT_W, iterations=iterations,
                               mask_bits=mask_bits, use_correct_k=use_correct_k)
    core, core_ovf = _eval_vecs(model, ALL_REAL_VECS)
    edge, edge_ovf = _eval_vecs(model, dynamic_edge_vecs(model))
    return core, core_ovf, edge, edge_ovf


def stats(errs):
    n = len(errs)
    return {"n": n, "max": max(errs), "rms": math.sqrt(sum(e * e for e in errs) / n),
            "mean": sum(errs) / n}


# ---------------------------------------------------------------------------
# Item 1: iteration sweep, 1..16, FRACT_W=12, mask_bits=0 (real datapath).
# ---------------------------------------------------------------------------
def sweep_iterations_extended():
    rows = []
    for n in range(1, MAX_ITER + 1):
        core, core_ovf, edge, edge_ovf = run_grid_point(n, mask_bits=0)
        s = stats(core)
        s.update(iterations=n, mask_bits=0, effective_bits=FRACT_W,
                  overflow_freq=(core_ovf + edge_ovf) / (len(core) + len(edge)),
                  edge_max=max(edge), edge_rms=stats(edge)["rms"])
        rows.append(s)
    return rows


# ---------------------------------------------------------------------------
# Item 2: joint grid, iterations (1..16, real datapath) x mask_bits
# (0..10, HYPOTHETICAL -- no such masking hardware exists).
# ---------------------------------------------------------------------------
MASK_BITS_SWEEP = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]


def sweep_joint_masked():
    rows = []
    for k in MASK_BITS_SWEEP:
        for n in range(1, MAX_ITER + 1):
            core, core_ovf, edge, edge_ovf = run_grid_point(n, mask_bits=k)
            s = stats(core)
            s.update(iterations=n, mask_bits=k, effective_bits=FRACT_W - k,
                      overflow_freq=(core_ovf + edge_ovf) / (len(core) + len(edge)),
                      hw_realized=(k == 0))
            rows.append(s)
    return rows


# ---------------------------------------------------------------------------
# Item 3: K analysis, n = 1..16 (real fixed K vs. hypothetical correct-per-n K).
# ---------------------------------------------------------------------------
def sweep_k_error_extended():
    rows = []
    k_asym = 0.6072529350088813
    for n in range(1, MAX_ITER + 1):
        k_true = cordic_gain(n)
        errs_wrong, _, _, _ = run_grid_point(n, mask_bits=0, use_correct_k=False)
        errs_correct, _, _, _ = run_grid_point(n, mask_bits=0, use_correct_k=True)
        sw, sc = stats(errs_wrong), stats(errs_correct)
        rows.append({
            "iterations": n, "K_true_n": k_true, "K_asymptotic_fixed": k_asym,
            "K_rel_error_pct": abs(k_asym - k_true) / k_true * 100.0,
            "rms_err_fixed_k": sw["rms"], "rms_err_correct_k": sc["rms"],
            "max_err_fixed_k": sw["max"], "max_err_correct_k": sc["max"],
            "k_matters": abs(sw["rms"] - sc["rms"]) / sw["rms"] > 0.05,
        })
    return rows


# ---------------------------------------------------------------------------
# Item 4: error-reference confirmation (a handful of direct A/B checks
# against tb/golden_model.py, expected exactly 0 at mask_bits=0, n<=8).
# ---------------------------------------------------------------------------
def confirm_error_reference():
    random.seed(42)
    rows = []
    for n in (1, 4, 8):
        g = CordicGoldenModel(width=WIDTH, fract_w=FRACT_W, iterations=n)
        m = MaskedCordicModel(width=WIDTH, fract_w=FRACT_W, iterations=n, mask_bits=0)
        diffs = 0
        checked = 0
        for _ in range(500):
            x = random.randint(-32768, 32767)
            y = random.randint(-32768, 32767)
            z = random.randint(-32768, 32767)
            sat = random.choice([True, False])
            g.saturate = sat
            m.saturate = sat
            a = g.cordic_rotation(x, y, z)
            b = m.cordic_rotation(x, y, z)
            checked += 1
            if a != b:
                diffs += 1
        rows.append({"iterations": n, "checked": checked, "diffs_vs_golden_model": diffs})
    return rows


# ---------------------------------------------------------------------------
# Item 5: mode proposal from error budgets (not even spacing).
# ---------------------------------------------------------------------------
ERROR_BUDGETS = {
    "Low":      0.10,
    "Mid":      0.01,
    "High":     0.001,
}


def propose_modes(joint_rows):
    """For each budget, among (iterations, mask_bits) grid points whose core
    RMS error meets the budget, pick the one with fewest iterations; break
    ties by MOST masking (fewest effective bits) -- i.e. the cheapest point
    on the grid that still meets the target, not an evenly-spaced guess."""
    proposals = {}
    for name, budget in ERROR_BUDGETS.items():
        candidates = [r for r in joint_rows if r["rms"] <= budget]
        if not candidates:
            proposals[name] = None
            continue
        best = min(candidates, key=lambda r: (r["iterations"], -r["mask_bits"]))
        proposals[name] = best
    return proposals


def propose_modes_iterations_only(iter_rows):
    """Same budgets, but restricted to mask_bits=0 (the only currently
    buildable lever) -- the PRACTICAL proposal, vs. propose_modes()'s
    exploratory joint (iterations + hypothetical masked bits) proposal."""
    proposals = {}
    for name, budget in ERROR_BUDGETS.items():
        candidates = [r for r in iter_rows if r["rms"] <= budget]
        proposals[name] = min(candidates, key=lambda r: r["iterations"]) if candidates else None
    return proposals


def find_wasteful(joint_rows):
    """Combinations where reducing iterations by 1 (same mask_bits), or
    increasing mask_bits by 1 (same iterations), changes core RMS by <2% --
    i.e. that increment bought essentially nothing."""
    by_key = {(r["iterations"], r["mask_bits"]): r for r in joint_rows}
    wasteful_iters = []
    wasteful_bits = []
    for (n, k), r in by_key.items():
        prev = by_key.get((n - 1, k))
        if prev and prev["rms"] > 0 and abs(r["rms"] - prev["rms"]) / prev["rms"] < 0.02:
            wasteful_iters.append({"iterations": n, "mask_bits": k, "rms": r["rms"],
                                    "prev_rms": prev["rms"]})
        nxt = by_key.get((n, k - 1))  # k-1 = fewer bits masked = more precision
        if nxt and nxt["rms"] > 0 and abs(r["rms"] - nxt["rms"]) / nxt["rms"] < 0.02 and k > 0:
            wasteful_bits.append({"iterations": n, "mask_bits": k, "rms": r["rms"],
                                   "finer_rms": nxt["rms"]})
    return wasteful_iters, wasteful_bits


def write_csv(path, rows, fieldnames):
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for r in rows:
            w.writerow(r)


def svg_line_chart(path, series, xlabel, ylabel, title, log_y=True):
    W, H, PAD = 640, 400, 60
    xs_all = [p[0] for s in series for p in s["points"]]
    ys_all = [p[1] for s in series for p in s["points"]]
    xmin, xmax = min(xs_all), max(xs_all)
    ys_plot = [math.log10(y) if (log_y and y > 0) else y for y in ys_all]
    ymin, ymax = min(ys_plot), max(ys_plot)
    if ymax == ymin:
        ymax = ymin + 1
    if xmax == xmin:
        xmax = xmin + 1

    def sx(x):
        return PAD + (x - xmin) / (xmax - xmin) * (W - 2 * PAD)

    def sy(y):
        yy = math.log10(y) if (log_y and y > 0) else y
        return H - PAD - (yy - ymin) / (ymax - ymin) * (H - 2 * PAD)

    colors = ["#1f77b4", "#d62728", "#2ca02c", "#9467bd", "#ff7f0e"]
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
             f'font-family="sans-serif" font-size="11">',
             f'<rect width="{W}" height="{H}" fill="white"/>',
             f'<text x="{W/2}" y="20" text-anchor="middle" font-size="14">{title}</text>',
             f'<line x1="{PAD}" y1="{H-PAD}" x2="{W-PAD}" y2="{H-PAD}" stroke="black"/>',
             f'<line x1="{PAD}" y1="{PAD}" x2="{PAD}" y2="{H-PAD}" stroke="black"/>',
             f'<text x="{W/2}" y="{H-15}" text-anchor="middle">{xlabel}</text>',
             f'<text x="15" y="{H/2}" text-anchor="middle" '
             f'transform="rotate(-90,15,{H/2})">{ylabel}{" (log10)" if log_y else ""}</text>']
    for i, s in enumerate(series):
        pts = s["points"]
        color = colors[i % len(colors)]
        path_d = " ".join(f"{'M' if j == 0 else 'L'}{sx(x):.1f},{sy(y):.1f}"
                           for j, (x, y) in enumerate(pts))
        parts.append(f'<path d="{path_d}" fill="none" stroke="{color}" stroke-width="2"/>')
        for (x, y) in pts:
            parts.append(f'<circle cx="{sx(x):.1f}" cy="{sy(y):.1f}" r="2.5" fill="{color}"/>')
        parts.append(f'<text x="{W-PAD-5}" y="{PAD+15*i}" text-anchor="end" '
                      f'fill="{color}">{s["label"]}</text>')
    parts.append("</svg>")
    with open(path, "w") as f:
        f.write("\n".join(parts))


def svg_heatmap(path, rows, xkey, ykey, vkey, title):
    xs = sorted(set(r[xkey] for r in rows))
    ys = sorted(set(r[ykey] for r in rows))
    grid = {(r[xkey], r[ykey]): r[vkey] for r in rows}
    vals = [v for v in grid.values() if v > 0]
    lo, hi = math.log10(min(vals)), math.log10(max(vals))
    if hi == lo:
        hi = lo + 1
    CELL = 40
    PAD = 70
    W = PAD + CELL * len(xs) + 20
    H = PAD + CELL * len(ys) + 20

    def color_for(v):
        t = (math.log10(v) - lo) / (hi - lo) if v > 0 else 0
        t = max(0.0, min(1.0, t))
        r = int(255 * t)
        g = int(255 * (1 - t))
        return f"rgb({r},{g},80)"

    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
             f'font-family="sans-serif" font-size="9">',
             f'<rect width="{W}" height="{H}" fill="white"/>',
             f'<text x="{W/2}" y="20" text-anchor="middle" font-size="13">{title}</text>']
    for xi, xv in enumerate(xs):
        parts.append(f'<text x="{PAD+xi*CELL+CELL/2}" y="{PAD-8}" text-anchor="middle">'
                      f'{xv}</text>')
    for yi, yv in enumerate(ys):
        parts.append(f'<text x="{PAD-8}" y="{PAD+yi*CELL+CELL/2+4}" text-anchor="end">'
                      f'{yv}</text>')
        for xi, xv in enumerate(xs):
            v = grid.get((xv, yv))
            x0, y0 = PAD + xi * CELL, PAD + yi * CELL
            if v is None:
                continue
            parts.append(f'<rect x="{x0}" y="{y0}" width="{CELL-2}" height="{CELL-2}" '
                         f'fill="{color_for(v)}"/>')
            parts.append(f'<text x="{x0+CELL/2-1}" y="{y0+CELL/2+3}" text-anchor="middle" '
                         f'font-size="7">{v:.1e}</text>')
    parts.append(f'<text x="{PAD+len(xs)*CELL/2}" y="{H-3}" text-anchor="middle">'
                  f'{xkey} &#8594;</text>')
    parts.append(f'<text x="10" y="{PAD+len(ys)*CELL/2}" text-anchor="middle" '
                 f'transform="rotate(-90,10,{PAD+len(ys)*CELL/2})">{ykey} &#8593;</text>')
    parts.append("</svg>")
    with open(path, "w") as f:
        f.write("\n".join(parts))


def main():
    print(f"Canonical vector set: {N_DIRECTED} directed + {N_RANDOM} random "
          f"= {len(ALL_REAL_VECS)} core per grid point, + 40 dynamic edge vectors")

    iter_rows = sweep_iterations_extended()
    write_csv(os.path.join(RESULTS, "sweep_iterations_16.csv"), iter_rows,
              ["iterations", "mask_bits", "effective_bits", "n", "max", "rms", "mean",
               "overflow_freq", "edge_max", "edge_rms"])

    joint_rows = sweep_joint_masked()
    write_csv(os.path.join(RESULTS, "sweep_joint_masked.csv"), joint_rows,
              ["iterations", "mask_bits", "effective_bits", "n", "max", "rms", "mean",
               "overflow_freq", "hw_realized"])

    k_rows = sweep_k_error_extended()
    write_csv(os.path.join(RESULTS, "k_factor_error_16.csv"), k_rows,
              ["iterations", "K_true_n", "K_asymptotic_fixed", "K_rel_error_pct",
               "rms_err_fixed_k", "rms_err_correct_k", "max_err_fixed_k",
               "max_err_correct_k", "k_matters"])

    ref_rows = confirm_error_reference()
    write_csv(os.path.join(RESULTS, "error_reference_check.csv"), ref_rows,
              ["iterations", "checked", "diffs_vs_golden_model"])

    proposals = propose_modes(joint_rows)
    proposals_practical = propose_modes_iterations_only(iter_rows)
    wasteful_iters, wasteful_bits = find_wasteful(joint_rows)

    svg_line_chart(
        os.path.join(RESULTS, "error_vs_iterations_16.svg"),
        [{"label": "RMS error", "points": [(r["iterations"], r["rms"]) for r in iter_rows]},
         {"label": "Max error", "points": [(r["iterations"], r["max"]) for r in iter_rows]}],
        "iterations", "abs error (real units)",
        "Error vs. iteration count, 1-16 (FRACT_W=12, real RTL, bit-exact-verified)")

    svg_line_chart(
        os.path.join(RESULTS, "error_vs_maskbits_iter16.svg"),
        [{"label": "RMS error", "points": [(r["mask_bits"], r["rms"]) for r in joint_rows
                                            if r["iterations"] == 16]},
         {"label": "Max error", "points": [(r["mask_bits"], r["max"]) for r in joint_rows
                                            if r["iterations"] == 16]}],
        "mask_bits (LSBs zeroed)", "abs error (real units)",
        "Error vs. masked bits @ iterations=16 (HYPOTHETICAL, no masking HW exists)")

    svg_heatmap(os.path.join(RESULTS, "joint_heatmap_masked_rms.svg"), joint_rows,
                "iterations", "mask_bits", "rms",
                "Joint RMS error heatmap: iterations x mask_bits (log color)")

    svg_line_chart(
        os.path.join(RESULTS, "k_error_vs_iterations_16.svg"),
        [{"label": "RMS err, RTL's fixed K",
          "points": [(r["iterations"], r["rms_err_fixed_k"]) for r in k_rows]},
         {"label": "RMS err, hypothetical correct-per-n K",
          "points": [(r["iterations"], r["rms_err_correct_k"]) for r in k_rows]}],
        "iterations", "abs error (real units)",
        "K-factor error contribution vs. iteration count, 1-16")

    with open(os.path.join(RESULTS, "summary_b.json"), "w") as f:
        json.dump({
            "n_directed": N_DIRECTED, "n_random": N_RANDOM, "n_edge": 40,
            "iterations_sweep_16": iter_rows,
            "joint_masked": joint_rows,
            "k_factor_16": k_rows,
            "error_reference_check": ref_rows,
            "mode_proposals_joint_exploratory": proposals,
            "mode_proposals_practical_iterations_only": proposals_practical,
            "wasteful_iterations": wasteful_iters,
            "wasteful_bits": wasteful_bits,
        }, f, indent=2, default=str)

    print("Mode proposals (practical, iterations-only, mask_bits=0):")
    for name, r in proposals_practical.items():
        print(f"  {name}: {r}")
    print("Mode proposals (exploratory, joint iterations+masked-bits):")
    for name, r in proposals.items():
        print(f"  {name}: {r}")
    print(f"Wasteful-iteration points: {len(wasteful_iters)}, "
          f"wasteful-bit points: {len(wasteful_bits)}")
    print("Wrote CSVs, SVG plots, and summary_b.json to phase0/results/")


if __name__ == "__main__":
    main()
