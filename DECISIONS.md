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

---

## Experiment 2, Step A: is the ripple-carry chain RTL structure or synthesis mapping?

**Answer: synthesis mapping, not RTL structure.** Two independent, verified facts:

1. **`rtl/fp_add_sub.sv` has no adder architecture at all.** Its module doc
   comment claims "carry-select optimization" and it declares a
   `USE_CARRY_SELECT` parameter (default `1'b1`), but `USE_CARRY_SELECT` is
   never referenced anywhere in the module body (confirmed by grepping the
   whole `rtl/` tree — the only two hits are the declaration and the doc
   comment). The actual datapath is plain `a_ext - b_ext` / `a_ext + b_ext`
   on `logic signed` operands (lines 51–55) — i.e. whatever Yosys's generic
   `+`/`-` lowering produces, with zero RTL-level structural choice.

2. **`scripts/synth.tcl` lowers `$add`/`$sub` with plain `techmap` (line
   32) before `abc` ever runs** (line 38: `abc -liberty ...`, no `-D`, no
   `-constr`). Yosys's default `techmap.v` rule for `$add` builds a
   textbook ripple-carry structure (cascaded full-adders); there is no
   arithmetic-aware pass (`alumacc`, or a custom lookahead/carry-select
   techmap map file) anywhere in the script. ABC then only re-maps that
   already-ripple-structured gate network to Sky130 cells — maj3 is
   exactly a full adder's carry-generate function, which is why the
   critical path is a chain of `sky130_fd_sc_hd__maj3_1` cells.

**Corroborating evidence that ABC is not timing-driven at all:** per
`yosys -p "help abc"`, the default ABC script only runs `buffer; upsize
{D}; dnsize {D}` (the cell-sizing passes) when **both** `-D <ps>` and
`-constr <file>` are given; `scripts/synth.tcl` passes neither. Checked
`output/synth_area.rpt`: **every** carry-chain cell in the entire
5367-cell design (`maj3_1`, `xor3_1`, `xnor2_1`, `xnor3_1`, `xor2_1`) is
the weakest (`_1`) drive-strength variant, even though the Sky130 HD
library stocks `_2` and `_4` variants of every one of them. Zero upsized
cells anywhere in the design is exactly what "ABC never runs sizing"
predicts, independently confirming the mechanism.

**Two independent levers follow directly:**
- (i) synthesis-only, RTL unchanged: give `abc` a `-D` delay target and a
  `-constr` file so it actually sizes/buffers along the existing ripple
  chain.
- (ii) RTL-level: replace the plain `+`/`-` with an explicit
  carry-select/prefix structure in `fp_add_sub.sv`, independent of (i).

**Update after Experiment 2/2b (measured fact vs. hypothesis, stated
separately per explicit request):** both levers above were tried, plus an
ABC `-D` sensitivity sweep and a forced-hierarchy variant of (ii) — see
RESULTS.md Experiment 2 / 2b for full numbers. All four measured worse
than the ripple baseline at 11.5ns. **Measured fact:** the synthesized
netlist is byte-identical across `-D` = 800/3000/11500ps, so ABC's mapping
here is provably insensitive to delay target. **Hypothesis, not
established:** that this generalizes to "no adder topology can fix this
under this flow" — only carry-select (plain and forced-structure) was
tried; Brent-Kung/Kogge-Stone remain untested, and the `-D`-insensitivity
result is equally consistent with an intrinsic-logic-depth explanation as
a wire-RC one (ABC's model has zero internal-net wire capacitance either
way, so its indifference to `-D` doesn't distinguish the two). Do not cite
the wire-RC/fanout explanation as a settled fact without re-reading
RESULTS.md's Experiment 2b writeup for the caveat.
