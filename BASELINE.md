# CORDIC Accelerator — Frozen Timing-Closure Baseline (Flow v1)

**Frozen at commit:** `8fc0930c03da9c20936a7fc62b4a6a523eb4d05d`
**Branch:** `repair/cordic-e107100`

All later timing/area/power comparisons in this project must use `pr.tcl`
unchanged from this commit. If the flow needs to change again, that is a
new experiment with its own measurement, not a silent edit to this one.

## Tool versions

| Tool | Version |
|---|---|
| Yosys | 0.69+post (git sha1 v0.69, Release) |
| OpenROAD | 26Q2 |
| OpenSTA (standalone, `tools/OpenSTA/build/sta`) | 3.1.0 |
| Verilator (regression only) | 5.052 |
| PDK | Sky130 HD, `sky130_fd_sc_hd__tt_025C_1v80` (nom corner) |

All via `nix develop` (see `flake.nix` / `flake.lock` for exact pins).

## Constraints (unchanged from `constraints/cordic.sdc`)

- Clock: 11.5 ns (period), name `clk`
- Setup uncertainty: 0.5 ns; hold uncertainty: 0.1 ns
- Input delays: 2.0 ns max / 0.5 ns min (data + config + ready)
- Output delays: 3.0 ns max / 0.5 ns min (data/valid/overflow/irq), 2.0 ns
  max / 0.5 ns min (ready_out, config_ready)
- No false paths, no multicycle paths (single clock domain)

## Flow v1 (5 incremental steps over Flow v0, all measured — see RESULTS.md)

1. `set_wire_rc -signal -layer met2` / `-clock -layer met3` before global placement
2. `global_placement -density 0.6 -timing_driven` (**this step did essentially all the work**)
3. `repair_design` + re-legalize, after detailed placement
4. `set_propagated_clock` + `estimate_parasitics -placement` + `repair_timing -setup` after CTS, re-legalized
5. `estimate_parasitics -global_routing` + `repair_timing -setup` after global route, then re-legalize + re-route globally, filler placement moved to run last (after step 5, before detailed route)

## Final measured numbers (11.5 ns clock, real extracted SPEF via standalone OpenSTA)

| Metric | Flow v0 | Flow v1 (frozen) |
|---|---|---|
| WNS (max) | -24.18 ns | **-1.13 ns** |
| TNS (max) | -1885.86 ns | **-33.69 ns** |
| WHS (min) | +0.32 ns | +0.32 ns (unchanged) |
| Design area | 55192 um² / 43% util | 55503 um² / 44% util |
| Post-route cell instances | (not counted) | 18547 |
| Regression (`make test-unit`) | 11/11 | 11/11 |
| DRC (detailed route) | 0 violations | 0 violations |

**Does not close at 11.5 ns.** Flow v1 is a flow-only fix (no RTL changes)
that eliminated a severe, unintended config-fanout violation (an unbuffered
minimum-drive gate fanning out to ~50 pins) and exposed the real,
architecturally-expected bottleneck: an 18-cell `maj3_1` ripple-carry chain
in `fp_add_sub`'s stage-0 adder plus the 2.0 ns input-delay budget. This
remaining -1.13 ns is now a small, single-cause gap, not a systemic one.

## Known-stale artifact this baseline corrects

Every previously-recorded post-route number (the SDC's own comment, commit
`dfa2b01`, and the -3.16ns/-84.84ns figure supplied for this task)
predates RTL merges at HEAD (`37d7249` skid FIFO, `05e9725` per-transaction
config/overflow tagging, `3bd6fe6`/`348d22d` MIN_NEG fixes, `46af47a`
cordic_lut guard). See `DECISIONS.md` for the full trace. Treat this
document, not any of those, as authoritative going forward.

## Open items not yet resolved

- 11.5 ns does not close under Flow v1 (-1.13 ns WNS). A clock sweep and,
  if needed, an RTL-level fix targeting `fp_add_sub`'s ripple-carry chain
  are the next steps (tracked in RESULTS.md / DECISIONS.md as they run).
- DRC/LVS against current RTL: DRC re-verified clean under Flow v1 (this
  document); LVS not re-run in this pass (`docs/PLACE_ROUTE_DRC.md` should
  be treated as stale until it is).
- Formal properties: unresolved/documented-FAIL items noted separately in
  the formal test tree; not re-touched in this timing pass per the task's
  Rule 6.
