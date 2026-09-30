# Formal Property Triage

Freshly re-run for this pass: `make formal` (`sby -f tb/formal/cordic_formal.sby`,
all 5 tasks), against the RTL at its Flow v1 baseline (no RTL changes made
in this triage, per instruction). Full log: this session's `/tmp/formal_run.log`
(not committed; re-run `make formal` to reproduce).

**Important caveat that applies to every "PASS" below:** every task in
`tb/formal/cordic_formal.sby` uses `mode bmc` (bounded model checking), not
`mode prove` with k-induction. A BMC "pass" means *no counterexample was
found within the task's fixed depth* — it is a bounded check, not an
unbounded inductive proof. None of the properties below are "proven" in
the strict formal sense; they are correctly labeled "bounded" throughout
this document.

## Summary table

| Task | Depth | Verdict | Classification | Genuine finding? |
|---|---|---|---|---|
| `stage` | 20 | pass | **Bounded** | — |
| `reset` | 18 | pass | **Bounded** | — |
| `conservation` | 18 | pass | **Bounded** | — |
| `satclamp` | 24 | FAIL (step 11) | **Failing** | Yes — real architectural gap |
| `cfg_align` | 18 | pass | **Not checked** (see below — the pass is not evidence the property holds) | Unresolved — needs a decision |

## `stage` — Bounded (depth 20)

Stage-local BMC on `cordic_stage` (via `cordic_formal_tb`). Checks, all as
procedural `$past`-based assert/cover (Yosys `-formal` here does not
reliably support concurrent SVA `property...endproperty`, so these are
re-expressed procedurally rather than reusing the SVA in
`rtl/common/cordic_assertions.sv`):

- P1: reset clears `valid_out` within 1 cycle
- P2: reset clears `overflow` within 1 cycle
- P3: `valid_in` propagates to `valid_out` 1 cycle later
- P4: `sat && overflow => (x_out clamped) OR (y_out clamped)`
- P6/P7: `x_out`/`y_out` always in signed representable range when valid

No counterexample within 20 steps. Also includes reachability `cover`s
proving P4's antecedent (`sat && overflow`) is not vacuous, and that the
x-only/y-only/both overflow sub-cases are each independently reachable —
important because a property that can never fire proves nothing.

## `reset` — Bounded (depth 18)

Pipeline-level reset correctness (`cordic_pipeline_reset_tb`, PP1: reset
clears `valid_out`/`overflow` and holds them cleared until the first valid
admission after release). No counterexample within 18 steps. Per the
`.sby` file's own note, depth is capped at 18 (not higher, e.g. 24) because
z3's per-step solve time grows sharply past step ~15 for this task's
state; 18 was chosen to get a complete, bounded result in available time
rather than an indefinitely-running one.

## `conservation` — Bounded (depth 18)

Fixed-latency, no-loss-no-duplication property
(`cordic_pipeline_conservation_tb`), using a testbench-local shadow
FIFO-occupancy model built entirely from external ports. Per the `.sby`
file's history note: two earlier "FAIL" verdicts under this task name were
both **harness bugs, not RTL findings** — round 1 referenced RTL that no
longer existed post-merge; round 2 used a hierarchical `dut.*` reference
that Yosys silently turned into a free/unconstrained signal instead of a
hard error (the same class of tool limitation flagged again below for
`cfg_align`). The current version avoids `dut.*` entirely. No
counterexample within 18 steps in this fresh run.

## `satclamp` — FAILING (depth 24, counterexample at step 11)

**This is a real, re-confirmed architectural finding, not a harness bug.**
Fresh run this pass: `engine_0 (smtbmc z3) returned FAIL`, failed assertion
`cordic_pipeline_satclamp_tb._witness_.check_assert_cordic_formal_tb_sv_740_35`
at `cordic_formal_tb.sv:740`, step 11 — well within the 24-step bound, so
this is a genuine counterexample, not a depth-limitation artifact.

The failing assertion (source, `cordic_formal_tb.sv:739-742`):
```systemverilog
if (rst_n && $past(!valid_out) && valid_out && overflow && cfg_saturate) begin
  assert (x_out == MAX_POS_F || x_out == MIN_NEG_F);
  assert (y_out == MAX_POS_F || y_out == MIN_NEG_F);
end
```

**Why it fails:** the pipeline's `overflow` output is a *sticky* "saturated
somewhere across the 8 stages" bit, not a "the final output is currently
at the saturation boundary" bit. A stage partway through the pipeline can
clamp `x`/`y` to the boundary and set `overflow`, but a *later* stage's
own arithmetic (further rotation) can move the value off the boundary
again while `overflow` stays set (it only ever accumulates, never
clears mid-transaction). So `overflow && cfg_saturate` at the output does
not imply the output value itself is at the boundary. This is a real
semantic gap between what `overflow` documents/implies and what it
actually guarantees at the pipeline's output port — worth fixing or
re-documenting, but **not to be fixed in this pass** per instruction (no
RTL changes without asking first).

## `cfg_align` — NOT CHECKED (the "pass" is not evidence the property holds)

**Flagging a real discrepancy, not silently accepting it.** The task
`.sby` header and this testbench file's own module-list comment both say
"EXPECT FAIL when `config_valid` is left free" for this task — describing
an intended check of whether `cfg_saturate_r`'s value stays constant
across a transaction's full 8-stage traversal (the "does overflow status
correspond to the same transaction as the data it accompanies" question
from the original task brief). The fresh run this pass returned **PASS**,
which at first reads as "the metadata-alignment bug is fixed." It is not
evidence of that, for a specific, source-documented reason:

Reading `cordic_pipeline_cfg_align_tb`'s body
(`tb/formal/cordic_formal_cfg_align/src/cordic_formal_tb.sv`, lines
~920-949): **this module contains no `assert` of the alignment property at
all.** Its own inline comment says why: "Yosys `-formal` does not reliably
resolve `dut.*` hierarchical dot-references AT ALL from outside the
instance ... There is no `dut.*` workaround," and concludes "since
`config_valid`/`config_ready` are left free ... a plain edge-detect on the
external port is an honest, real-port-only proxy ... **sufficient for a
reachability `cover`, this module makes no assert**." The module has three
`cover()` statements and zero `assert()` statements checking alignment.

**Consequence:** an sby BMC task with no assert can only report "pass" —
there is nothing for a counterexample to violate. The PASS verdict here
means "the cover goals were reachable and nothing else in the design
raised an assertion," not "the config/overflow metadata-alignment property
holds." The "EXPECT FAIL" comments in both the `.sby` file and this
testbench's header are **stale/aspirational** — they describe a check that
this testbench, by its own documentation, was never able to actually
implement due to the `dut.*` tool limitation, not a real measured result
that later became a real measured pass.

**This needs a decision, not a silent fix:** the actual RTL-level question
("can `cfg_saturate_r` change value while a transaction is mid-flight, and
if so does the output's `overflow` flag correspond to the wrong
transaction's config") remains formally open. Options (not undertaken
here, per instruction to ask before touching RTL or, by extension,
formal harnesses that gate RTL conclusions):
1. Find a Yosys-formal-compatible way to observe the alignment (e.g.
   route the config-shift-register value out through a debug port instead
   of a `dut.*` reference) and write a real assert.
2. Accept that this property is out of reach for this toolchain and
   downgrade the task's own documentation (both the `.sby` header and the
   testbench header) from "EXPECT FAIL" to "NOT CHECKED (tool
   limitation)," so a future reader doesn't repeat this session's
   momentary misreading of a trivial PASS as a real proof.
3. Investigate via simulation instead (Verilator can observe hierarchical
   signals that Yosys-formal cannot) to at least get empirical, if not
   formal, evidence either way.

No RTL or testbench changes have been made for this item — flagging it
here for a decision before any of the above is attempted.
