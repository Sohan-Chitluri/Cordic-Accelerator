# ARCH_SPEC.md — Adaptive per-transaction-mode CORDIC (Phase 1)

**Status: SPEC ONLY. No implementation. No RTL edits.** This document
covers the architecture options, their predicted costs, and the guards and
hazards a future implementation phase must resolve — nothing here has been
built or measured on real hardware. Every timing/area claim below is
labeled qualitative/predicted, distinct from Phase 0c's measured fixed-design
numbers in `PROGRESS.md`.

## 0. Physical stage count and mode set

**11 physical stages.** Per Phase 0c (`PROGRESS.md`), ITERATIONS=11 is the
largest iteration count that still closes the frozen 15.0ns clock under
the frozen flow (WNS 0.00ns, worst slack max +0.60ns); ITERATIONS=12 fails
(WNS -0.24ns, TNS -2.69ns). 11 is therefore both the timing-closure ceiling
and the RMS-error-based "High" mode pick — an 11-physical-stage design is
the largest fixed hardware footprint this flow supports at this clock.

**Mode support: arbitrary iteration counts 1..11.** While three primary
reference operating points (4 / 8 / 11 iterations) are carried forward for
benchmarking from Phase 0c §1c (4 = Low RMS knee, 8 = baseline Mid,
11 = timing-closed High), the hardware architecture natively supports any
integer iteration count from 1 to 11 via a 4-bit configuration field.
This eliminates artificial quantization to just 3 hardcoded modes while
retaining 4/8/11 as the comparison anchors against the fixed family.

The max-error alternative (6 / 9 / —) is a legitimate, data-backed
different reading of the same round-number budgets and is **natively
executable** under this 1..11 scheme (running modes 6 and 9 directly),
completely resolving the previous mode-set hazard in `DECISIONS.md`.

## 1. Mode field in transaction metadata

### 4-bit Mode Definition and Semantics

`cfg_iterations` (4-bit input, `rtl/cordic_pipeline.sv` port list) is
revived as genuine per-transaction configuration metadata:
- **Encoding:** 4-bit unsigned integer representing iteration count `1..11`.
- **Valid range:** `1 <= cfg_iterations <= 11`. Exactly `cfg_iterations`
  stages execute rotation; remaining stages pass data through unmodified.
- **Underflow/Zero:** `cfg_iterations == 0` is reserved and clamped to `1`.
- **Clamping & Sticky Error:** Any configuration value `cfg_iterations > 11`
  (12..15) is automatically clamped by admission logic to `11` (ensuring safe
  full-precision execution), and asserts a sticky status flag
  `status_mode_clamped_sticky`. This flag remains asserted until cleared by
  a hardware reset or an explicit status-clear handshake.

### Config-vs-Data Same-Cycle Capture Semantics

To support dynamic per-transaction reconfiguration without pipeline flushes:
- **Exact Capture Point:** When `config_valid && config_ready` asserts in the
  **same cycle** as `valid_in && ready_out` (cycle $t$), the newly admitted
  transaction captures the updated `cfg_iterations` and `cfg_saturate`
  presented in cycle $t$.
- **In-flight Isolation:** Transactions admitted in cycles $< t$ have already
  latched their configuration into stage shift registers and remain completely
  unaffected by the cycle-$t$ update.
- **Directed Test:**
  1. Cycle 0: Admit transaction $T_0$ with `cfg_iterations = 4`, `valid_in = 1`.
  2. Cycle 1: Assert `config_valid = 1`, `cfg_iterations = 11`, alongside `valid_in = 1` for transaction $T_1$.
  3. Cycle 2: Deassert `valid_in` and `config_valid`.
  4. Verification: When $T_0$ emerges (cycle 12), its output matches 4-iteration precision ($RMS \approx 0.082$); when $T_1$ emerges (cycle 13), its output matches 11-iteration precision ($RMS \approx 0.00086$).

### Per-Stage Decoded, Replicated Active Bits

Instead of shifting a 4-bit mode value down the pipeline and requiring each
stage to implement a 4-bit magnitude comparator `(i < mode)`, the mode is
decoded **once** at admission into an 11-bit thermometer active vector:
$$\text{active\_mask}[i] = (i < \text{cfg\_iterations}) \quad \text{for } i \in [0, 10]$$

To eliminate high fanout on the stage timing paths:
- Each stage $i$ registers its active bit into **three dedicated local copies**:
  - `active_x_r[i]`: drives X-datapath operand isolation AND gates (fanout = 16)
  - `active_y_r[i]`: drives Y-datapath operand isolation AND gates (fanout = 16)
  - `active_z_r[i]`: drives Z-datapath angle isolation AND gates + `cin` gating (fanout = 17)
- **Fanout Bound:** Each replicated active bit drives strictly $\le 17$ loads,
  preventing large buffer trees and eliminating select-line routing congestion.

### Carrying Metadata Through the Skid FIFO and Backpressure

The output skid FIFO stores the 4-bit `mode` tag alongside data payloads
(`x_out`/`y_out`/`z_out`/`overflow`). Backpressure only affects admission
(`ready_out`) and output pop (`ready_in`); stages free-run synchronously,
advancing active bits and data in strict lockstep every cycle.

### 2. B1 — gating-only (skipped stages pass through via operand isolation)

**Mechanism.** All 11 stages remain physically instantiated and clocked;
for any mode $n \in [1, 11]$, stages beyond count $n$ ($i \ge n$) pass their
inputs straight to their outputs unmodified ($x/y/z$ preserved, `valid`
propagated, 0 rotation applied). Latency is **fixed at 12 cycles (ITERATIONS+1)
for every mode** — mode 4 takes exactly as long as mode 11. Ordering is
strictly FIFO and preserved globally with 0 arbitration logic.

**Gating method: input operand isolation, NOT output mux.**
Earlier drafts proposed an output multiplexer per stage. That is replaced with
**input operand isolation** into the existing `fp_add_sub` blocks:
- Zero the shifted operands and atan constant before the add/sub XOR polarity network:
  $$\text{x\_shift\_iso} = \text{active\_x\_r}[i] \text{ ? } (x\_in \ggg i) : 16'd0$$
  $$\text{y\_shift\_iso} = \text{active\_y\_r}[i] \text{ ? } (y\_in \ggg i) : 16'd0$$
  $$\text{angle\_iso} = \text{active\_z\_r}[i] \text{ ? } \text{STAGE\_ANGLE}[i] : 16'd0$$
- Gate carry-in with active state:
  $$\text{cin} = \text{active\_z\_r}[i] \ \& \ \text{sub}$$
- **Passthrough computation:** When $\text{active} = 0$, both operands and $\text{cin}$
  are 0, causing the stage adder to compute $x\_comb = x\_in + 0 = x\_in$,
  $y\_comb = y\_in + 0 = y\_in$, and $z\_comb = z\_in + 0 = z\_in$.
- **No clock gating:** Stage output flip-flops are clocked unconditionally every cycle.
  Skipped stages must capture and forward passthrough data synchronously to preserve
  pipeline continuity for concurrent multi-transaction flow.

**Critical-path & timing advantage over output mux:**
An output mux places a 2:1 data selector in series after the adder carry chain,
directly threatening the tight +0.60ns slack margin at ITERATIONS=11.
In contrast, operand isolation inserts simple AND gates at the *inputs* of the
shifted path and constant ROM, which settle early in parallel with stage input arrival.
The adder itself computes the passthrough value, adding **zero series gate delay**
to the output stage-register arrival path.

**Feasibility Acceptance Gate (from Task 1 post-route power audit):**
B1 gating is considered viable if the savable combinational power fraction at
mode 4 is above 15% of total power. Measured post-route Sky130 HD gate-level
activity (Task 1) demonstrates:
- Fixed-11 total power: 11.42 mW; combinational power: 4.06 mW (35.6% of total).
- Savable power upper bound at mode 4: $4.06\text{ mW} \times (11 - 4)/11 = 2.58\text{ mW}$ (22.6% of total power).
- Since 22.6% > 15%, the feasibility gate **passes**.

## 3. B2 — early exit (discussion only — non-baseline architecture)

*Note: B2 remains strictly a discussion-only architecture section; it is NOT the baseline design.*

**Mechanism.** Physical output taps after `cordic_stage` 4 and stage 8,
each feeding an independent exit path. Latency would vary by mode (5, 9, 12 cycles).

**Critical semantic change: drops global ordering.**
Because stages complete at different absolute cycle delays, a mode-11 transaction
admitted in cycle $t$ and a mode-4 transaction admitted in cycle $t+1$ would finish
in cycles $t+12$ and $t+6$, respectively. B2 **explicitly drops global admission
ordering** across mixed-mode traffic. Restoring global ordering would require a
heavy reorder buffer (ROB) keyed on admission transaction tags.

**Throughput degradation under mixed traffic:**
While single-mode traffic achieves 1 transaction/cycle, mixed-mode traffic causes
severe head-of-line blocking and arbitration contention across the three completion queues.
If two taps finish concurrently, one tap must stall, degrading sustained throughput
substantially below 1 transaction/cycle. B1 avoids this contention entirely.

**What changes for formal ordering properties.** VERIFICATION.md's
`conservation` property (bounded-proven) checks no-loss/no-duplication
under a **fixed-latency** assumption implicit in a single-path pipe; B2
breaks that assumption outright — conservation would need to be
re-specified per-tap (no loss/duplication *within* each tap's own FIFO,
which is a structurally identical property to today's, just three
instances of it) plus a **new** property asserting the arbiter itself
never drops or duplicates a tap-completed transaction while multiplexing
onto the shared output. This is a strictly larger formal surface than B1
(which preserves the existing single-path, fixed-latency conservation
property unchanged).

**Predicted critical-path impact (qualitative).** Two new tap points, each
requiring: (a) a small FSM/mux to route a completing transaction into its
own tap FIFO, and (b) the cross-tap output arbiter. (a) is local to each
tap and unlikely to be worse than B1's per-stage mux; (b) is the larger
risk — arbitrating three independent-depth sources onto one shared,
timing-critical output bus is a new piece of combinational logic with no
counterpart in the current baseline, and its complexity (priority
encoding across 3 sources, each carrying a full WIDTH-bit payload) makes
it the most likely of any Phase 1 mechanism to threaten the already-tight
+0.60ns margin at ITERATIONS=11. **How this would actually be measured:**
same as B1 — build it, run the frozen flow, compare WNS against the
ungated ITERATIONS=11 baseline; additionally, measure realized throughput
under a synthetic mixed-mode traffic pattern (e.g. round-robin 4/8/11
admission) in simulation to quantify the "throughput cost on mixed
traffic" claim above with real numbers rather than qualitative reasoning.

## 4. Fixed K constant in all modes

`rtl/cordic_lut.sv`'s `K_FIXED = 2488` (and its shift-add realization,
`<<11,<<9,<<6,<<3`) is a **literal constant**, with zero dependence on any
parameter — the real hardware always uses this same K regardless of how
many iterations actually run (confirmed by direct source read; no
parameter threading exists to make it otherwise without an RTL change to
`cordic_lut.sv` itself).

**This spec keeps K_FIXED unchanged in every mode**, justified directly by
Phase 0c §1e's K analysis: even at the smallest proposed mode (n=4), the K
relative error is 0.26% (Phase 0b §3) with a correspondingly negligible
*output*-error effect (the iteration-truncation error dominates total
error by roughly an order of magnitude or more at every proposed n ∈
{4, 8, 11}). Per-mode K compensation is not justified by any measured data
in this range and would add a mode-dependent multiplier/lookup with real
area and critical-path cost for no measured benefit.

## 5. Masking — SECONDARY experiment, low mode only

**Not part of the primary B1/B2 architecture.** LSB masking
(`phase0/masked_model.py`, `MaskedCordicModel`) is **not RTL-verified for
mask_bits>0** — no masking hardware exists anywhere in the frozen
baseline, and this spec does not propose adding any. It is recorded here
only because the Phase 0c/Phase 1 instruction explicitly asks for it as a
secondary, low-mode-only experiment to scope for a *possible future*
phase, not to build now.

- **Where it would apply.** Only the low mode (4 iterations) — Phase 0b
  §5's exploratory result shows masking headroom shrinks sharply with
  iteration count and is already gone entirely at the High mode (11
  iterations, mask_bits=0 is the only point that meets the target). A
  masked low mode would need its own narrower internal register/functional
  path, not the current shared 16-bit-everywhere datapath — this is a
  datapath change, not a mode-select change, and is a materially larger
  RTL effort than B1/B2.
- **Output realignment.** `MaskedCordicModel` masks in place (zeroing low
  bits of a value that stays in the same Q12 container throughout) rather
  than rescaling — so "realignment" in the sense of a shift/rescale step
  is **not needed** by this specific masking scheme; the masked value is
  already in the same numeric domain as an unmasked one. This is a
  property of the *chosen* masking scheme, not a general fact about
  narrower datapaths — a genuinely narrower physical register width (as
  opposed to LSB-zeroing a full-width register) would need real
  realignment/rescale logic at its boundary with the full-width datapath,
  which this spec does not attempt to design.
- **Interaction with saturation.** `MaskedCordicModel` masks *after* the
  existing saturating add/sub (`_addsub`, reusing the same MAX_POS/MIN_NEG
  clamp as the real RTL) — so saturation behavior is unchanged by masking
  in the model, and a hypothetical masked-low-mode hardware path could
  reuse the existing `cordic_stage` saturation logic unmodified, masking
  only its stage-to-stage feedback values. This is the one piece of
  the masking experiment that transfers cleanly to a real design if ever
  pursued.

## 6. Guards rejecting unsupported configurations

The existing parameter-domain guard pattern in `rtl/cordic_stage.sv`
(`FRACT_W_SUPPORTED`, `STAGE_IDX_SUPPORTED`, `WIDTH_SUPPORTED`, combined
via a compile-time divide-by-zero `STATIC_ASSERT_STAGE_DOMAIN` plus a
redundant `initial $fatal`) is a **compile-time** guard on fixed RTL
parameters — it cannot guard a *runtime*, per-transaction mode value,
which is exactly the new surface Phase 1 introduces. Phase 1 implements
runtime admission clamping and status signaling:

- **Mode clamping and sticky flag:** To avoid deadlock or rejecting transactions
  (since `config_ready` is unconditional once out of reset), the admission logic
  guards runtime mode values:
  - If `cfg_iterations == 0`: Clamped to `1`.
  - If `cfg_iterations > 11`: Clamped to `11` (full precision) and asserts the
    sticky status flag `status_mode_clamped_sticky`. This flag remains asserted
    until hardware reset or explicit register clear.
- **B2-specific: tap FIFO overflow.** Each tap's own completion FIFO
  (§3) has a fixed depth; if arbitration starves one tap long enough, that
  tap's FIFO can overflow. The existing pipeline's overall admission
  guard (`ready_out` gated by `reserved_count < FIFO_DEPTH`) only protects
  the *single* shared FIFO today; a B2 design needs either per-tap credit
  tracking feeding a single combined `ready_out`, or per-mode backpressure
  (different `ready_out` semantics per mode) — undecided, recorded as a
  hazard in `DECISIONS.md`.

## 7. Comparison plan: adaptive-11 per mode vs. fixed-4/8/11 family

Phase 0c's fixed-design reference family (ITERATIONS=4/8/11, each its own
independently-synthesized fixed design) and the Fixed-11 ungated baseline
are the ground truth to compare against once a real adaptive design exists:

| Metric | Fixed-11 Baseline (no adaptation) | Fixed family (Phase 0c, measured) | Adaptive-11 (future, per mode) |
|---|---|---|---|
| Area | 73,238 µm² (measured) | 31,226 / 55,726 / 73,238 µm² (4/8/11) | One fixed 11-stage area (≥73,238 µm² baseline + mode-tag/operand isolation overhead) for ALL modes |
| WNS/TNS at 15.0ns | 0.00 / 0.00 ns (worst slack +0.60ns) | 0.00 / 0.00 ns at all three (4, 8, 11 all close) | B1: target WNS 0.00ns (operand isolation on inputs avoids output mux penalty). B2: unknown / high risk at arbiter |
| Latency (cycles) | 12 cycles | 5 / 9 / 12 (mode-matched, ITERATIONS+1) | B1: fixed 12 cycles for every mode. B2: 5/9/12 per mode |
| Throughput (single-mode) | 1/cycle after fill | 1/cycle after fill, per fixed design | B1: 1/cycle after fill, any single mode. B2: 1/cycle after fill, single mode |
| Throughput (mixed-mode) | N/A (single mode only) | N/A (fixed designs don't mix modes) | B1: 1/cycle sustained (no contention). B2: degraded by arbiter contention |
| Power (Mode 4 / 8 / 11) | 11.42 mW (flat across all workloads) | 4.73 / 8.88 / 11.42 mW (measured gate-level) | B1: Mode 11 ≈ 11.42 mW; Mode 4 target ≤ 8.84 mW (saving up to 2.58 mW combinational) |
| Formal Equivalence | Self | Golden float/fixed model | **Bit-identical equivalence:** Adaptive-11 operating in mode $n$ must produce outputs bit-identical to Fixed-$n$ for all $n \in [1, 11]$ under identical test vectors |

**The headline question this comparison plan answers**: is the area+
complexity cost of ONE adaptive-11 design (paid once) smaller than the
combined area of shipping the fixed family (4+8+11 = 160,190 µm² summed, if
all three were needed simultaneously as separate hardware instances) —
and does B1 preserve enough energy savings without sacrificing 15.0ns timing closure.

## Summary of unresolved hazards (see `DECISIONS.md` for full entries)

1. **Mode-set choice:** RESOLVED. The native 4-bit `1..11` mode encoding allows
   executing both the RMS knee points (4/8/11) and the max-error round-number points
   (6/9) without hardware re-synthesis.
2. **Config-admission rejection hazard:** RESOLVED. Runtime mode inputs $> 11$
   are clamped to 11 and assert `status_mode_clamped_sticky`, preventing deadlock
   without requiring an admission-reject signal.
3. **B1 timing closure risk:** RESOLVED at architecture level by replacing the
   series output multiplexer with parallel input operand isolation (AND gating
   shifted inputs and constant ROM).
4. **B2 per-tap FIFO admission/backpressure semantics:** UNRESOLVED. Retained as
   a hazard in `DECISIONS.md` if early-exit B2 is ever investigated. B2 is strictly
   non-baseline.
