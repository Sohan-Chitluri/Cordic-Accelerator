#!/usr/bin/env python3
#==============================================================================
# Golden Model: cordic_golden.py
# Description: Bit-exact fixed-point CORDIC reference model for co-simulation
# Owner: Verification Agent
# Wave: 1 (continuous)
#==============================================================================

import sys
import math
import json
import random


class CordicGoldenModel:
    """
    Bit-exact fixed-point CORDIC rotation mode golden model.
    
    Matches RTL implementation:
    - Q-format: configurable WIDTH and FRACT_W
    - K-factor prescaling via 4-MSB LUT (same as RTL)
    - Arithmetic right shift with round-to-nearest
    - Saturating or wrap-around arithmetic
    - 8 iterations default
    """

    def __init__(self, width=16, fract_w=12, iterations=8, saturate=True):
        self.WIDTH = width
        self.FRACT_W = fract_w
        self.ITERATIONS = iterations
        self.saturate = saturate

        # Constants
        self.MAX_POS = (1 << (width - 1)) - 1
        self.MIN_NEG = -(1 << (width - 1))
        self.ONE_FIX = 1 << fract_w

        # K-factor: realized as the Q12 constant 2488/4096 = 0.607421875 via a
        # shift-add network in RTL (cordic_lut.sv). 0.028% vs. true K.
        self.K_FACTOR = 0.6072529350088813
        self.K_FIXED = 2488  # round(K * 2^FRACT_W), FRACT_W = 12

        # Pre-computed atan(2^-i) in fixed-point
        self.atan_lut = self._compute_atan_lut()

    def _compute_atan_lut(self):
        """Compute atan(2^-i) in fixed-point."""
        lut = []
        for i in range(16):
            angle = math.atan(2.0 ** -i)
            fixed = int(round(angle * (1 << self.FRACT_W)))
            lut.append(fixed)
        return lut

    def _wrap(self, v):
        """Wrap an integer to signed WIDTH-bit two's complement."""
        v &= (1 << self.WIDTH) - 1
        if v >= (1 << (self.WIDTH - 1)):
            v -= (1 << self.WIDTH)
        return v

    def _addsub(self, a, b, sub, sat):
        """Mirror rtl/fp_add_sub.sv: full = a-b (sub) or a+b, then saturate or
        wrap to WIDTH bits. Returns (result, overflow)."""
        full = (a - b) if sub else (a + b)
        overflow = not (self.MIN_NEG <= full <= self.MAX_POS)
        if sat and overflow:
            result = self.MAX_POS if full > self.MAX_POS else self.MIN_NEG
        else:
            result = self._wrap(full)
        return result, overflow

    def sat_add(self, a, b):
        """Saturating/wrapping addition (uses current self.saturate)."""
        return self._addsub(a, b, sub=False, sat=self.saturate)[0]

    def sat_sub(self, a, b):
        """Saturating/wrapping subtraction (uses current self.saturate)."""
        return self._addsub(a, b, sub=True, sat=self.saturate)[0]

    def arith_shift_right(self, val, shift):
        """Arithmetic right shift, round-to-nearest (bias added BEFORE shift).

        Bit-exact match to cordic_pkg::asr and cordic_stage. `val` is a signed
        int; Python's >> floors toward -inf, matching SV >>> on a signed value.
        """
        if shift <= 0:
            return val
        return (val + (1 << (shift - 1))) >> shift

    def k_prescale(self, val):
        """K-factor prescaling: round(val * 2488 / 4096).

        Bit-exact match to the RTL shift-add network in cordic_lut.sv:
            acc = (v<<11) + (v<<9) - (v<<6) - (v<<3)   # == v * 2488
            k   = (acc + 2048) >> 12                    # round-to-nearest
        Python's arithmetic >> floors (toward -inf), matching SV >>> on the
        signed accumulator, so both sides agree exactly. K < 1 so the result
        always fits in WIDTH bits; no saturation needed here.
        """
        acc = val * self.K_FIXED
        return (acc + (1 << (self.FRACT_W - 1))) >> self.FRACT_W

    def cordic_rotation(self, x_in, y_in, z_in):
        """CORDIC rotation mode, bit-exact to rtl/cordic_stage.sv chain.

        Per iteration i (sigma = +1 if z >= 0, else -1):
            x <- x - sigma * asr(y, i)     # x-path subtract
            y <- y + sigma * asr(x, i)     # y-path add
            z <- z - sigma * atan(2^-i)    # z-path (wraps, no saturation)

        Inputs are K-prescaled first. Overflow reflects the LAST stage's
        x/y saturation only, matching the pipeline's registered `overflow`.
        Returns (x_out, y_out, z_out, overflow_flag).
        """
        x = self.k_prescale(x_in)
        y = self.k_prescale(y_in)
        z = self._wrap(z_in)

        overflow = False

        for i in range(self.ITERATIONS):
            sigma_pos = (z >= 0)

            x_sh = self.arith_shift_right(x, i)
            y_sh = self.arith_shift_right(y, i)
            x_mux = x_sh if sigma_pos else -x_sh
            y_mux = y_sh if sigma_pos else -y_sh

            x_new, ovf_x = self._addsub(x, y_mux, sub=True, sat=self.saturate)
            y_new, ovf_y = self._addsub(y, x_mux, sub=False, sat=self.saturate)

            angle = self.atan_lut[i]
            z_b = angle if sigma_pos else -angle
            z_new, _ = self._addsub(z, z_b, sub=True, sat=False)  # z wraps

            overflow = ovf_x or ovf_y   # last-stage overflow (matches RTL)
            x, y, z = x_new, y_new, z_new

        return x, y, z, overflow


def run_test_suite():
    """Self-checking smoke tests for the golden model (arithmetic + rotation)."""
    model = CordicGoldenModel(width=16, fract_w=12, iterations=8, saturate=True)

    print("=" * 60)
    print("CORDIC Golden Model Smoke Test")
    print("=" * 60)

    # Test 1: Model instantiation and basic arithmetic
    print("\n--- Test 1: Basic Arithmetic ---")
    a = 100; b = 200
    sum_val = model.sat_add(a, b)
    diff = model.sat_sub(a, b)
    print(f"  sat_add(100, 200) = {sum_val} (expected 300)")
    print(f"  sat_sub(100, 200) = {diff} (expected -100)")
    assert sum_val == 300
    assert diff == -100
    print("  PASS")

    # Test 2: Saturation
    print("\n--- Test 2: Saturation ---")
    max_val = model.sat_add(32000, 1000)
    min_val = model.sat_sub(-32000, 1000)
    print(f"  sat_add(32000, 1000) = {max_val} (expected {model.MAX_POS})")
    print(f"  sat_sub(-32000, 1000) = {min_val} (expected {model.MIN_NEG})")
    assert max_val == model.MAX_POS
    assert min_val == model.MIN_NEG
    print("  PASS")

    # Test 3: Arithmetic shift, round-to-nearest (bias before shift)
    print("\n--- Test 3: Arithmetic Shift ---")
    assert model.arith_shift_right(4096, 1) == 2048   # exact, no fraction
    assert model.arith_shift_right(4095, 1) == 2048   # (4095+1)>>1 = 2048
    assert model.arith_shift_right(-4095, 1) == -2047  # (-4095+1)>>1 = -2047
    print("  arith_shift_right rounds correctly")
    print("  PASS")

    # Test 4: K-prescale = round(v * 2488 / 4096), full precision
    print("\n--- Test 4: K-Prescale (shift-add) ---")
    assert model.k_prescale(0) == 0
    assert model.k_prescale(4096) == 2488       # round(4096*2488/4096)
    assert model.k_prescale(-4096) == -2488
    for v in [0, 4096, -4096, 8192, 32767, -32768]:
        print(f"  k_prescale({v:6d}) = {model.k_prescale(v):6d}")
    print("  PASS")

    # Test 5: CORDIC rotation correctness — unit vector, known angles.
    # Input x=ONE_FIX(4096)=1.0, y=0, z=angle. Prescale by K then CORDIC gain
    # 1/K restores unit magnitude → x_out=cos(z)*4096, y_out=sin(z)*4096.
    print("\n--- Test 5: CORDIC Known Angles ---")
    ONE = model.ONE_FIX
    for deg, zf in [(0, 0), (45, 3217), (30, 2145), (60, 4290)]:
        xo, yo, zo, ovf = model.cordic_rotation(ONE, 0, zf)
        exp_c = int(round(math.cos(math.radians(deg)) * ONE))
        exp_s = int(round(math.sin(math.radians(deg)) * ONE))
        print(f"  {deg:2d}deg: x={xo} (cos~{exp_c}), y={yo} (sin~{exp_s}), z={zo}, ovf={ovf}")
        assert abs(xo - exp_c) <= 40, f"cos error at {deg}deg: {xo} vs {exp_c}"
        assert abs(yo - exp_s) <= 40, f"sin error at {deg}deg: {yo} vs {exp_s}"
    print("  PASS (all within 40 LSB / ~1%)")

    # Test 6: Wrap mode returns signed wrapped value
    print("\n--- Test 6: Wrap Mode ---")
    model_wrap = CordicGoldenModel(width=16, fract_w=12, iterations=8, saturate=False)
    wrapped = model_wrap.sat_add(32000, 1000)   # 33000 wraps to -32536
    print(f"  wrap_add(32000, 1000) = {wrapped} (expected -32536)")
    assert wrapped == -32536
    print("  PASS")

    print("\n" + "=" * 60)
    print("ALL SMOKE TESTS PASSED")
    print("=" * 60)
    return True


# CORDIC convergence zone: |z| < ~1.7433 rad. In Q12 that's ~7141; use 7127
# (matches SPECIFICATION FR-01 ±1.74 rad). Inputs are limited so the prescaled
# vector magnitude stays within the Q12.3 range and does not spuriously saturate.
Z_LIMIT = 7127
XY_LIMIT = 6000   # |x|,|y| bound; after K-prescale (~0.61x) well inside ±8.0


def _gen_vectors(count, seed=0xC0DE):
    """Produce a list of (x, y, z, saturate, x_out, y_out, z_out, ovf) tuples
    within the CORDIC convergence zone."""
    model = CordicGoldenModel()
    random.seed(seed)
    out = []
    for _ in range(count):
        x = random.randint(-XY_LIMIT, XY_LIMIT)
        y = random.randint(-XY_LIMIT, XY_LIMIT)
        z = random.randint(-Z_LIMIT, Z_LIMIT)
        saturate = random.choice([True, False])
        model.saturate = saturate
        xo, yo, zo, ovf = model.cordic_rotation(x, y, z)
        out.append((x, y, z, 1 if saturate else 0, xo, yo, zo, 1 if ovf else 0))
    return out


def generate_test_vectors(count=10000, output_file="test_vectors.json"):
    """Generate random regression vectors as JSON (convergence-zone limited)."""
    vectors = [
        {"id": i, "x_in": x, "y_in": y, "z_in": z, "cfg_saturate": sat,
         "expected": {"x_out": xo, "y_out": yo, "z_out": zo, "overflow": ovf}}
        for i, (x, y, z, sat, xo, yo, zo, ovf) in enumerate(_gen_vectors(count))
    ]
    with open(output_file, 'w') as f:
        json.dump(vectors, f, indent=2)
    print(f"Generated {count} JSON test vectors to {output_file}")


def generate_test_mem(count=10000, output_file="test_vectors/regression.mem"):
    """Generate plain-text vectors for SystemVerilog $fscanf co-simulation.

    One vector per line, whitespace-separated decimal (signed) fields:
        x_in y_in z_in cfg_saturate  exp_x exp_y exp_z exp_ovf
    First line is the vector count (so the TB can size its loop).
    """
    import os
    vecs = _gen_vectors(count)
    os.makedirs(os.path.dirname(output_file) or ".", exist_ok=True)
    with open(output_file, 'w') as f:
        f.write(f"{len(vecs)}\n")
        for (x, y, z, sat, xo, yo, zo, ovf) in vecs:
            f.write(f"{x} {y} {z} {sat} {xo} {yo} {zo} {ovf}\n")
    print(f"Generated {count} .mem test vectors to {output_file}")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "gen":
        count = int(sys.argv[2]) if len(sys.argv) > 2 else 10000
        out = sys.argv[3] if len(sys.argv) > 3 else "test_vectors.json"
        generate_test_vectors(count, out)
    elif cmd == "gen-mem":
        count = int(sys.argv[2]) if len(sys.argv) > 2 else 10000
        out = sys.argv[3] if len(sys.argv) > 3 else "tb/test_vectors/regression.mem"
        generate_test_mem(count, out)
    else:
        run_test_suite()