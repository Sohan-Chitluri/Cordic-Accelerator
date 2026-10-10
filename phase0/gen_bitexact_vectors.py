#!/usr/bin/env python3
"""Phase 0, item 1: generate directed + random vectors to verify tb/golden_model.py
(CordicGoldenModel) is bit-exact to the frozen-baseline RTL (WIDTH=16, FRACT_W=12,
ITERATIONS=8), via actual Verilator simulation (tb/phase0_cosim_tb.sv).

Writes the same $fscanf-friendly format golden_model.py's own generate_test_mem()
defines (never used by any committed testbench until this Phase 0 script):
    line 1: vector count
    each line: x_in y_in z_in cfg_saturate  exp_x exp_y exp_z exp_ovf

No RTL is touched. This script only produces stimulus for a new, separate
cosim testbench (tb/phase0_cosim_tb.sv).
"""
import os
import random
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tb"))
from golden_model import CordicGoldenModel, Z_LIMIT, XY_LIMIT  # noqa: E402

OUT = os.path.join(os.path.dirname(__file__), "vectors", "bitexact_check.mem")

WIDTH = 16
FRACT_W = 12
ITERATIONS = 8
MAX_POS = (1 << (WIDTH - 1)) - 1   # 32767
MIN_NEG = -(1 << (WIDTH - 1))      # -32768


def directed_cases():
    """Quadrant boundaries, near-overflow, and MIN_NEG/MAX_POS extremes."""
    cases = []
    # Quadrant-boundary angles (z in Q12 radians), both saturate modes.
    angle_z = {
        "0deg": 0, "30deg": 2145, "45deg": 3217, "60deg": 4290,
        "+Zlimit": Z_LIMIT, "-Zlimit": -Z_LIMIT,
        "+Zlimit-1": Z_LIMIT - 1, "-Zlimit+1": -Z_LIMIT + 1,
    }
    xy_extreme = {
        "zero": 0, "+XYlimit": XY_LIMIT, "-XYlimit": -XY_LIMIT,
        "+MAX_POS": MAX_POS, "MIN_NEG": MIN_NEG, "+1": 1, "-1": -1,
    }
    for sat in (True, False):
        for zname, z in angle_z.items():
            cases.append((XY_LIMIT, 0, z, sat, f"unit_vec_z={zname}"))
        for xname, x in xy_extreme.items():
            for yname, y in xy_extreme.items():
                cases.append((x, y, 0, sat, f"x={xname},y={yname},z=0deg"))
        # MIN_NEG negation-overflow stress (historically a bug class here).
        cases.append((MIN_NEG, MIN_NEG, Z_LIMIT, sat, "MIN_NEG,MIN_NEG,+Zlimit"))
        cases.append((MIN_NEG, MAX_POS, -Z_LIMIT, sat, "MIN_NEG,MAX_POS,-Zlimit"))
        cases.append((MAX_POS, MAX_POS, 0, sat, "MAX_POS,MAX_POS,0"))
    return cases


def main(n_random=4000, seed=0xB17E, iterations=ITERATIONS, out=OUT):
    model = CordicGoldenModel(width=WIDTH, fract_w=FRACT_W, iterations=iterations)
    vecs = []  # (x, y, z, sat, xo, yo, zo, ovf, label)

    for (x, y, z, sat, label) in directed_cases():
        model.saturate = sat
        xo, yo, zo, ovf = model.cordic_rotation(x, y, z)
        vecs.append((x, y, z, sat, xo, yo, zo, ovf, label))

    random.seed(seed)
    for i in range(n_random):
        # Full architectural range (not just the documented convergence zone) —
        # Phase 0 explicitly wants overflow/saturation frequency data too.
        x = random.randint(MIN_NEG, MAX_POS)
        y = random.randint(MIN_NEG, MAX_POS)
        z = random.randint(MIN_NEG, MAX_POS)
        sat = random.choice([True, False])
        model.saturate = sat
        xo, yo, zo, ovf = model.cordic_rotation(x, y, z)
        vecs.append((x, y, z, sat, xo, yo, zo, ovf, f"random_{i}"))

    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    with open(out, "w") as f:
        f.write(f"{len(vecs)}\n")
        for (x, y, z, sat, xo, yo, zo, ovf, _label) in vecs:
            f.write(f"{x} {y} {z} {1 if sat else 0} {xo} {yo} {zo} {1 if ovf else 0}\n")

    n_directed = len(directed_cases())
    print(f"Wrote {len(vecs)} vectors ({n_directed} directed, {n_random} random, "
          f"iterations={iterations}) to {out}")


if __name__ == "__main__":
    if len(sys.argv) > 1:
        it = int(sys.argv[1])
        main(n_random=800, iterations=it,
             out=os.path.join(os.path.dirname(__file__), "vectors",
                               f"bitexact_check_iter{it}.mem"))
    else:
        main()
