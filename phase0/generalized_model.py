#!/usr/bin/env python3
"""Phase 0, items 2b/2c/3: a GENERALIZED CORDIC model, used only where the
frozen baseline RTL cannot be built at all (varying FRACT_W, or using a
per-iteration-count-correct K constant instead of the RTL's fixed 2488).

This is explicitly NOT bit-exact-to-any-buildable-RTL-configuration and must
never be cited as a hardware measurement. It exists solely to characterize,
numerically, where a quantization error floor would sit if a future
architecture relaxed the FRACT_W=12/single-K-constant restrictions that
rtl/cordic_lut.sv and rtl/cordic_stage.sv currently enforce (ADR-0002:
no general multiplier in the datapath). It uses the SAME quantization
methodology as the real RTL (round-to-nearest shift-add K constant,
round-to-nearest atan LUT, arithmetic-shift-right-with-round-to-nearest,
saturating add/sub) — only the specific constants change per FRACT_W.

For FRACT_W == 12, iterations == 8, and use_correct_k == False, this model's
arithmetic is identical in every respect to tb/golden_model.py's
CordicGoldenModel (verified bit-exact to the RTL in
phase0/gen_bitexact_vectors.py / tb/phase0_cosim_tb.sv) — i.e. it degenerates
exactly to the real, buildable baseline at that one point.
"""
import math


class GeneralizedCordicModel:
    def __init__(self, width=16, fract_w=12, iterations=8, saturate=True,
                 use_correct_k=False):
        self.WIDTH = width
        self.FRACT_W = fract_w
        self.ITERATIONS = iterations
        self.saturate = saturate

        self.MAX_POS = (1 << (width - 1)) - 1
        self.MIN_NEG = -(1 << (width - 1))

        self.K_FACTOR_TRUE = 0.6072529350088813  # asymptotic (n->inf) CORDIC gain
        self.K_N_TRUE = cordic_gain(iterations)   # true gain for THIS iteration count

        # RTL reality: the shift-add network always realizes round(K_FACTOR_TRUE
        # * 2^FRACT_W), independent of ITERATIONS (rtl/cordic_lut.sv has no
        # ITERATIONS-dependence in its constant at all). use_correct_k=True
        # instead uses round(K_N_TRUE * 2^FRACT_W) -- the value that WOULD be
        # needed for THIS iteration count to be gain-correct; not realizable
        # by the current shift-add hardware without per-mode constants.
        k_src = self.K_N_TRUE if use_correct_k else self.K_FACTOR_TRUE
        if fract_w == 12 and not use_correct_k:
            # The real RTL constant (2488) is a literal in rtl/cordic_lut.sv,
            # not a live round(K*4096) -- that computation actually gives 2487
            # (0.6072529350088813*4096 = 2487.308), one LSB below the RTL's
            # hardwired value. Use the real constant here so this model is
            # bit-exact to buildable hardware at its one real-hardware point;
            # the round() formula below is this model's own explicit,
            # documented choice for the hypothetical (non-buildable) points.
            self.K_FIXED = 2488
        else:
            self.K_FIXED = round(k_src * (1 << fract_w))

        self.atan_lut = [round(math.atan(2.0 ** -i) * (1 << fract_w))
                         for i in range(max(iterations, 16))]

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
            z_new, _ = self._addsub(z, z_b, sub=True, sat=False)
            overflow = overflow or ovf_x or ovf_y
            x, y, z = x_new, y_new, z_new
        return x, y, z, overflow


def cordic_gain(n):
    """True CORDIC gain K_n = prod_{i=0}^{n-1} 1/sqrt(1+2^-2i)."""
    k = 1.0
    for i in range(n):
        k *= 1.0 / math.sqrt(1.0 + 2.0 ** (-2 * i))
    return k
