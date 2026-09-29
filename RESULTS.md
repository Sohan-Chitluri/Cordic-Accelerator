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
