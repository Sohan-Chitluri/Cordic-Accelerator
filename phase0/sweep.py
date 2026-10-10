#!/usr/bin/env python3
"""Phase 0 sweeps (items 2, 3, 4). No RTL changes; reads nothing from the
hardware flow. Uses:
  - tb.golden_model.CordicGoldenModel for the iteration-count sweep (2a) --
    this IS bit-exact to what the frozen RTL would produce if elaborated with
    that ITERATIONS value (K_FIXED=2488 is a compile-time literal independent
    of ITERATIONS in rtl/cordic_lut.sv, exactly as the model already behaves).
  - phase0.generalized_model.GeneralizedCordicModel for the FRACT_W sweep
    (2b) and the joint grid (2c), since the real RTL cannot be built at any
    FRACT_W other than 12 (rtl/cordic_lut.sv / rtl/cordic_stage.sv static
    guards) -- flagged wherever it's used.
  - phase0.generalized_model.cordic_gain for the true per-iteration-count K
    (item 3).

Writes CSVs, a JSON summary, and dependency-free SVG plots (no matplotlib in
this project's nix environment) under phase0/results/.
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
from generalized_model import GeneralizedCordicModel, cordic_gain  # noqa: E402

RESULTS = os.path.join(os.path.dirname(__file__), "results")
os.makedirs(RESULTS, exist_ok=True)

WIDTH = 16
MAX_ITER = 8
Z_CONV_LIMIT_RAD = 1.7433   # asymptotic CORDIC rotation-mode convergence bound

# ---------------------------------------------------------------------------
# Canonical test-vector set, defined in REAL units so it can be re-quantized
# consistently at any FRACT_W. Same set used for every grid point.
# ---------------------------------------------------------------------------
ANGLES_DEG = [0, 5, 10, 15, 30, 45, 60, 75, 89, 95, 99]  # includes 90deg-ish boundary
MAGNITUDES = [0.0, 0.25, 0.5, 1.0, 1.4648]               # 1.4648 ~= XY_LIMIT/4096

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


def ideal_rotation(x, y, theta):
    """Exact real-valued rotation (what CORDIC approximates)."""
    c, s = math.cos(theta), math.sin(theta)
    return x * c - y * s, x * s + y * c


def quantize(real_val, fract_w, max_pos, min_neg):
    q = round(real_val * (1 << fract_w))
    return max(min_neg, min(max_pos, q))


def dynamic_edge_vecs(model, scale):
    """Near-overflow / MIN_NEG / MAX_POS stress cases, sized to THIS grid
    point's own representable range (which shrinks as fract_w grows for a
    fixed WIDTH=16 word) -- otherwise a fixed real magnitude would only
    stress saturation at small fract_w and never at large fract_w."""
    max_r = model.MAX_POS / scale
    min_r = model.MIN_NEG / scale
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


def _eval_vecs(model, scale, vecs):
    errs_abs = []
    ovf_count = 0
    for (x_r, y_r, theta_r, sat) in vecs:
        model.saturate = sat
        xin = quantize(x_r, fract_w=model.FRACT_W, max_pos=model.MAX_POS,
                       min_neg=model.MIN_NEG)
        yin = quantize(y_r, fract_w=model.FRACT_W, max_pos=model.MAX_POS,
                       min_neg=model.MIN_NEG)
        zin = quantize(theta_r, fract_w=model.FRACT_W, max_pos=model.MAX_POS,
                       min_neg=model.MIN_NEG)
        xo, yo, zo, ovf = model.cordic_rotation(xin, yin, zin)
        # Ideal uses the ACTUAL quantized inputs re-interpreted as reals, so
        # the error measured is purely the algorithm+arithmetic error, not
        # input-quantization noise from the canonical-vector definition.
        x_ideal, y_ideal = ideal_rotation(xin / scale, yin / scale, zin / scale)
        ex = xo / scale - x_ideal
        ey = yo / scale - y_ideal
        errs_abs.append(math.hypot(ex, ey))
        if ovf:
            ovf_count += 1
    return errs_abs, ovf_count


def run_grid_point(fract_w, iterations, use_correct_k=False):
    """Run the canonical (within-convergence-envelope) vector set AND this
    grid point's own dynamic near-overflow/MIN_NEG/MAX_POS edge cases
    (sized to ITS OWN representable range) through the (generalized) model.

    Returns (core_errs, core_ovf, edge_errs, edge_ovf) -- kept SEPARATE
    because saturation-boundary error magnitudes are qualitatively
    different (an ideal rotation near the format's max magnitude produces
    huge absolute real-unit errors on clamp, by construction) and would
    otherwise swamp the knee-point analysis of normal-operating-envelope
    error, which is what item 4's mode proposal needs.
    """
    model = GeneralizedCordicModel(width=WIDTH, fract_w=fract_w,
                                    iterations=iterations,
                                    use_correct_k=use_correct_k)
    scale = 1 << fract_w
    core_errs, core_ovf = _eval_vecs(model, scale, ALL_REAL_VECS)
    edge_errs, edge_ovf = _eval_vecs(model, scale, dynamic_edge_vecs(model, scale))
    return core_errs, core_ovf, edge_errs, edge_ovf


def stats(errs):
    n = len(errs)
    mx = max(errs)
    mean = sum(errs) / n
    rms = math.sqrt(sum(e * e for e in errs) / n)
    return {"max": mx, "rms": rms, "mean": mean, "n": n}


# ---------------------------------------------------------------------------
# 2a. Error vs iteration count, FRACT_W=12 (real, buildable RTL configs).
# ---------------------------------------------------------------------------
def sweep_iterations():
    rows = []
    for n in range(1, MAX_ITER + 1):
        core, core_ovf, edge, edge_ovf = run_grid_point(
            fract_w=12, iterations=n, use_correct_k=False)
        s = stats(core)
        s.update(iterations=n, fract_w=12,
                  overflow_freq=(core_ovf + edge_ovf) / (len(core) + len(edge)),
                  edge_max=max(edge), edge_rms=stats(edge)["rms"])
        rows.append(s)
    return rows


# ---------------------------------------------------------------------------
# 2b. Error vs FRACT_W, iterations=8 (max). HYPOTHETICAL beyond fract_w=12.
# ---------------------------------------------------------------------------
FRACT_W_SWEEP = [4, 6, 8, 9, 10, 11, 12, 13, 14]


def sweep_precision():
    rows = []
    for fw in FRACT_W_SWEEP:
        core, core_ovf, edge, edge_ovf = run_grid_point(
            fract_w=fw, iterations=MAX_ITER, use_correct_k=False)
        s = stats(core)
        s.update(iterations=MAX_ITER, fract_w=fw,
                  overflow_freq=(core_ovf + edge_ovf) / (len(core) + len(edge)),
                  edge_max=max(edge), edge_rms=stats(edge)["rms"],
                  buildable_rtl=(fw == 12))
        rows.append(s)
    return rows


# ---------------------------------------------------------------------------
# 2c. Joint grid.
# ---------------------------------------------------------------------------
def sweep_joint():
    rows = []
    for fw in FRACT_W_SWEEP:
        for n in range(1, MAX_ITER + 1):
            core, core_ovf, edge, edge_ovf = run_grid_point(
                fract_w=fw, iterations=n, use_correct_k=False)
            s = stats(core)
            s.update(iterations=n, fract_w=fw,
                      overflow_freq=(core_ovf + edge_ovf) / (len(core) + len(edge)),
                      buildable_rtl=(fw == 12))
            rows.append(s)
    return rows


# ---------------------------------------------------------------------------
# 3. K-factor-per-iteration-count analysis (FRACT_W=12, the real datapath).
# ---------------------------------------------------------------------------
def sweep_k_error():
    rows = []
    for n in range(1, MAX_ITER + 1):
        k_true = cordic_gain(n)
        k_asym = 0.6072529350088813
        errs_wrong, _, _, _ = run_grid_point(fract_w=12, iterations=n, use_correct_k=False)
        errs_correct, _, _, _ = run_grid_point(fract_w=12, iterations=n, use_correct_k=True)
        sw, sc = stats(errs_wrong), stats(errs_correct)
        rows.append({
            "iterations": n,
            "K_true_n": k_true,
            "K_asymptotic": k_asym,
            "K_rel_error_pct": abs(k_asym - k_true) / k_true * 100.0,
            "rms_error_wrong_k": sw["rms"],
            "rms_error_correct_k": sc["rms"],
            "max_error_wrong_k": sw["max"],
            "max_error_correct_k": sc["max"],
        })
    return rows


# ---------------------------------------------------------------------------
# Dependency-free SVG plotting helpers
# ---------------------------------------------------------------------------
def svg_line_chart(path, series, xlabel, ylabel, title, log_y=False):
    W, H, PAD = 640, 400, 60
    xs_all = [p[0] for s in series for p in s["points"]]
    ys_all = [p[1] for s in series for p in s["points"]]
    xmin, xmax = min(xs_all), max(xs_all)
    if log_y:
        ys_plot = [math.log10(y) if y > 0 else math.log10(1e-9) for y in ys_all]
    else:
        ys_plot = ys_all
    ymin, ymax = min(ys_plot), max(ys_plot)
    if ymax == ymin:
        ymax = ymin + 1
    if xmax == xmin:
        xmax = xmin + 1

    def sx(x):
        return PAD + (x - xmin) / (xmax - xmin) * (W - 2 * PAD)

    def sy(y):
        yy = math.log10(y) if (log_y and y > 0) else (math.log10(1e-9) if log_y else y)
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
    CELL = 46
    PAD = 70
    W = PAD + CELL * len(xs) + 140
    H = PAD + CELL * len(ys) + 20

    def color_for(v):
        t = (math.log10(v) - lo) / (hi - lo) if v > 0 else 0
        t = max(0.0, min(1.0, t))
        r = int(255 * t)
        g = int(255 * (1 - t))
        return f"rgb({r},{g},80)"

    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
             f'font-family="sans-serif" font-size="10">',
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
                         f'font-size="8">{v:.1e}</text>')
    parts.append(f'<text x="{PAD+len(xs)*CELL/2}" y="{H-3}" text-anchor="middle">'
                  f'{xkey} &#8594;</text>')
    parts.append(f'<text x="10" y="{PAD+len(ys)*CELL/2}" text-anchor="middle" '
                 f'transform="rotate(-90,10,{PAD+len(ys)*CELL/2})">{ykey} &#8593;</text>')
    parts.append("</svg>")
    with open(path, "w") as f:
        f.write("\n".join(parts))


def write_csv(path, rows, fieldnames):
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for r in rows:
            w.writerow(r)


def main():
    print(f"Canonical vector set: {N_DIRECTED} directed + {N_RANDOM} random "
          f"= {len(ALL_REAL_VECS)} per grid point")

    iter_rows = sweep_iterations()
    write_csv(os.path.join(RESULTS, "sweep_iterations.csv"), iter_rows,
              ["iterations", "fract_w", "n", "max", "rms", "mean", "overflow_freq",
               "edge_max", "edge_rms"])

    prec_rows = sweep_precision()
    write_csv(os.path.join(RESULTS, "sweep_precision.csv"), prec_rows,
              ["fract_w", "iterations", "n", "max", "rms", "mean", "overflow_freq",
               "edge_max", "edge_rms", "buildable_rtl"])

    joint_rows = sweep_joint()
    write_csv(os.path.join(RESULTS, "sweep_joint.csv"), joint_rows,
              ["fract_w", "iterations", "n", "max", "rms", "mean", "overflow_freq",
               "buildable_rtl"])

    k_rows = sweep_k_error()
    write_csv(os.path.join(RESULTS, "k_factor_error.csv"), k_rows,
              ["iterations", "K_true_n", "K_asymptotic", "K_rel_error_pct",
               "rms_error_wrong_k", "rms_error_correct_k",
               "max_error_wrong_k", "max_error_correct_k"])

    svg_line_chart(
        os.path.join(RESULTS, "error_vs_iterations.svg"),
        [{"label": "RMS error", "points": [(r["iterations"], r["rms"]) for r in iter_rows]},
         {"label": "Max error", "points": [(r["iterations"], r["max"]) for r in iter_rows]}],
        "iterations", "abs error (real units)",
        "Error vs. iteration count (FRACT_W=12, real RTL configs)", log_y=True)

    svg_line_chart(
        os.path.join(RESULTS, "error_vs_precision.svg"),
        [{"label": "RMS error", "points": [(r["fract_w"], r["rms"]) for r in prec_rows]},
         {"label": "Max error", "points": [(r["fract_w"], r["max"]) for r in prec_rows]}],
        "FRACT_W (bits)", "abs error (real units)",
        "Error vs. fractional precision (iterations=8, HYPOTHETICAL beyond FRACT_W=12)",
        log_y=True)

    svg_heatmap(os.path.join(RESULTS, "joint_heatmap_rms.svg"), joint_rows,
                "iterations", "fract_w", "rms",
                "Joint RMS error heatmap (iterations x fract_w) -- log color scale")

    svg_line_chart(
        os.path.join(RESULTS, "k_error_vs_iterations.svg"),
        [{"label": "RMS err, wrong K (RTL-realistic)",
          "points": [(r["iterations"], r["rms_error_wrong_k"]) for r in k_rows]},
         {"label": "RMS err, correct-per-n K (hypothetical)",
          "points": [(r["iterations"], r["rms_error_correct_k"]) for r in k_rows]}],
        "iterations", "abs error (real units)",
        "K-factor error contribution vs. iteration count", log_y=True)

    with open(os.path.join(RESULTS, "summary.json"), "w") as f:
        json.dump({
            "n_directed": N_DIRECTED, "n_random": N_RANDOM,
            "iterations_sweep": iter_rows,
            "precision_sweep": prec_rows,
            "k_factor_analysis": k_rows,
        }, f, indent=2)

    print("Wrote CSVs, SVG plots, and summary.json to phase0/results/")


if __name__ == "__main__":
    main()
