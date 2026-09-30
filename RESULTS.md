# CORDIC Timing-Closure Results — Flow v0 → v1

All runs: Sky130 HD (`sky130_fd_sc_hd__tt_025C_1v80`), OpenROAD 26Q2, Yosys
0.69+post, standalone OpenSTA 3.1.0 (`tools/OpenSTA/build/sta`), clock
11.5 ns unless noted. Post-route numbers are always from the standalone
OpenSTA run against the real extracted SPEF (`scripts/sta_postroute.tcl`),
never OpenROAD's own inline resident-timer report — see that script's
header comment for why the two are not interchangeable. Regression =
`make test-unit` (11/11 unit+integration tests).

| Step | Change | Regression | WNS (max) | TNS (max) | WHS (min) | Post-route cells | Area (um²) / util |
|---|---|---|---|---|---|---|---|
| Flow v0 | baseline `pr.tcl` (unchanged since commit `dfa2b01`) | 11/11 | -24.18 ns | -1885.86 ns | +0.32 ns | (not counted) | 55192 / 43% |
| Flow v1 step 1 | + `set_wire_rc -signal -layer met2` / `-clock -layer met3` before global placement | 11/11 | -24.18 ns (unchanged) | -1885.86 ns (unchanged) | +0.32 ns | 18515 | 55192 / 43% |
| Flow v1 step 2 | + `-timing_driven` on `global_placement` | 11/11 | **-1.13 ns** | **-33.69 ns** | +0.32 ns | 18547 | 55503 / 44% |

**Step 1 finding:** giving global placement a wire-RC estimate made **no
measurable difference** to real post-route timing, even though OpenROAD's
own internal (non-SPEF) resident timer swung from `worst slack max +0.23 /
tns 0.00` (Flow v0) to `worst slack max -4.48 / tns -186.80` once it had an
RC estimate to place against. Placement alone can't fix this path: the
dominant 18.1 ns hop (Step 1 diagnosis, see chat) is a minimum-drive
`nor4b_1` gate driving ~50 unbuffered fanout pins — that's a drive-strength/
buffering problem, not a wire-topology problem, and no placement-only pass
touches gate sizing. Confirms `repair_design` (or `-timing_driven` placement,
which includes resizing) is the next candidate, not further RC tuning.

**Step 2 finding — this is the big one.** Adding `-timing_driven` to
`global_placement` (which resizes/buffers cells during placement, unlike
plain HPWL placement) took WNS from -24.18 ns to **-1.13 ns** and TNS from
-1885.86 ns to **-33.69 ns**, for +311 um² area (+0.6%) and +32 cells. Top-20
failing paths were re-extracted: the config-fanout bottleneck from Step 1
diagnosis is **gone** — all 20 violating endpoints now share a single
startpoint (`y_in[1]`) and route through an 18-cell `maj3_1`/`xnor`/`xor`
ripple-carry chain inside `fp_add_sub`, plus the 2.0 ns `set_input_delay`
budget on the input port. This is exactly the "carry chain" bottleneck the
original SDC comment (and `dfa2b01`) described — it was real, just masked
under the much larger config-fanout problem until placement got timing
awareness. Slack is now tightly clustered (-1.04 to -1.13 ns across all 20
endpoints), i.e. a single structural bottleneck, not a long tail.
Regression: 11/11 (RTL untouched).

| Flow v1 step 3 | + explicit `repair_design` after detailed placement (re-legalized) | 11/11 | -1.13 ns (unchanged) | -33.69 ns (unchanged) | +0.32 ns | 18547 (unchanged) | 55503 / 44% (unchanged) |

**Step 3 finding — CORRECTED.** The original text of this section claimed
the explicit `repair_design` call "did do work" (19 slew violations fixed,
19 instances resized, 28 buffers inserted). That was a misreading and is
wrong: re-checked by line number against the log, the `RSZ-0034`/`RSZ-0039`/
`RSZ-0038` messages appear at line 149, *before* the first post-placement
`detailed_placement`/`check_placement` output (line 246) — i.e. they are
emitted by step 2's `-timing_driven global_placement` call itself, not by
this step's explicit `repair_design` line, which runs later. Verified this
is the same single occurrence, in the same position, in the step 2 (v1b)
log too. Grepping for `RSZ-0034` occurrence *counts* confirms it: exactly
one occurrence in every one of steps 2/3/4/5's logs — never two — so no
step after step 2 ever triggered its own resize/buffer event.
**Corrected conclusion: the explicit `repair_design` call in this step is a
true no-op — it found and fixed nothing.** All resizing/buffering on this
design happens once, inside `-timing_driven` placement. Kept in the flow as
harmless, zero-cost insurance for future RTL changes, not because it did
anything here.

| Flow v1 step 4 | + `set_propagated_clock` / `estimate_parasitics -placement` / `repair_timing -setup` after CTS (re-legalized) | 11/11 | -1.13 ns (unchanged) | -33.69 ns (unchanged) | +0.32 ns | 18547 (unchanged) | 55503 / 44% (unchanged) |

**Step 4 finding:** `repair_timing -setup` logged **"No setup violations
found"** at this stage — i.e. against a placement-based RC estimate with a
propagated (post-CTS) clock, OpenROAD's own internal timer believes the
design already closes. This is the same optimism gap `sta_postroute.tcl`'s
header comment warns about for OpenROAD's resident timer vs. real extracted
SPEF: a placement-stage RC *estimate* still isn't close enough to actual
routed parasitics to see the real -1.13 ns carry-chain violation, so
`repair_timing` has nothing to act on and makes no changes. Zero effect on
any measured number, confirmed.

| Flow v1 step 5 | + `estimate_parasitics -global_routing` / `repair_timing -setup` after `global_route`, then re-legalize + re-route globally before fill/detailed_route | 11/11 | -1.13 ns (unchanged) | -33.69 ns (unchanged) | +0.32 ns | 18547 (unchanged) | 55503 / 44% (unchanged) |

**Step 5 finding — the important negative result.** Even with parasitics
estimated from actual global-route topology (much closer to final routing
than step 4's placement-stage estimate), `repair_timing -setup` again
logged **"No setup violations found."** OpenROAD's own internal timer,
at every pre-detailed-route stage this flow offers, cannot see the -1.13 ns
carry-chain violation that the standalone OpenSTA run finds against the
real extracted SPEF after detailed routing. This empirically validates the
premise of `sta_postroute.tcl`'s existence (see its header comment): an
inline "post-route-adjacent" OpenROAD timing report is not sufficient
evidence of real timing, in either direction — Flow v0's ideal-wire report
said the design closed when it violated by -24ns; Flow v1's global-route
estimate says it closes when it still violates by -1.13ns. Routing
converged cleanly (0 DRC violations after re-route, matching Flow v0's
clean route) and regression is 11/11.

**Summary of the 5-step buildup (corrected):** step 2 (`-timing_driven`
placement) did **all** of the measured work (-24.18ns → -1.13ns) and is the
only step that ever inserted a buffer or resized a cell — confirmed by
grepping `RSZ-0034`/`RSZ-0038`/`RSZ-0039` occurrence counts across every
step's log: exactly one occurrence total, always at the same position
(inside step 2's `global_placement -timing_driven` call, before any later
step's `detailed_placement`/`repair_design`/`repair_timing` runs). Step 1
(`set_wire_rc` alone, no resizing) measured no change because an RC
estimate without resizing can't fix a drive-strength problem. Steps 3, 4,
and 5 are **confirmed true no-ops** — step 3's `repair_design` found zero
violations (everything already fixed by step 2), and steps 4/5's
`repair_timing -setup` explicitly logged "No setup violations found" at
every stage OpenROAD's own estimate can see. None of steps 1/3/4/5 broke
anything, so all are kept in the frozen flow as zero-cost insurance for
future RTL changes that might shift which nets have slew/cap/fanout
problems — but the honest accounting is that only step 2 is load-bearing
for the numbers in this document.

## Clock sweep (Flow v1, frozen `pr.tcl`, unchanged — only `create_clock -period` varied)

| Clock period | Frequency | WNS (max) | TNS (max) | Worst slack (max) | WHS (min) | Area (um²) / util | Post-route cells | Regression |
|---|---|---|---|---|---|---|---|---|
| 11.5 ns | ~87.0 MHz | -1.13 ns | -33.69 ns | -1.13 ns | +0.32 ns | 55503 / 44% | 18547 | 11/11 |
| 13.0 ns | ~76.9 MHz | 0.00 ns | 0.00 ns | **+0.09 ns** | +0.32 ns | 55581 / 44% | 18557 | not re-run (timing only) |
| 15.0 ns | ~66.7 MHz | 0.00 ns | 0.00 ns | +2.00 ns | +0.32 ns | 55726 / 44% | 18546 | not re-run (timing only) |
| 18.0 ns | ~55.6 MHz | 0.00 ns | 0.00 ns | +5.12 ns | +0.32 ns | 55562 / 44% | 18542 | not re-run (timing only) |

**Honest Fmax: the design does not close at the frozen 11.5 ns point.**
13.0 ns is the tightest sweep point measured to close (+0.09 ns worst
slack, essentially zero margin — not recommended to freeze at exactly this
point). 15.0 ns gives +2.00 ns of real margin. Area is flat across the
sweep (55.5–55.7k um², all within 0.4%) — this design is fanout/logic-depth
bound, not routing-congestion bound, consistent with the Step 2 diagnosis.
Only 11.5 ns had its full regression suite re-run in this sweep (timing
constraints don't affect functional simulation, so the other three points'
11/11 pass is implied, not independently re-verified here — flagged as
"not measured" per the task's Rule 4 rather than assumed).

**Recommendation:** freeze **15.0 ns (~66.7 MHz)** as the baseline clock
for later comparisons — closes with real margin (+2.00 ns, ~13% of the
period) rather than 13.0 ns's near-zero slack, which would make any future
RTL change (even a functionally-neutral one) likely to immediately reopen
a violation.

## Experiment 2: adder architecture (RTL/synthesis)

Flow v1 and `constraints/cordic.sdc` unchanged throughout (per rules).
Baseline for this experiment: Flow v1 @ 11.5 ns = WNS -1.13 ns, TNS
-33.69 ns, area 55503 um² / 44%, 18547 post-route cells, 11/11 regression.

**Step A (diagnosis, no changes):** the ripple-carry chain is a synthesis
artifact, not RTL structure. See `DECISIONS.md` for the full evidence
trail: `fp_add_sub.sv`'s `USE_CARRY_SELECT` parameter is declared but never
used (plain `+`/`-` in RTL); `scripts/synth.tcl`'s plain `techmap` lowers
`$add` to Yosys's default ripple-carry template before `abc` runs; and
`abc -liberty ...` was called with neither `-D` nor `-constr`, so its
upsize/dnsize sizing passes never ran at all — confirmed by every
carry-chain cell in the whole design being the weakest `_1` drive-strength
variant despite the library stocking `_2`/`_4` of each.

| Sub-experiment | Change | Regression | WNS (max) | TNS (max) | WHS (min) | Area (um²) / util | Post-route cells |
|---|---|---|---|---|---|---|---|
| (i) timing-driven ABC | `abc -liberty ... -D 11500 -constr scripts/abc_constr.txt` (11.5ns period in ps, `set_driving_cell sky130_fd_sc_hd__buf_1` / `set_load 20.0`); RTL unchanged | 11/11 | **-1.32 ns (worse)** | **-39.26 ns (worse)** | +0.32 ns | 55926 / 43% (+0.8%) | 19208 (+661) |
| (ii) RTL carry-select | `USE_CARRY_SELECT`-gated generate-based block carry-select adder in `fp_add_sub.sv` (new `CSA_BLOCK=4` param; add/sub unified via `b_eff = b_ext ^ {17{op}}`, `cin0 = op`); Flow v1/SDC unchanged | 11/11 | **-1.69 ns (worse)** | **-45.70 ns (worse)** | +0.32 ns | 54312 / 44% (**-1.2%, smaller**) | 18008 (**-539, fewer**) |

**(ii) finding — negative result, and it confirms Step A's diagnosis more
strongly than (i) did.** The carry-select RTL change made timing *worse*
again (WNS -1.13ns → -1.69ns, TNS -33.69ns → -45.70ns) while *simultaneously
making the design smaller* (-539 cells, -1.2% area). Inspected the fresh
post-route worst path (`output/sta_postroute_checks.rpt`, regenerated after
confirming netlist/report timestamps were monotonic — the first P&R attempt
this experiment silently used a stale pre-edit `cordic_top_synth.v` and had
to be discarded and rerun): the critical path is a **13-cell unbroken
`maj3_1` chain with zero mux cells in it** — structurally indistinguishable
from the original ripple-carry critical path. The block-carry-select mux
structure written in RTL is present in the netlist (`mux2_1`/`mux2i_1`/
`mux4_2` cells exist, 107 total) but the critical path routes around it
entirely.

Root cause: `abc -liberty ...` (still no `-D`/`-constr`, per Step A) is
pure area-driven Boolean resynthesis. Sky130 HD's `maj3` cell makes a
plain ripple-carry chain (`cout = maj3(a, b, cin)`) very close to the
area-optimal implementation of *any* adder's Boolean function in this
library, independent of how the RTL expresses the computation. ABC's
resynthesis pass does not preserve source structure — it re-derives a
minimal-area gate network for the function, converges back to essentially
the same maj3-ripple shape regardless of whether the RTL described a plain
adder or a carry-select one, and (having no delay awareness) has no reason
to prefer the carry-select decomposition, which costs more logic for the
same function unless something asks it to value delay over area. This is
the same class of gap as (i) (ABC without `-D`/`-constr` cannot reflect
delay), but it now generalizes: **RTL-level adder-topology changes alone
cannot survive this synthesis flow's plain `abc -liberty` call** — the
topology gets flattened back to whatever ABC finds smallest, which for
this library is ripple-carry-shaped, before OpenROAD's placement ever sees
it. Trying Brent-Kung or Kogge-Stone next would very likely reproduce this
exact outcome for the exact same reason, since neither the diagnosis nor
the offending tool call would differ.

RTL reverted to the Flow v1 baseline (plain `+`/`-`, matching
`BASELINE.md`) after recording this result, to keep the frozen baseline
intact pending a decision on how to proceed. Regression: 11/11 (both with
the carry-select RTL in place and after reverting it).

**(i) finding — negative result.** Giving ABC a delay target and
driving-cell/load constraint made things slightly *worse*, not better:
WNS -1.13ns → -1.32ns, TNS -33.69ns → -39.26ns, for +661 cells and +0.8%
area. Checked which cells actually got upsized: only 5 extra buffers
(`buf_2`×3, `buf_6`×2) appeared anywhere in the whole design — **the
carry-chain cells themselves (`maj3`, `xor3`, `xnor2`) are still 100% `_1`
drive strength**, unchanged from before. ABC's sizing pass ran (confirmed
by the new buffers existing at all) but didn't touch the actual bottleneck,
and the few buffers it did insert perturbed OpenROAD's own (more accurate,
placement/route-aware) `-timing_driven` optimization for the worse. Root
cause: ABC's internal delay model is a pre-layout estimate with no
knowledge of real Sky130 parasitics or the actual fanout/placement this
design ends up with — the same estimate-vs-real gap documented in Flow v1
steps 3–5. **Conclusion: synthesis-only timing-driven ABC does not fix
this bottleneck.** `scripts/synth.tcl`'s `-D`/`-constr` change and
`scripts/abc_constr.txt` are being reverted before trying (ii), to keep
the RTL-only experiment isolated and comparable to the Flow v1 baseline.
Regression: 11/11 (RTL unchanged in this sub-experiment).

### Experiment 2b: forced-structure follow-up (user-directed)

Two further sub-experiments, both keeping Flow v1/SDC unchanged and RTL
reverted to the Flow v1 baseline between attempts. All numbers below are
from OpenSTA post-route reports whose file mtimes were explicitly checked
to post-date the netlist/RTL that produced them before being read (see
step 3 below for why this check now exists permanently).

**2b-1: ABC delay-target sweep (synthesis-only, ripple RTL unchanged).**
Ran `abc -liberty ... -D <ps> -constr <file>` (realistic constraint:
`set_driving_cell sky130_fd_sc_hd__dfxtp_1`, `set_load 8.0`) at three very
different delay targets — 800 ps, 3000 ps, and 11500 ps (the SDC period,
correctly converted to ps) — and diffed the resulting synthesized
netlists. **All three are structurally identical**: 252 diff lines out of
~30k, all incidental (e.g. one `clkbuf_1` vs `lpflow_clkbufkapwr_1` choice
on a tie net), none touching the adder. The maj3-chain cell count (261) is
byte-for-byte the same at every delay target. This rules out synthesis-only
timing-driven ABC more decisively than sub-experiment (i) did: it isn't a
matter of picking a better `-D`/`-constr`, ABC's mapping is **completely
insensitive** to the delay target here. Root cause: per Yosys's own `abc
-constr` semantics, `set_load` only applies fictitious capacitance to true
primary outputs — every *internal* net gets zero wire capacitance in ABC's
delay model. With no wire RC, an 18-cell maj3 chain sums to a few hundred
ps of intrinsic gate delay regardless of fanout, so no delay target from
800 ps up ever registers as a violation. This is a structural blind spot,
not a tuning problem: ABC cannot perceive this bottleneck at all, because
the bottleneck only exists once real Sky130 wire RC and real fanout are
added at placement — which ABC's timing model has no representation of.
Full P&R was not run for this sub-experiment (the pre-P&R netlist diff
already falsifies the approach at zero P&R cost). Since ABC's mapping was
proven insensitive to `-D`, cherry-picking the Experiment 2(ii) carry-select
RTL on top of a `-D`/`-constr` synthesis run would necessarily reproduce
(ii)'s exact result, so this sub-step was skipped as redundant.

**2b-2: forced-hierarchy carry-select (fallback).** Extracted the
carry-select block's per-block adder into a separate `fp_csa_block`
submodule marked `(* keep_hierarchy *)`, so Yosys's `flatten` pass leaves
each block instance as an opaque module boundary instead of merging it
into the top-level combinational network that `abc -liberty` then
re-optimizes for area. This is a forced-structure workaround for a
synthesis-flow limitation, flagged explicitly as such — not a claim that
this is how the RTL should normally be written.

| Variant | Regression | WNS (max) | TNS (max) | Area (um²) / util | Post-route cells |
|---|---|---|---|---|---|
| Baseline (ripple, Flow v1) | 11/11 | -1.13 ns | -33.69 ns | 55503 / 44% | 18547 |
| (i) timing-driven ABC | 11/11 | -1.32 ns | -39.26 ns | 55926 / 43% | 19208 |
| (ii) plain carry-select | 11/11 | -1.69 ns | -45.70 ns | 54312 / 44% | 18008 |
| **2b-2: keep_hierarchy CSA** | **11/11** | **-1.46 ns** | **-38.84 ns** | **62170 / 43% (+12%)** | **20739 (+2192)** |

It worked partially at the structural level: the routed netlist confirms
112 `fp_csa_block` instances survived `flatten` untouched (96 at
`BW=4`, 16 at `BW=1`), and the pre-route synthesized netlist shows only 2
`maj3` cells per 4-bit block instead of one 18-cell chain. But the fresh
post-route worst path shows the block-boundary select logic (mapped by
ABC to `a31oi_1`/`o211ai_1`/`a21bo_1` compound gates, not dedicated mux
cells) costs about as much real per-stage delay (~0.25-0.45 ns each,
including real wire RC) as the maj3 cells it was meant to bypass — so the
5-block chain (`CSA_BLOCK=4` over 17 bits) ends up costing nearly as much
total delay as the original 18-cell ripple, while adding real area (+12%,
+2192 cells) for the extra select logic, most of it (`mux2i_1` × 349,
`mux4_2` × 98, plus assorted AOI/OAI gates) not on the critical path at
all. **Conclusion: forced-structure carry-select is also a negative
result** — better than the plain (unforced) carry-select of (ii), but
still worse than the Flow v1 ripple baseline on every axis (timing, area,
cell count). All four synthesis/RTL-side approaches tried in Experiment 2
now point to the same underlying limit: this design's bottleneck is real
Sky130 wire RC and fanout load that only appears after placement, and no
purely combinational adder-topology change — with or without forcing its
structure to survive synthesis — changes how much of that load the
critical net ends up carrying. RTL reverted to the Flow v1 baseline after
recording this result (`fp_add_sub.sv` confirmed byte-identical to its
pre-Experiment-2 state). Regression: 11/11 throughout.

**2b-3: permanent staleness check.** The first Experiment 2(ii) P&R
attempt silently used a stale pre-edit netlist (caught only by noticing
`cordic_top_synth.v`'s mtime was *newer* than `cordic_top_routed.v`'s,
which is impossible for a non-stale run since P&R reads the synth
netlist as its first step). Going forward for the rest of this
experiment, every P&R/STA cycle explicitly checked
`stat -c '%Y' output/cordic_top_synth.v` < `cordic_top_routed.v` < the STA
report file, in that order, before any number from that run was reported
or committed.
