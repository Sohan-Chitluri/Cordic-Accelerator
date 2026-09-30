# CORDIC Accelerator — Frozen Timing-Closure Baseline (Flow v1, 15.0 ns)

**Frozen at commit:** `df40b4e` (RTL: `fp_add_sub.sv` at its Flow v1
baseline, byte-identical since `a492b44`; SDC: 15.0 ns clock)
**Branch:** `repair/cordic-e107100`

All later timing/area/power comparisons in this project must use `pr.tcl`
unchanged from this commit, and `constraints/cordic.sdc`'s 15.0 ns clock
unless a new, separately-measured experiment changes it. If the flow or
clock needs to change again, that is a new experiment with its own
measurement, not a silent edit to this one.

## Tool versions

| Tool | Version |
|---|---|
| Yosys | 0.69+post (git sha1 v0.69, Release) |
| OpenROAD | 26Q2 |
| OpenSTA (standalone, `tools/OpenSTA/build/sta`) | 3.1.0 |
| Verilator (regression only) | 5.052 |
| SymbiYosys / z3 (formal only) | sby + z3, see VERIFICATION.md |
| PDK | Sky130 HD, `sky130_fd_sc_hd__tt_025C_1v80` (nom corner) |

All via `nix develop` (see `flake.nix` / `flake.lock` for exact pins).

## Constraints (frozen `constraints/cordic.sdc`)

- **Clock: 15.0 ns period** (was 11.5 ns; changed in this freeze — see
  "Why 15.0 ns, not 11.5 ns or 13.0 ns" below), name `clk`
- Setup uncertainty: 0.5 ns; hold uncertainty: 0.1 ns
- Input delays: 2.0 ns max / 0.5 ns min, applied to `x_in`/`y_in`/`z_in`/
  `valid_in`, `cfg_iterations`/`cfg_saturate`/`config_valid`, `ready_in`
- Output delays: 3.0 ns max / 0.5 ns min (data/valid/overflow/irq), 2.0 ns
  max / 0.5 ns min (`ready_out`, `config_ready`)
- No false paths, no multicycle paths (single clock domain)

## Flow v1 (5 incremental steps over Flow v0) — what actually did work

Re-verified per this freeze's "before starting" requirement (checking
buffers inserted / cells resized per step, not just assuming from the
step's own commit message):

| Step | Change | Did real work? |
|---|---|---|
| 1 | `set_wire_rc -signal -layer met2` / `-clock -layer met3` before global placement | Yes — sets the RC model `-timing_driven` (step 2) resizes against; not separately measurable in isolation but a precondition for step 2. |
| 2 | `global_placement -density 0.6 -timing_driven` | **Yes — this step did essentially all the work.** Its internal resizer pass is the only place in the whole flow where the RSZ-0034/0038/0039 buffer-insertion/resize log lines appear (confirmed by exact log line position relative to each step's own commands, and by `grep -c` occurrence counts: exactly one occurrence total across all 5 steps' logs, always positioned before that step's own added commands execute). Took WNS from -24.18 ns to -1.13 ns at 11.5 ns with zero RTL changes. |
| 3 | Explicit `repair_design` + `detailed_placement` + `check_placement` after the original detailed placement | **Confirmed no-op.** Originally miscredited with doing work in this step's own commit message (`09929fe`) — corrected after re-verification (`e5bf272`) once the log-line-position check was actually done, per this baseline's requirement. |
| 4 | `set_propagated_clock [all_clocks]` + `estimate_parasitics -placement` + `repair_timing -setup` + re-legalize, after CTS | Confirmed no-op (same log-position/occurrence-count check as step 3). |
| 5 | `global_route` → `estimate_parasitics -global_routing` → `repair_timing -setup` → re-legalize → re-route globally → `filler_placement` moved to run last → `detailed_route` | Confirmed no-op for the `repair_timing` call itself, but the re-route it triggers re-converges to 0 DRC violations (that part is real, just not a timing improvement). |

**Net finding:** only step 2 (`-timing_driven` global placement) moves any
timing number in this flow. Steps 3-5 are no-ops for timing as currently
sequenced (their resizer calls run against estimated, non-SPEF parasitics
that already show no violation by the time they run). This is a real,
re-verified finding, not carried over unchecked from the original Flow v1
work.

## Why 15.0 ns, not 11.5 ns or 13.0 ns

11.5 ns does not close under Flow v1: WNS -1.13 ns, TNS -33.69 ns (real
extracted SPEF, standalone OpenSTA). Four synthesis/RTL-side approaches
were tried against this gap in Experiment 2/2b (each its own commit, each
reverted after measurement, full detail in RESULTS.md):

| Approach | WNS @ 11.5ns | TNS @ 11.5ns | vs. baseline |
|---|---|---|---|
| Baseline (ripple, Flow v1) | -1.13 ns | -33.69 ns | — |
| (i) synthesis-only timing-driven ABC | -1.32 ns | -39.26 ns | worse |
| (ii) plain RTL carry-select | -1.69 ns | -45.70 ns | worse |
| 2b-1: ABC `-D` sweep (800/3000/11500 ps) | n/a — netlist proven byte-identical at every target, no P&R run | n/a | falsified pre-P&R |
| 2b-2: forced-hierarchy (`keep_hierarchy`) carry-select | -1.46 ns | -38.84 ns | worse |

All four measured worse than the plain ripple baseline. See RESULTS.md
Experiment 2/2b for the full per-attempt analysis, including the explicit
separation of **measured fact** (the four numbers above; the `-D`-sweep
netlist-identity result) from **hypothesis** (that this generalizes to "no
adder topology can help" — only carry-select variants were tried;
Brent-Kung/Kogge-Stone remain untested and are flagged as an untried
lever, not ruled out).

The clock sweep (Flow v1, RTL unchanged) found:

| Clock period | WNS (max) | TNS (max) | Worst slack (max) | Area / util | Cells |
|---|---|---|---|---|---|
| 11.5 ns | -1.13 ns | -33.69 ns | -1.13 ns | 55503 um² / 44% | 18547 |
| 13.0 ns | 0.00 ns | 0.00 ns | +0.09 ns | 55581 um² / 44% | 18557 |
| **15.0 ns (frozen)** | **0.00 ns** | **0.00 ns** | **+2.00 ns** | **55726 um² / 44%** | **18546** |
| 18.0 ns | 0.00 ns | 0.00 ns | +5.12 ns | 55562 um² / 44% | 18542 |

13.0 ns closes but with ~0 margin (+0.09 ns), which is not a safe frozen
point given normal corner/OCV/model-to-model variation. 15.0 ns gives a
real, measured +2.00 ns margin at essentially the same area/cell count as
11.5/13.0 ns (post-route cell count is *not* monotonic with clock period
in this data — 18546 at 15.0 ns is actually the lowest of the four points
measured — so the margin at 15.0 ns is not being bought with extra area).
18.0 ns gives more margin still but was not chosen: 15.0 ns already gives
a comfortable margin without giving up more frequency than needed.

**Re-verified fresh for this freeze** (not reused from the earlier sweep,
per the permanent staleness check below): WNS 0.00 ns, TNS 0.00 ns, worst
slack (max) **+2.00 ns**, worst slack (min) +0.32 ns, area 55726 um² / 44%
utilization, 18546 post-route cell instances, 0 slew/max-capacitance/
max-fanout violations in the post-route STA report, regression 11/11,
latency **9 cycles** (`VALID_DEPTH = ITERATIONS + 1 = 8 + 1`, unchanged —
RTL is at its Flow v1 baseline, no latency-affecting change was made in
this freeze).

## Permanent staleness check (added this freeze)

An Experiment 2(ii) P&R run silently used a stale pre-edit netlist once
during this work (caught only because `cordic_top_synth.v`'s mtime was
newer than `cordic_top_routed.v`'s, which is impossible for a valid run).
Going forward, every P&R/STA cycle in this project should verify, in
order, before trusting any number: `stat -c '%Y' output/cordic_top_synth.v`
< `cordic_top_routed.v`'s mtime < the relevant `output/sta_postroute_*.rpt`
mtime. All numbers in this document were produced with that check applied.

## Known-stale artifact this baseline corrects

Every previously-recorded post-route number (the SDC's own old comment,
commit `dfa2b01`, and the -3.16ns/-84.84ns figure supplied for the
original task) predates RTL merges at HEAD (`37d7249` skid FIFO, `05e9725`
per-transaction config/overflow tagging, `3bd6fe6`/`348d22d` MIN_NEG
fixes, `46af47a` cordic_lut guard). See `DECISIONS.md` for the full trace.
Treat this document, not any of those, as authoritative going forward.

## Open items not yet resolved

- **Pipeline-boundary rebalance (Experiment 2 Step B-iii)** was not
  attempted — explicitly skipped per direction, in favor of freezing at
  15.0 ns now. This remains an untried, materially different lever (moves
  the register boundary rather than changing combinational adder
  topology) if 11.5-13.0 ns closure is ever needed again.
- **Brent-Kung / Kogge-Stone prefix adders** were not attempted — flagged
  above as untested, not ruled out by the carry-select negative results.
- LVS not re-run against current RTL (`docs/PLACE_ROUTE_DRC.md` should be
  treated as stale until it is); DRC re-verified clean under Flow v1 at
  15.0 ns (0 violations, from the fresh P&R run backing this document).
- Formal properties: triaged separately in `VERIFICATION.md` (proven /
  bounded / failing, with reasons) — not modified in this pass; one
  discrepancy from that document's stale expectations is flagged there
  (`cfg_align`) and needs a decision, not a silent fix.
