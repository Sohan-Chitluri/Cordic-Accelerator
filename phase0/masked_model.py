#!/usr/bin/env python3
"""Phase 0b, item 2: LSB-masking precision model on the FIXED, real 12-bit
datapath (WIDTH=16, FRACT_W=12 exactly as built) -- replaces Phase 0's
"narrower FRACT_W" GeneralizedCordicModel for precision characterization.

Rationale for the replacement: GeneralizedCordicModel (phase0/generalized_model.py)
had to invent a K constant and atan table for FRACT_W values the RTL cannot
build at all (a new shift-add network per width). This model instead keeps
the REAL, buildable FRACT_W=12 datapath (same K_FIXED=2488 literal, same
12-bit atan table) and zeros the low `mask_bits` bits of x, y, and z at the
input and after every iteration stage -- modeling what a narrower internal
register/functional-unit width (or a deliberately truncated datapath) would
produce if it fed back into this same, unchanged 16-bit/Q12 container. No
rescaling is needed ("realignment"): masking zeros bits in place, so the
result stays in the same Q12 numeric domain throughout, and the existing
saturating add/sub is reused unmodified.

This model is NOT RTL-verified for mask_bits > 0 (there is no such masking
hardware in the frozen baseline) -- ONLY mask_bits=0 is bit-exact to real
hardware (verified: identical arithmetic to tb/golden_model.py's
CordicGoldenModel, itself bit-exact to the RTL per phase0/gen_bitexact_vectors.py).
Every mask_bits > 0 result is a numerical hypothetical, not a hardware
measurement, and must be labeled as such wherever it is reported.
"""
import math


class MaskedCordicModel:
    def __init__(self, width=16, fract_w=12, iterations=8, saturate=True,
                 mask_bits=0, use_correct_k=False):
        if fract_w != 12:
            raise ValueError("MaskedCordicModel keeps the REAL fixed datapath; "
                              "FRACT_W must be 12 (see module docstring).")
        self.WIDTH = width
        self.FRACT_W = fract_w
        self.ITERATIONS = iterations
        self.saturate = saturate
        self.mask_bits = mask_bits

        self.MAX_POS = (1 << (width - 1)) - 1
        self.MIN_NEG = -(1 << (width - 1))

        # Same real constant as rtl/cordic_lut.sv (literal 2488), unless the
        # (hypothetical) correct-per-n-K variant is requested for item 3.
        if use_correct_k:
            self.K_FIXED = round(cordic_gain(iterations) * (1 << fract_w))
        else:
            self.K_FIXED = 2488

        # Same 16-entry table as rtl/cordic_stage.sv's STAGE_ANGLE (FRACT_W=12).
        self.atan_lut = [round(math.atan(2.0 ** -i) * (1 << fract_w))
                         for i in range(16)]

    def _mask(self, v):
        """Zero (truncate toward -inf) the low mask_bits bits -- a narrower
        effective register width feeding back into the same Q12 container."""
        k = self.mask_bits
        if k <= 0:
            return v
        return (v >> k) << k

    def _wrap(self, v):
        v &= (1 << self.WIDTH) - 1
        if v >= (1 << (self.WIDTH - 1)):
            v -= (1 << self.WIDTH)
        return v

    def _addsub(self, a, b, sub, sat):
        full = (a - b) if sub else (a + b)
        overflow = not (self.MIN_NEG <= full <= self.MAX_POS)
        if sat and overflow:
            result = self.MAX_POS if full > self.MAX_POS else self.MIN_NEG
        else:
            result = self._wrap(full)
        return result, overflow

    def arith_shift_right(self, val, shift):
        if shift <= 0:
            return val
        return (val + (1 << (shift - 1))) >> shift

    def k_prescale(self, val):
        acc = val * self.K_FIXED
        return (acc + (1 << (self.FRACT_W - 1))) >> self.FRACT_W

    def cordic_rotation(self, x_in, y_in, z_in):
        x = self._mask(self.k_prescale(self._mask(x_in)))
        y = self._mask(self.k_prescale(self._mask(y_in)))
        z = self._mask(self._wrap(z_in))
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
            z_new, _ = self._addsub(z, z_b, sub=True, sat=False)
            overflow = overflow or ovf_x or ovf_y
            x, y, z = self._mask(x_new), self._mask(y_new), self._mask(z_new)
        return x, y, z, overflow


def cordic_gain(n):
    k = 1.0
    for i in range(n):
        k *= 1.0 / math.sqrt(1.0 + 2.0 ** (-2 * i))
    return k
