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

**Step 3 finding:** the explicit `repair_design` call did do work — log shows
it found 19 slew violations, resized 19 instances, and inserted 28 buffers
in 20 nets — but final post-route WNS/TNS/area/cell-count are all
bit-identical to Step 2. `-timing_driven` global placement already runs its
own internal repair_design pass (visible in the log as `GPL-0107
"Timing-driven: repair_design"`), and it already covers the paths that
matter; the slew violations my explicit call fixed were on nets with slack
to spare, not on the critical carry chain. **Conclusion: explicit
`repair_design` is redundant given `-timing_driven` placement is already
present** — kept in the flow for now since it's harmless and cheap, but it
is not the reason Step 2 closed most of the gap.

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

**Summary of the 5-step buildup:** step 2 (`-timing_driven` placement) did
essentially all of the work (-24.18ns → -1.13ns). Steps 1, 3, 4, and 5 each
measured zero further change — not because they're broken, but because
they operate on RC estimates/repair targets that either don't reach the
real critical path (steps 1, 3) or can't see it at all pre-route (steps 4,
5). None of steps 1/3/4/5 broke anything either, so all are kept in the
frozen flow below as no-cost insurance for future RTL changes that might
shift which nets have slew/cap/fanout problems.

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
