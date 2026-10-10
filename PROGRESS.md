# Phase 0 — Numerical Characterization (no RTL changes)

Scope, per instruction: pure numerical characterization to pick candidate
runtime modes from data, before any adaptive-hardware architecture or
implementation work. **No RTL was edited in this phase.** Two new,
standalone files were added for verification (`tb/phase0_cosim_tb.sv`, a
Verilator testbench) and all analysis (`phase0/*.py`); nothing under `rtl/`
was touched, and no existing testbench was modified.

All scripts are saved under `phase0/` and are reproducible:
```
nix develop --command bash -c "python3 phase0/gen_bitexact_vectors.py"
# then, from repo root, build+run tb/phase0_cosim_tb.sv (see item 1 below)
nix develop --command bash -c "python3 phase0/sweep.py"
```
Raw outputs: `phase0/results/*.csv`, `phase0/results/*.svg`,
`phase0/results/summary.json`.

---

## 1. Bit-accurate reference model — verified, not just reused

`tb/golden_model.py`'s `CordicGoldenModel` is **already bit-accurate to the
frozen baseline RTL** (`WIDTH=16, FRACT_W=12, ITERATIONS=8`) — this was
verified in this phase, not assumed from its own doc comments:

- **Directed test**: existing `make test-unit` (Verilator, real RTL) —
  `cordic_stage_tb` and `cordic_pipeline_tb` both compare live RTL output to
  values computed from this exact model and passed, fresh, 11/11
  (`cordic_top` suite) plus the two lower-level suites, re-run in this
  session.
- **New directed + random test** (this phase): `phase0/gen_bitexact_vectors.py`
  generated 120 directed vectors (quadrant-boundary angles 0/30/45/60°, the
  algorithm's own convergence limit `±Z_LIMIT`, `MIN_NEG`/`MAX_POS`/`±1`
  extremes on x/y, both saturate modes) plus 4000 random vectors spanning the
  **full architectural range** (`x,y,z ∈ [MIN_NEG, MAX_POS]`, saturate mode
  random per-vector) — into `phase0/vectors/bitexact_check.mem`. A new
  standalone testbench, `tb/phase0_cosim_tb.sv`, drives `cordic_pipeline`
  with these 4120 vectors one at a time (config handshake + data + drain per
  vector, so per-vector `cfg_saturate` is unambiguous) and compares
  `x_out/y_out/z_out/overflow` against the model's precomputed expected
  values.
  **Result: 4120/4120 bit-exact, 0 mismatches, 0 errors.**
  (Build/run command:
  `verilator --binary -j 0 -O3 -Wno-VARHIDDEN -Wno-TIMESCALEMOD --sv --timing --assert --top-module phase0_cosim_tb rtl/pkg/cordic_pkg.sv rtl/fp_add_sub.sv rtl/cordic_lut.sv rtl/cordic_stage.sv rtl/cordic_pipeline.sv tb/phase0_cosim_tb.sv -o <abs>/output/Vphase0_cosim_tb && output/Vphase0_cosim_tb +VECFILE=phase0/vectors/bitexact_check.mem`.)

**Conclusion: reused as-is for item 2a below (iteration-count sweep), which
stays within the model's supported domain (`FRACT_W=12`, `ITERATIONS`
free).**

### The FRACT_W constraint (why item 2 needed a second, explicitly-labeled model)

`CordicGoldenModel` hard-fails (`raise ValueError`) for any `fract_w != 12`,
mirroring the real RTL's own elaboration-time static-assert guards in
`rtl/cordic_lut.sv` and `rtl/cordic_stage.sv`: the K-factor shift-add network
(`K_FIXED = 2488`) is a **hardwired literal**, not derived from any
parameter — confirmed by reading `rtl/cordic_lut.sv` directly (the constant
`2488` and the shift amounts `<<11,<<9,<<6,<<3` are literal RTL, with no
`FRACT_W`- or `ITERATIONS`-dependence at all). There is no way to build this
RTL at any `FRACT_W` other than 12 without a new shift-add network (or a
real multiplier, forbidden by ADR-0002) — a **real architectural constraint**,
not a model limitation.

Item 2b/2c (fractional-precision sweep) is therefore impossible to run
against buildable RTL. `phase0/generalized_model.py` provides
`GeneralizedCordicModel`, which:
- Is **bit-exact to `CordicGoldenModel` (and therefore to the real RTL) at
  its one real-hardware point** (`fract_w=12, use_correct_k=False`) —
  verified directly: 5000/5000 random vectors, 0 mismatches (uses the
  literal `2488`, not a recomputed round(), at that one point — see the
  file's own comment for why naively recomputing `round(K·4096)` gives 2487,
  one LSB off the real constant).
- For any other `FRACT_W`, uses `round(K_FACTOR · 2^FRACT_W)` as its own
  explicit, documented modeling choice — the same rounding methodology the
  real constant was (nominally) derived from, applied at a width the real
  hardware cannot build.

**Every number in items 2b/2c/3 (below) that comes from `FRACT_W != 12` is a
hypothetical, non-buildable-RTL characterization, clearly marked
`buildable_rtl=False` in the CSVs.** Only `FRACT_W=12` rows are real,
measured-hardware-equivalent numbers.

---

## 2. Sweeps

**Error metric**: for each fixed-point input `(x,y,θ)`, the "ideal" is the
exact real-valued rotation `x·cosθ − y·sinθ, x·sinθ + y·cosθ`; error is the
Euclidean distance between the model's output (converted back to real units
via that grid point's own `2^FRACT_W` scale) and this ideal, in real
(dimensionless) units — comparable across different `FRACT_W` values.

**Two separate vector pools per grid point**, because they answer different
questions and mixing them confounds both:
- **Core (610 vectors)**: 110 directed (11 angles 0–99° × 5 magnitudes ×
  2 saturate modes, magnitudes chosen within the documented convergence/
  representable envelope) + 500 random real vectors
  (`x,y ∈ [-1.5,1.5]`, `θ ∈ [-1.7433, 1.7433]` rad, the algorithm's own
  asymptotic convergence bound, saturate mode random). This is the
  **normal-operating-envelope** error — what item 4's knee-point/mode
  analysis is based on.
- **Edge (40 vectors per grid point)**: `MAX_POS`/`MIN_NEG`-magnitude
  vectors, **re-derived per grid point** from that point's own
  `MAX_POS/2^FRACT_W` (since the representable real range shrinks as
  `FRACT_W` grows for a fixed 16-bit word), at 4 angles × 2 saturate modes ×
  5 magnitude-pair combinations. These deliberately stress saturation; a
  clamped output compared to an unclamped "ideal" produces very large
  absolute real-unit errors by construction — reported separately
  (`edge_max`, `edge_rms` columns) so they don't distort the "typical error"
  numbers.
- `overflow_freq` is computed over the combined core+edge pool at each grid
  point (fraction of all 650 vectors where `overflow` fired).

### 2a. Error vs. iteration count (FRACT_W=12, real buildable RTL)

`phase0/results/sweep_iterations.csv`, plot `error_vs_iterations.svg`.

| iterations | core max err | core RMS err | overflow freq |
|---|---|---|---|
| 1 | 1.528 | 0.573 | 3.7% |
| 2 | 0.798 | 0.299 | 3.7% |
| 3 | 0.451 | 0.158 | 3.7% |
| 4 | 0.216 | 0.082 | 3.7% |
| 5 | 0.111 | 0.040 | 3.7% |
| 6 | 0.056 | 0.022 | 3.7% |
| 7 | 0.028 | 0.010 | 4.3% |
| 8 (baseline) | 0.014 | 0.0053 | 4.9% |

Error roughly **halves per additional iteration** — the expected geometric
CORDIC convergence rate. `overflow_freq` is flat (driven almost entirely by
the deliberately-saturating edge vectors, not by iteration count) until it
ticks up slightly at 7–8 iterations, consistent with more iterations letting
a borderline vector's intermediate magnitude cross the saturation threshold
that it wouldn't have reached yet at fewer iterations.

### 2b. Error vs. fractional precision (ITERATIONS=8 max, HYPOTHETICAL beyond FRACT_W=12)

`phase0/results/sweep_precision.csv`, plot `error_vs_precision.svg`.

| FRACT_W | buildable RTL? | core max err | core RMS err |
|---|---|---|---|
| 4 | No | 0.253 | 0.1023 |
| 6 | No | 0.069 | 0.0243 |
| 8 | No | 0.022 | 0.0084 |
| 9 | No | 0.016 | 0.0060 |
| 10 | No | 0.014 | 0.0055 |
| 11 | No | 0.0138 | 0.0053 |
| **12** | **Yes (baseline)** | **0.0138** | **0.0053** |
| 13 | No | 0.0137 | 0.0053 |
| 14 | No | 0.0136 | 0.0052 |

**Error floor sets in around FRACT_W ≈ 9–10.** Below that, RMS error grows
substantially (2.4× worse at FRACT_W=8, 4.6× worse at FRACT_W=6). From
FRACT_W=10 upward, RMS error is flat to 3 significant figures — the
8-iteration algorithmic (truncation) error (~0.0053) dominates completely,
and extra fractional bits buy nothing measurable. **The real RTL's
FRACT_W=12 choice already sits past this knee**, i.e. is not
precision-starved relative to its own 8-iteration truncation floor.

### 2c. Joint iteration × precision grid

`phase0/results/sweep_joint.csv`, heatmap `joint_heatmap_rms.svg`
(iterations × FRACT_W, log-color RMS).

Confirms 2a/2b are not independent: **at low iteration counts, precision is
almost entirely irrelevant.** E.g. at `iterations=2`, core RMS ranges only
0.2995–0.3054 across `FRACT_W=4..14` (< 2% relative spread); at
`iterations=4`, 0.0825–0.1206 (FRACT_W=4 alone is measurably worse; FRACT_W
≥ 6 is flat). The iteration-truncation error dominates until iterations gets
large enough (≈7–8) for precision to start mattering at all — and even then,
only below FRACT_W≈9.

---

## 3. CORDIC gain K per iteration count

`phase0/results/k_factor_error.csv`, plot `k_error_vs_iterations.svg`.
True gain `K_n = ∏_{i=0}^{n-1} 1/√(1+2^{-2i})`, computed directly (no RTL/model needed for this column):

| iterations | K_n (true) | vs. asymptotic K=0.60725 (RTL's fixed constant) | rel. error |
|---|---|---|---|
| 1 | 0.70711 | | 14.12% |
| 2 | 0.63246 | | 3.98% |
| 3 | 0.61357 | | 1.03% |
| 4 | 0.60883 | | 0.26% |
| 5 | 0.60765 | | 0.065% |
| 6 | 0.60735 | | 0.016% |
| 7 | 0.60728 | | 0.0041% |
| 8 | 0.60726 | | 0.0010% |

**Does the K mismatch matter for output error?** Compared, at each
iteration count, using the RTL-realistic fixed asymptotic K (`K_FIXED=2488`,
what the hardware actually always does) vs. a hypothetical per-n-correct K:

| iterations | RMS err, RTL's fixed K | RMS err, per-n-correct K | difference |
|---|---|---|---|
| 1 | 0.5730 | 0.5916 | correct-K is *worse* |
| 2 | 0.2995 | 0.3019 | correct-K is *worse* |
| 3 | 0.1577 | 0.1581 | ~equal |
| 4 | 0.0825 | 0.0825 | ~equal |
| 5–8 | ~equal to 3 sig figs | ~equal | negligible |

**Finding: per-mode K compensation is NOT required.** At every iteration
count tested, using the RTL's single fixed asymptotic K constant produces
output error statistically indistinguishable from (and at low iteration
counts, sometimes even slightly *better* than) using the "correct" per-n
gain. This is because the CORDIC algorithm's own iteration-truncation error
term dominates the K-mismatch term at every point on this grid — the 14%
K-error at `iterations=1` sounds large in isolation, but a 1-iteration CORDIC
is already so far from converged (RMS error 0.57, over half the unit
magnitude) that a 14%-wrong gain constant doesn't measurably change the
picture. **A future low-iteration-count runtime mode does not need a
separate K constant per mode** — this removes one degree of design freedom
(and one potential source of per-mode datapath cost) from any future
adaptive-hardware proposal.

---

## 4. Knee-point analysis and proposed modes

**Knee points, both axes:**
- **Iteration axis**: error decreases geometrically (halving per iteration)
  with no plateau within the tested range (1–8) — i.e. **every iteration up
  to the current max (8) still buys a real, non-wasteful accuracy
  improvement.** There is no "wasted iterations" region within the current
  8-iteration architecture.
- **Precision axis** (at max iterations=8): floor sets in at **FRACT_W ≈
  9–10**; FRACT_W=12 (current) has ~0 headroom cost (0.0053 vs. 0.0055 RMS
  at FRACT_W=10 — a 4% difference) but is not "wasted" either, since 13–14
  bits would buy nothing further (flat from 12 up).
- **Joint**: precision only matters once iteration count is high enough
  (≈7–8) to have driven the truncation error down near the precision floor.
  **Wasteful combination, from the data**: any `FRACT_W > ~6` at
  `iterations ≤ 4` — e.g. `(iterations=2, FRACT_W=12)` costs the same
  precision-related silicon as `(iterations=2, FRACT_W=6)` for statistically
  indistinguishable error (0.2995 vs. 0.2998 RMS). If a future low-iteration
  runtime mode is ever built, it would not need full FRACT_W=12 precision to
  match its own achievable accuracy.

**Proposed candidate modes** (iteration count only — FRACT_W stays at 12,
the only buildable value under the current architecture; K stays at the
single fixed constant, justified by item 3):

| Mode | Iterations | Core RMS err | Core max err | Rationale |
|---|---|---|---|---|
| **Low** | 4 | 0.082 | 0.216 | ~2× the error of "balanced," but roughly half the combinational depth (fewer `cordic_stage` instances) — a real latency/area lever if a future architecture makes iteration count runtime-selectable (it is not, today: `cfg_iterations` is an unused input per `rtl/cordic_pipeline.sv`'s own comment, "currently unused in V1 (fixed at ITERATIONS)"). |
| **Balanced** | 6 | 0.022 | 0.056 | ~4× better than Low for 2 more stages; well past the steepest part of the convergence curve. |
| **High** | 8 (current baseline) | 0.0053 | 0.014 | No further per-iteration gain is free — this is the current, already-built configuration. |

These are **proposed from the error-vs-iteration curve's shape alone**
(geometric decay with no plateau), not from a hard application accuracy
requirement — no such requirement was given as an input to this phase. The
actual cycle/area cost of a lower-iteration-count build was not measured in
this phase (would require re-running Flow v1 P&R with `ITERATIONS<8`, which
is architecture/implementation work, out of scope here).

**Open questions for architecture phase (not answered here):**
- Today `cfg_iterations` is a dead input — realizing "modes" as a genuine
  runtime feature (vs. three separate fixed-`ITERATIONS` builds) requires
  new RTL (early-exit/mux logic in the stage chain) not present in the
  frozen baseline; this is real architecture work, correctly out of Phase
  0's scope.
- Whether "Low"/"Balanced" are worth building depends on an actual
  application-level accuracy requirement and a real area/timing measurement
  of a reduced-iteration build — neither exists yet.
- The precision axis is entirely hypothetical under the current
  architecture (Section 1); if a future design ever revisits FRACT_W (e.g.
  a wider datapath), the knee at FRACT_W≈9–10 (at 8 iterations) is the
  relevant data point, but only if the K-network and atan LUT are rebuilt
  for that width (real hardware work, not attempted here).
- Overflow/saturation frequency (used here as a coarse indicator) was not
  broken down by input-magnitude region beyond the two-pool (core/edge)
  split; a finer breakdown was not needed to reach the conclusions above.

---

## Deliverables checklist

- [x] Bit-accurate reference model, verified against frozen RTL (directed +
      random, via real Verilator simulation) — `tb/phase0_cosim_tb.sv`,
      `phase0/gen_bitexact_vectors.py`, `phase0/vectors/bitexact_check.mem`.
- [x] Error vs. iteration count — `phase0/results/sweep_iterations.csv`,
      `error_vs_iterations.svg`.
- [x] Error vs. fractional precision — `phase0/results/sweep_precision.csv`,
      `error_vs_precision.svg` (explicitly labeled hypothetical beyond
      FRACT_W=12).
- [x] Joint grid — `phase0/results/sweep_joint.csv`, `joint_heatmap_rms.svg`.
- [x] K-factor-per-iteration-count analysis —
      `phase0/results/k_factor_error.csv`, `k_error_vs_iterations.svg`.
- [x] Knee-point analysis and 3 proposed modes (above).
- [x] Scripts saved and reproducible (`phase0/*.py`, no external
      dependencies beyond the Python stdlib — this environment's `nix`
      shell has no `matplotlib`, so plots are dependency-free hand-rolled
      SVG, not PNG).

**STOP at this gate, per instruction.** No architecture spec or
implementation has been started. *(Phase 0b, below, extends this analysis
per follow-up instruction; the STOP-at-gate constraint still applies after
it.)*

---
---

# Phase 0b — Extended Numerical Characterization

No RTL edits. All new files are additive: `phase0/masked_model.py`,
`phase0/sweep_b.py`, and one **compile-time-only** extension to
`tb/phase0_cosim_tb.sv` (a new `TEST_ITERATIONS` module parameter,
defaulting to `cordic_pkg::ITERATIONS`, used to override
`cordic_pipeline`'s own `ITERATIONS` parameter at the Verilator command
line — no package file or other RTL touched; `cordic_pkg::ITERATIONS` stays
`8`). `git diff --stat -- rtl/ tb/ constraints/ scripts/ Makefile` before
this phase's edit to `tb/phase0_cosim_tb.sv` showed the file as newly-added
in Phase 0 already, so this is a same-file, additive extension, not a
change to any pre-existing testbench.

## 1. Iteration sweep extended to 16 — legality checked, RTL-verified per point

`cordic_stage.sv`'s own domain guard (`STAGE_IDX_SUPPORTED = (STAGE_IDX <
16)`, read directly from source) makes **`ITERATIONS` ∈ {9..16} a legal,
buildable configuration at `FRACT_W=12`** — the atan table has 16
precomputed entries (`STAGE_IDX` 0..15), and `WIDTH=16` already satisfies
the separate `WIDTH >= 13` guard. `ITERATIONS > 16` would fail elaboration
(`$fatal` + a static-assert-by-division-by-zero for `STAGE_IDX >= 16`).

**Verified bit-exact against real RTL builds at each of ITERATIONS ∈
{8, 10, 12, 14, 16}** (not just the 12/14/16 requested — 8 and 10 included
as continuity checks): `phase0/gen_bitexact_vectors.py <n>` generates 120
directed + 800 random vectors per `n` (`phase0/vectors/bitexact_check_iter{n}.mem`);
`tb/phase0_cosim_tb.sv` built with `-GTEST_ITERATIONS=<n>` against the real
`cordic_pipeline`/`cordic_stage`/`cordic_lut`/`fp_add_sub` RTL (no
`cordic_assertions` needed — its instantiation is compiled out entirely
under `ifdef ASSERT_ON`, not defined in this build, so its own hardwired
`cordic_pkg::ITERATIONS` reference is irrelevant here).

| ITERATIONS | Legal? | Vectors | Result |
|---|---|---|---|
| 8 | Yes (baseline) | 920 | **920/920 bit-exact** |
| 10 | Yes | 920 | **920/920 bit-exact** |
| 12 | Yes | 920 | **920/920 bit-exact** |
| 14 | Yes | 920 | **920/920 bit-exact** |
| 16 | Yes (max) | 920 | **920/920 bit-exact** |

**The 12-bit (FRACT_W=12) quantization floor is reached at ITERATIONS ≈ 13**
(`phase0/results/sweep_iterations_16.csv`, plot `error_vs_iterations_16.svg`):

| iterations | core RMS err | core max err |
|---|---|---|
| 8 (baseline) | 0.00528 | 0.01382 |
| 9 | 0.00276 | 0.00862 |
| 10 | 0.00148 | 0.00466 |
| 11 | 0.00086 | 0.00277 |
| 12 | 0.00063 | 0.00178 |
| **13** | **0.000573** | 0.00131 |
| 14 | 0.000569 | 0.00156 |
| 15 | 0.000569 | 0.00156 |
| 16 | 0.000569 | 0.00156 |

RMS error is flat from iteration 13 onward (0.0005694, identical to 4 sig
figs); max error stabilizes in a narrow 0.0013–0.0016 band rather than
continuing to shrink (a small vector-dependent rounding-decision flip at
the floor, not a bug — re-confirmed reproducible on re-run). **Iterations
beyond 13 buy nothing further at FRACT_W=12.**

## 2. Precision model replaced: LSB-masking on the real, fixed 12-bit datapath

`phase0/masked_model.py`'s `MaskedCordicModel` **replaces**
`phase0/generalized_model.py`'s FRACT_W-rescaling model for precision
characterization (that file and its `sweep_precision.csv`/`sweep_joint.csv`
outputs are retained on disk but superseded — do not cite them for
precision conclusions going forward). Unlike the old model, this one keeps
`WIDTH=16, FRACT_W=12` and the real `K_FIXED=2488` literal / real 16-entry
atan table exactly as built, and instead **zeros (truncates toward −∞) the
low `mask_bits` bits** of `x`, `y`, `z` at the input and after every
iteration stage, before the (unmodified) existing saturating add/sub. No
output realignment is needed: masking never changes scale, only zeroes
low-order bits in place.

**Verified degenerate at `mask_bits=0`**: bit-identical to
`tb/golden_model.py`'s `CordicGoldenModel` for iterations ∈
{1,2,4,8,10,12,14,16} (0/1000 mismatches each, random check) — i.e. exactly
the same real-hardware-equivalent arithmetic as Phase 0's item 1. **Any
`mask_bits > 0` result below is a numerical hypothetical — there is no
masking hardware in the frozen baseline; it characterizes what a
*redesigned, narrower* datapath might cost in accuracy, not the current chip.**

**Joint grid, iterations (1–16, real) × mask_bits (0–10, hypothetical)**
(`phase0/results/sweep_joint_masked.csv`, heatmap `joint_heatmap_masked_rms.svg`,
slice plot `error_vs_maskbits_iter16.svg`):

- **No plateau in `mask_bits` at any iteration count tested (0–10 bits
  masked, i.e. effective precision down to 2 bits)** — unlike the old
  FRACT_W-rescale model (which showed a knee around FRACT_W≈9–10), masking
  shows **monotonic, accelerating degradation with no floor**: at
  `iterations=16`, RMS goes 0.00057 (0 masked) → 0.0027 (1) → 0.0076 (2) →
  0.017 (3) → 0.037 (4) → 0.076 (5) → 0.159 (6) → 0.33 (7) → 0.68 (8) → 1.35
  (9) → 2.45 (10). **This is a real, reportable distinction**: a true
  narrower fixed-point *format* (smaller FRACT_W, its own correspondingly
  rescaled K/atan constants) degrades gracefully to a floor set by
  iteration-truncation error (Phase 0's finding); *masking* bits out of an
  otherwise-full-width datapath has no such floor and keeps getting worse,
  because it deletes information the algorithm needs at every one of the
  16 iterations rather than uniformly rescaling the whole numeric domain.
- **At LOW iteration counts, several masked bits cost almost nothing**
  (iteration-truncation error already dominates): at `iterations=2`, RMS is
  flat at ≈0.2995–0.301 through `mask_bits=0..6` (effective bits 12 down to
  6) before climbing; at `iterations=4`, flat ≈0.0825–0.098 through
  `mask_bits=0..6` as well.

## 3. K-factor analysis, extended to n=1..16

(`phase0/results/k_factor_error_16.csv`, plot `k_error_vs_iterations_16.svg`)

| iterations | K rel. error (fixed vs. true K_n) | RMS err, RTL's fixed K | RMS err, hypothetical correct-per-n K |
|---|---|---|---|
| 1 | 14.12% | 0.5730 | 0.5916 |
| 2 | 3.98% | 0.2995 | 0.3019 |
| 4 | 0.26% | 0.0825 | 0.0825 |
| 8 | 0.0010% | 0.00528 | 0.00528 |
| 10 | 0.0000636% | 0.001479 | 0.001423 |
| 12 | 0.0000040% | 0.000632 | 0.000559 |
| 16 | 0.0000000155% | 0.000569 | 0.000482 |

**Per-mode K compensation does not start to matter anywhere in this
range.** The K relative error itself shrinks to negligible (<0.001%) by
n=8 and keeps shrinking; the corresponding *output*-error gap between using
the RTL's fixed K vs. a hypothetical correct-per-n K stays at or below the
noise floor throughout. (The raw CSV shows a naive relative-difference
flag flipping "True" for n≥11 — this is an artifact of dividing two
already-tiny, quantization-floor-limited numbers, not a real re-emergence
of K sensitivity: the absolute gap there is ~0.00006–0.00008, an order of
magnitude below the FRACT_W=12 floor itself (§1). The correct reading is
the K-relative-error column: it only ever gets smaller with more
iterations, so if K compensation doesn't matter at n=4 (0.26% K error,
unmeasurable output effect), it certainly doesn't matter at n≥8.) This
confirms and extends Phase 0's original finding: **no future
low-iteration-count mode needs a per-mode K constant.**

## 4. Error reference — confirmed

Every error number in Phase 0 and Phase 0b (items 2a/2b/2c/3 in both) is
measured against the **exact real-valued floating-point ideal rotation**
(`x·cosθ − y·sinθ, x·sinθ + y·cosθ`, computed with Python's `math.cos`/`sin`
— IEEE double precision, effectively exact relative to the ~12-bit fixed
point being characterized), not against `tb/golden_model.py`. Where the
model in use is mathematically identical to the golden model
(`mask_bits=0`, any iteration count, FRACT_W=12), this was checked directly
and separately (`phase0/results/error_reference_check.csv`): **0 diffs
across 500 random vectors each at iterations ∈ {1, 4, 8}** — confirming the
"vs. golden model" and "vs. ideal float" questions are consistent at that
one real-hardware point, and that all reported *error* numbers are the
model's deviation from ideal, not from the golden model (which would be
trivially ~0 wherever the two are the same model).

**Sample counts per grid point** (stated explicitly, per instruction):
- **Core** pool: 110 directed (11 angles × 5 magnitudes × 2 saturate modes)
  + 500 random = **610 vectors**, fixed and identical across every grid
  point for direct comparability.
- **Edge** pool (Phase 0 only, item 1's precision table): 40 vectors
  per grid point, dynamically re-derived from that point's own
  `MAX_POS`/`MIN_NEG` real-unit bounds.
- Bit-exactness RTL verification (§1 above, and Phase 0 item 1): 4120
  vectors (Phase 0, ITERATIONS=8) + 920 × 5 = 4600 vectors (Phase 0b,
  ITERATIONS ∈ {8,10,12,14,16}) — **8720 total RTL-simulated vectors**,
  0 mismatches.

## 5. Mode proposal from error budgets (not evenly spaced)

Three RMS-error targets, chosen from the visible shape of the iteration
curve (§1) rather than picked for even spacing: **0.10 / 0.01 / 0.001**.
For each, two proposals are reported:

- **Practical** (mask_bits fixed at 0 — the only lever the current
  architecture can actually realize today; iterations-only search).
- **Exploratory** (joint search over iterations × mask_bits — informs a
  *possible future* narrower-datapath redesign; **not buildable today**).

| Mode (target RMS) | Practical: iterations @ FRACT_W=12 | Practical RMS | Exploratory: (iterations, mask_bits) | Exploratory effective bits | Exploratory RMS |
|---|---|---|---|---|---|
| Low (≤0.10) | **4** | 0.0825 | (4, 6) | 6 | 0.0978 |
| Mid (≤0.01) | **8** | 0.00528 | (8, 2) | 10 | 0.00727 |
| High (≤0.001) | **11** | 0.000861 | (11, 0) | 12 | 0.000861 |

**Reading this table:**
- **"Mid" exactly reproduces the current, already-built 8-iteration
  baseline** — a real, data-backed confirmation that the frozen RTL's
  iteration count corresponds to a sensible ≈0.01-RMS operating point, not
  an arbitrary choice.
- **"Low"**: if a future redesign ever wanted a cheap/fast mode, 4
  iterations alone already hits the 0.10 target; the *exploratory* result
  says such a design could *additionally* run its internal arithmetic at
  only 6 effective fractional bits (half of 12) for only ~19% worse RMS
  (0.098 vs. 0.082) — a genuine area lever IF a narrower datapath were ever
  built for a dedicated low mode, not something realizable in the current
  16-bit-everywhere datapath.
- **"High"**: reaching 0.001 RMS requires 11 iterations (3 more than
  today's baseline) and **no masking headroom is available** — at this
  target, precision is already the binding constraint, not iteration count
  alone, and the exploratory search correctly finds no cheaper point than
  the practical one.

**Wasteful combinations** (`phase0/results/summary_b.json`, an increment
that changes core RMS by <2%):

- **Wasteful iterations** (fixed mask_bits, one more iteration barely
  helps): 27 grid points, concentrated at `iterations=14→15→16` for every
  mask_bits value tested (the ITERATIONS=13 floor from §1 holds regardless
  of masking) — e.g. `(16, mask_bits=0)`: 0.0005694 vs. 0.0005694 at 15
  (identical to displayed precision).
- **Wasteful bits** (fixed iterations, one more bit of precision barely
  helps): 30 grid points, concentrated at **low iteration counts** — e.g.
  `(iterations=1, mask_bits=8→7)`: 0.5800 → 0.5743 (~1% change);
  `(iterations=2, mask_bits=7→6)`: 0.3055 → 0.3015 (~1.3% change). This
  matches §2's finding directly: below ~4 iterations, precision beyond
  ~6 effective bits is already wasted.

## Updated deliverables checklist (Phase 0b)

- [x] Iteration sweep extended to 16; legality checked from RTL source
      (`cordic_stage.sv` domain guard); RTL-verified bit-exact at
      {8,10,12,14,16} (4600 vectors, 0 mismatches); 12-bit quantization
      floor identified at iterations≈13.
- [x] FRACT_W-rescaling precision model replaced with LSB-masking model on
      the real, fixed datapath; joint iterations×mask_bits grid reported;
      explicitly labeled not-RTL-verified for mask_bits>0.
- [x] K analysis extended to n=1..16; shows per-mode K compensation is
      unnecessary throughout, with the apparent-relevance artifact at
      high n explained rather than taken at face value.
- [x] Error reference confirmed as exact floating-point ideal, cross-checked
      against the golden model where they coincide (0 diffs, 1500 vectors);
      sample counts stated for every grid point and RTL check.
- [x] Mode proposal from three error-budget targets (not evenly spaced),
      practical and exploratory variants, with effective-bit counts and an
      explicit wasteful-combination list.
- [x] PROGRESS.md updated (this section); plots and CSVs under
      `phase0/results/` (`*_16.csv`, `sweep_joint_masked.csv`,
      `error_reference_check.csv`, `summary_b.json`, and five new SVGs).

**STOP at this gate, per instruction.** No architecture spec or
implementation has been started.

# Phase 0c — Tightening Phase 0b claims + fixed-design reference family

No RTL edits. Measured numbers only. Stop at this gate.

## 0. Frozen-baseline confirmation

- **`BASELINE.md`**: frozen at commit `df40b4e` ("timing: freeze clock at
  15.0ns; separate measured fact from hypothesis"), 15.0ns clock,
  post-route STA WNS 0.00ns / TNS 0.00ns / worst slack max +2.00ns / min
  +0.32ns, area 55726µm² / 44% utilization, **18546 post-route cell
  instances**, 9-cycle latency, regression 11/11. Includes the Flow v1
  description and the Experiment 2/2b synthesis-approach comparison table
  ("Why 15.0ns"). Present and unchanged.
- **`VERIFICATION.md`**: present and unchanged; every formal task triaged —
  `stage`/`reset`/`conservation` Bounded-verified, `satclamp` Failing
  (genuine), `cfg_align` Not Checked (tool limitation, 3 documented
  resolution options). No unresolved property is left un-triaged.

Both preconditions hold; no gap found, nothing to do here beyond this
confirmation.

## 1. Tightening Phase 0b's mode-proposal and K claims

### 1a. RMS vs. max — stated explicitly, both tabulated

Phase 0b's §5 mode proposal used **RMS error only** against the three
targets 0.10 / 0.01 / 0.001. That was not stated as an RMS-specific choice
at the time. Both metrics for the three practical (mask_bits=0) picks:

| Mode | iterations | max error | RMS error |
|---|---|---|---|
| Low  | 4  | 0.2163  | 0.08248  |
| Mid  | 8  | 0.01382 | 0.005280 |
| High | 11 | 0.002768 | 0.0008609 |

Max error is consistently ~2.5–3.2x the RMS error at the same iteration
count (expected: RMS averages over a mostly-well-behaved core population,
max is set by the single worst core-population vector). Neither the RMS
picks nor the *ranking* of candidate iteration counts change based on which
metric is read off this table — but the two numbers are materially
different, and reporting only one without saying which was hiding that gap.

### 1b. Re-deriving the mode set on MAX-error budgets

Applying the **same three numeric targets (0.10 / 0.01 / 0.001) to max
error instead of RMS**, searched over the full `sweep_joint_masked.csv`
grid (practical = mask_bits=0 only; exploratory = joint search):

| Mode (max-error target) | Practical: iterations | Practical max | Practical RMS (at that point) |
|---|---|---|---|
| Low (≤0.10 max)  | **6**  | 0.05645  | 0.02155 |
| Mid (≤0.01 max)  | **9**  | 0.008618 | 0.002759 |
| High (≤0.001 max) | **not achievable at any tested iteration count** | — | — |

**The answer changes.** Low moves from 4→6 iterations and Mid moves from
8→9 iterations when the same numeric budget is read as a max-error bound
instead of an RMS bound. This is the direct, data-backed answer to
"redefine on max error and re-derive if it changes": **it changes for Low
and Mid.**

The High target is a separate, more important finding: **0.001 max error is
below the quantization floor of this FRACT_W=12 datapath.** Max error vs.
iterations at mask_bits=0 flattens at:

| iterations | max error |
|---|---|
| 11 | 0.002768 |
| 12 | 0.001779 |
| 13 | 0.001311 |
| 14–16 | 0.001558 (floor, does not improve further; note 14–16 max is
  slightly *above* 13's 0.001311 — a single worst-case vector, not a
  monotonic trend, since RMS keeps improving smoothly through the same
  range) |

No iteration count from 1–16 reaches 0.001 max error; the floor is
~0.0013, reached at n=13. A max-error-only High target would need either a
higher floor-aware budget (e.g. ≤0.0015 → n=13) or acceptance that 0.001
was always an RMS-shaped target with no max-error equivalent inside this
datapath.

### 1c. Consequence for the mode set carried into Phase 1

The **physical stage count and the ITERATIONS=11 "High" mode are decided
by Phase 0c's timing-closure result (§2 below), not by this error-budget
arithmetic** — 11 is both the RMS-based High pick and the largest
iteration count that closes at 15.0ns, so it is unambiguous either way.
Low and Mid are less clear-cut: the RMS-based picks (4, 8) are the ones
carried forward as the primary mode set in `ARCH_SPEC.md`, because (a)
mask_bits>0 is not a real, buildable lever today regardless of which
metric is used, so "practical" is the only actionable column, and (b) 8 is
the existing, already-shipped baseline. But the max-error re-derivation
(6, 9) is a legitimate, data-backed alternative reading of the same three
round-number targets, and is recorded as an open, undecided tradeoff in
`DECISIONS.md` rather than silently discarded.

### 1d. "Mid reproduces the baseline" — reworded

Phase 0b's §5 said Mid "exactly reproduces the current, already-built
8-iteration baseline." That is **consistent with, not independent
confirmation of**, the 8-iteration choice: the 0.01 RMS target was a
round number **we** chose for this analysis, not a design requirement
derived from anywhere else, so hitting the existing baseline at that target
is a coherence check on the chosen budget, not proof the budget itself is
correct. Restated: **the existing 8-iteration baseline is consistent with
a ≈0.01-RMS / ≈0.014-max operating point**, one of three round-number
tiers chosen for this analysis — not validated against any independent
error requirement.

### 1e. K-compensation claim — scoped, with n=1..3 explicit

Phase 0b's §3 claim ("per-mode K compensation does not start to matter
anywhere in this range") is scoped here explicitly to **the n range
actually tested (1–16) and actually proposed for modes (4, 8, 11, and the
max-error alternative 6, 9)**. It is *not* a claim about n<1 (undefined) or
n>16 (untested, and per-stage-guard-limited to ≤16 anyway — see §1 of
Phase 0b).

K relative error (fixed RTL constant `K_FIXED=2488` vs. the true per-n
gain), explicit at n=1, 2, 3 — the range where it is largest:

| n | K rel. error | RMS err, fixed K | RMS err, hypothetical correct-per-n K |
|---|---|---|---|
| 1 | 14.12% | 0.5730 | 0.5916 |
| 2 | 3.98%  | 0.2995 | 0.3019 |
| 3 | 1.03%  | 0.1577 | 0.1581 |

Even at n=1–3, where the K constant is most wrong in relative terms, the
*output*-error gap between the fixed K and a hypothetical correct-per-n K
is small relative to the iteration-truncation error itself (e.g. n=1: RMS
0.5730 vs. 0.5916, a ~3% relative difference in RMS *output* error, despite
a 14% error in K itself) — because at low n the iteration-truncation term
dominates total error far more than the K-mismatch term does. **No mode in
the proposed set (4, 6, 8, 9, 11) is at n<4**, so this table is the
worst-case bound for what any actually-proposed mode would see; the
smallest proposed n (4) already shows K error down to 0.26% (Phase 0b §3
table) with a correspondingly negligible output-error gap.

### 1f. Masking results — not-RTL-verified label, explicit pass

Every `MaskedCordicModel` result with `mask_bits > 0` in Phase 0b (§2, §3's
hypothetical-K column combined with masking, §5's exploratory columns) and
in this section's re-derivation (§1b's max-error re-derivation columns for
mask_bits=0 only — no masked results appear there) is a numerical
hypothetical, **not RTL-verified**: no masking hardware exists in the
frozen baseline (`masked_model.py`'s own docstring states this). Only
`mask_bits=0` results are bit-exact to real hardware. This was stated in
`masked_model.py`'s docstring and in Phase 0b §2's prose; this pass adds
the explicit label to the §5 mode-proposal table sections above (§1a, §1b,
§1c all use "practical" vs. "exploratory" column headers specifically so
every masked number sits under an "exploratory" / "not buildable today"
heading, never presented as a real measurement).

## 2. Phase 0c: fixed-design reference family

Frozen flow (`scripts/synth.tcl`, `scripts/pr.tcl`), frozen SDC
(`constraints/cordic.sdc`), frozen 15.0ns clock — **all unchanged**. Only
the `ITERATIONS` parameter varies, via a one-line `chparam -set ITERATIONS
<n> cordic_top` inserted into a **per-run copy** of `synth.tcl`
(`phase0c/synth_iter{4,11,12}.tcl`); each copy's diff against the frozen
`scripts/synth.tcl` is exactly two lines (the `chparam` line plus a
second `hierarchy -check -top cordic_top` re-run immediately after it,
required for Yosys to actually re-elaborate the parameterized submodule
chain — without the second `hierarchy` call, the design retains a
stale, unresolved `cordic_pipeline` sub-instance and `stat -top
cordic_top` crashes with a Yosys-internal `std::out_of_range` after the
netlist is otherwise correctly written; see `phase0c/` for the exact diff).
`ITERATIONS=8` reuses the existing, already-frozen `BASELINE.md` numbers —
not rerun. `output/` was backed up (`output_baseline_iter8_backup/`)
before any new run and restored to the exact frozen ITERATIONS=8 state
afterward; per-config artifacts live in `output_iter{4,11,12}/`.

**Staleness check applied to every run**: `cordic_top_synth.v` mtime <
`cordic_top_routed.v` mtime < `sta_postroute_*.rpt` mtime, verified by
build order (each stage was run to completion, in order, before the next;
no cached/stale artifact was reused across configs).

**Regression**: `tb/cordic_top_tb.sv` / `tb/cordic_pipeline_tb.sv` import
`cordic_pkg::*` directly (not a module parameter) and hardcode expected
output values computed at ITERATIONS=8 specifically — **not usable** as
regression for other ITERATIONS values, and not run as such. Two testbenches
genuinely are ITERATIONS-parameterized and were used:
- `tb/cordic_param_matrix_tb.sv` (pre-existing, `-GITERATIONS=` override):
  a self-checking functional smoke test (K-prescale range check + full
  ITERATIONS-stage chain convergence check against a known z=0 rotation).
- `tb/phase0_cosim_tb.sv` (Phase 0's own cosim harness, `-GTEST_ITERATIONS=`
  override): full bit-exact check against `tb/golden_model.py`, 920
  vectors per config (120 directed + 800 random), regenerated per
  ITERATIONS value via `phase0/gen_bitexact_vectors.py <n>`.

### Results

| ITERATIONS | WNS | TNS | Worst slack max/min | Area | Post-route cells | Latency (cycles) | Regression |
|---|---|---|---|---|---|---|---|
| 4 (new)        | **0.00 ns** | **0.00 ns** | +1.65 / +0.33 ns | 31226 µm² / 44% | 10733 | 5  | param-matrix PASS; cosim 920/920 |
| 8 (existing, BASELINE.md) | 0.00 ns | 0.00 ns | +2.00 / +0.32 ns | 55726 µm² / 44% | 18546 | 9  | 11/11 (BASELINE.md) |
| 11 (new)       | **0.00 ns** | **0.00 ns** | +0.60 / +0.32 ns | 73238 µm² / 43% | 24299 | 12 | param-matrix PASS; cosim 920/920 |
| 12 (new)       | **-0.24 ns** | **-2.69 ns** | -0.24 / +0.31 ns | 78954 µm² / 43% | 25808 | 13 | cosim 920/920 (functionally correct; **timing FAILS**) |

Latency in cycles = ITERATIONS + 1 (confirmed structurally: `VALID_DEPTH =
ITERATIONS + 1` in both `phase0_cosim_tb.sv` and the existing
`cordic_pipeline_tb.sv`, and matches BASELINE.md's 9-cycle figure at
ITERATIONS=8).

**Explicit answer to the required deliverable: ITERATIONS=11 still closes
at 15.0ns** — WNS 0.00ns, TNS 0.00ns, worst slack max +0.60ns. Margin is
much tighter than at 8 (+0.60ns vs. +2.00ns) but still positive. **12 does
not close** — WNS -0.24ns, TNS -2.69ns — the first tested failing point.
11 is therefore the largest ITERATIONS value, under this frozen flow/SDC,
that still meets the 15.0ns clock; this is the measured upper bound on
physical stage count for Phase 1's adaptive design, independent of the
error-budget analysis in §1.

Area and cell count scale roughly linearly with ITERATIONS (31226→55726→
73238→78954 µm² at 4/8/11/12), consistent with each stage being an
independent, non-shared physical resource (no logic sharing across
stages in this architecture) — expected, and a useful sanity check that
the `chparam` mechanism produced genuinely different physically-synthesized
designs rather than, e.g., accidentally reusing the ITERATIONS=8 netlist.

**No RTL was edited.** `scripts/pr.tcl` and `constraints/cordic.sdc` were
used completely unchanged for all three new configs; only the two-line
`chparam`/`hierarchy` insertion into a copy of `scripts/synth.tcl` varied
between runs.

## Deliverables checklist (Phase 0c)

- [x] Step 0: BASELINE.md/VERIFICATION.md re-confirmed frozen/complete.
- [x] Item 1: RMS-vs-max stated explicitly and tabulated; mode set
      re-derived on max-error budgets (changes for Low/Mid, High
      unachievable under the original numeric target); "exactly
      reproduces" reworded to "consistent with"; K claim scoped to
      tested/proposed n range with n=1–3 given explicitly; masking
      results labeled not-RTL-verified throughout.
- [x] Item 2: fixed-design reference family at ITERATIONS=4, 8 (existing),
      11, 12, frozen flow/SDC/clock, one-line-diff synthesis scripts,
      staleness check applied, regression run where genuinely
      parameterized testbenches exist, WNS/TNS/worst-slack/area/cells/
      latency reported for each, explicit answer given on whether 11
      closes at 15ns (yes) and 12 (no).

**STOP at this gate, per instruction.** `ARCH_SPEC.md` follows as a
separate deliverable; no implementation has been started.
