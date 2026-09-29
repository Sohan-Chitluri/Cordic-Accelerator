# Timing Baseline — Decision Log

## Why the -3.16 ns / -84.84 ns TNS baseline doesn't reproduce

**Bounded investigation (git history only, ~15 min):** found, not unexplained.

The only post-route re-derivation ever committed is `dfa2b01` ("timing:
re-derive real post-route timing vs stale pre-repair numbers (Agent D)"),
which measured **WNS -2.07 ns, WHS +0.32 ns, TNS -46.77 ns** at 11.5 ns,
against a netlist of **3980 cells / 454 FFs**.

Critically, `dfa2b01`'s only git parent is `e107100` ("Close timing: relax
clock to measured achievable Fmax") — it does **not** have the Agent
A/B/C RTL merges as ancestors, despite its own commit message claiming to
test "the merged RTL (skid FIFO + credit counter, per-transaction
config/overflow shift registers)". That claim does not match the git
graph: `05e9725` (per-transaction config/overflow tagging, Agent B),
`3bd6fe6`/`348d22d` (MIN_NEG fixes, Agent C), and `46af47a` (cordic_lut
FRACT_W guard) all merged into mainline *after* `dfa2b01`, via
`7948d24`/`8d18ca8`/`7c3066a`, and were never re-measured post-route
afterward. (Likely explanation, unverified: Agent D ran in a worktree
that had those files present locally without them being git ancestors of
its commit — consistent with the parallel-agent worktree setup visible
under `.claude/worktrees/`.)

So every post-route number on record — including the "-3.16 ns / -84.84
ns" figure supplied for this task, which is closer to but still doesn't
exactly match either committed data point — predates the RTL that is
actually at HEAD today.

**What changed in RTL between `dfa2b01`'s measurement and HEAD:**
- `37d7249` — output FIFO for lossless backpressure (skid FIFO/credit counter)
- `05e9725` — per-transaction config/overflow tagging in `cordic_pipeline`
- `3bd6fe6`, `348d22d` — MIN_NEG negation-overflow fixes (`fp_add_sub`, `cordic_stage`)
- `46af47a` — `cordic_lut` FRACT_W domain guard + golden model fix

Freshly measured at HEAD (`6539d08`), same 11.5 ns clock, same `pr.tcl`
(byte-identical to the version `dfa2b01` used):
- Synthesized cell count: **5367** (vs. 3980 at `dfa2b01` — +35%)
- Post-route (real SPEF, standalone OpenSTA): **WNS -24.18 ns, WHS +0.32 ns,
  TNS -1885.86 ns**
- Dominant path: NOT the `fp_add_sub` carry chain `dfa2b01` blamed. All 20
  worst-slack endpoints share one startpoint and route through a single
  minimum-drive `nor4b_1` gate contributing 18.1 ns alone, fed by four
  select/config nets each fanning out to 91–100 gate pins unbuffered. This
  lines up with `05e9725`'s per-transaction config/overflow tagging being
  the newest large structural addition since the last timing measurement.

**Decision:** treat the fresh measurements above as the authoritative
baseline going forward ("Flow v0"). The 11.5 ns clock value in
`constraints/cordic.sdc` and its justifying comment are now known-stale
and will be revisited once Flow v1 is frozen and the clock sweep (Step 2)
is re-run.
