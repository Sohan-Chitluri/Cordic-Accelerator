# Place & Route and DRC Flow

## Current Status (re-verified by Agent D against the post-repair RTL — see below)

The numbers below were reproduced from a clean `make clean && make synth && make sta && make pr`
run against the RTL as of this branch (after the arithmetic/MIN_NEG fixes, the rewritten
skid-FIFO/credit-based pipeline output stage, and the per-transaction config/overflow shift
registers were merged). **They supersede every number previously in this file**, which was
measured against an earlier, smaller netlist (417 cells / 48 FFs) — the current synthesized
netlist is 3980 cells / 454 `dfxtp_1` flip-flops, so none of the old timing numbers are valid for
this RTL.

✅ **Synthesis**: `output/cordic_top_synth.v`, mapped to Sky130 HD standard cells, 3980 cells
   (454 `dfxtp_1` flip-flops).
✅ **RTL Simulation / Formal**: unaffected by this pass (not re-run here; see other agents' work).
⚠️ **Static Timing Analysis (pre-layout, ideal/zero-wireload)**: standalone OpenSTA,
   `tt_025C_1v80` corner, 11.5 ns clock (see `constraints/cordic.sdc`). No `set_wire_load_mode`
   is set, and Sky130 HD's Liberty ships no default wire-load table, so this is a genuinely
   ideal/zero-parasitic run, not a statistical-wireload one.
   **WNS (setup) = +0.4173 ns, WHS (hold) = +0.2649 ns, TNS = 0.00 — closes.**
   Critical path: `x_in[1]` (input port) → stage-0 `y`-path flops, through the `fp_add_sub`
   carry-chain (`maj3_1`/`xnor3_1` cells — a ripple-style full-adder chain, i.e. the carry-select
   opportunity flagged in the `e107100` commit message is not actually exploited in the mapped
   netlist). `output/sta_checks.rpt`.
❌ **Static Timing Analysis (post-route, REAL extracted parasitics)**: standalone OpenSTA, same
   corner/SDC, reading a SPEF genuinely extracted by OpenROAD's OpenRCX
   (`extract_parasitics -ext_model_file pdk/sky130_fd_sc_hd_rcx_rules.nom.magic`, the volare-
   fetched Sky130A "nom" OpenRCX rules deck) from the actual detailed-routed DEF, via the new
   `scripts/sta_postroute.tcl` — not OpenROAD's own inline post-route timer, which is a separate
   number (see "Two post-route numbers" below).
   **WNS (setup) = -2.07 ns, WHS (hold) = +0.32 ns, TNS = -46.77 ns — does NOT close at 11.5 ns.**
   Critical path: same startpoint/topology as pre-layout (`x_in[1]` → stage-0 `y` flops through
   `fp_add_sub`'s carry chain) — extracted routing RC roughly *quintuples* the setup violation
   budget needed (from 0 to ~2.07 ns), it does not move the critical path elsewhere.
   Implied real Fmax ≈ 1000/(11.5+2.07) ≈ **73.7 MHz**, not the ~87 MHz implied by the pre-layout
   number alone. `output/sta_postroute_checks.rpt`, `output/sta_postroute_wns.rpt`,
   `output/sta_postroute_tns.rpt`.
✅ **Place & Route**: OpenROAD, full flow (floorplan → tap/tracks → IO/global/detailed placement →
   PDN → CTS → filler cells → global/detailed route → OpenRCX parasitic extraction). `make pr`.
   Routing itself completes with 0 DRT violations. `output/cordic_top_routed.def`,
   `output/cordic_top_routed.v`, `output/cordic_top_routed.spef`.
⚠️ **DRC / LVS**: **not re-verified against the current RTL in this pass** (time-boxed out of this
   session before `make drc`/`make lvs` could be re-run against the freshly re-routed design).
   The previous ✅ 0-violations / clean-match numbers in this file were measured against the old,
   smaller netlist and must be treated as stale until re-run against the current
   `output/cordic_top_routed.def`. Do not cite them as current.

### Two post-route numbers — resolving the zero-wireload vs. extracted-RC gap

An earlier (now-stale, pre-repair-RTL) third-party audit at commit `e107100` reported that the
project's *published* post-route WNS (-0.583711 ns at a 10 ns clock) was measured with
effectively ideal/zero-wireload parasitics, and that loading real extracted SPEF gave a much
worse number (-2.461153 ns / -89.56 ns TNS). That audit's own numbers are from a different clock
period (10 ns) and a different (older) netlist, so they are cited here only as methodology
precedent, not as current results.

Independently reproducing this on the *current* RTL, at the current 11.5 ns clock, confirms the
same *shape* of gap:
- OpenROAD's own inline post-route report (`report_worst_slack` called immediately after
  `extract_parasitics`/`write_spef`, still inside the same OpenROAD session) reported
  worst slack max/min = **+0.42 ns / +0.26 ns** — i.e. essentially identical to the pre-layout,
  zero-parasitic number, even though real parasitics had just been extracted in that same session.
  This is exactly the trap the audit warned about: OpenROAD's resident timer does not necessarily
  re-run a full timing update against newly-loaded/extracted parasitics on request, and a
  post-route-labeled number from it can silently still reflect ideal wires.
- A fresh, standalone OpenSTA process — the same tool used for pre-layout STA — that reads the
  routed netlist cold and explicitly `read_spef`s the OpenRCX-extracted parasitics from disk
  reports **WNS = -2.07 ns, TNS = -46.77 ns**, as detailed above.

`scripts/pr.tcl` now performs the OpenRCX extraction and writes `output/cordic_top_routed.spef`;
`scripts/sta_postroute.tcl` (new) is the standalone-OpenSTA + real-SPEF run. **Only the
standalone-OpenSTA-with-real-SPEF number should be trusted as "post-route timing"** — an inline
OpenROAD report taken right after extraction is not sufficient evidence of that on its own.

### Does 11.5 ns (ADR-0001 / `e107100`'s "measured achievable Fmax") still hold?

No, not for this RTL. `e107100`'s post-route "+0.92 ns, TNS 0.00, timing closed" claim does not
reproduce here — see numbers above. Two things changed since `e107100`: the RTL itself grew
substantially (skid-FIFO + credit counter, per-stage config/overflow shift registers — 3980 cells
vs. 417 previously), and, more importantly, `e107100`'s own post-route number looks to have
suffered from the same zero-wireload-masquerading-as-post-route gap described above, independent
of the RTL growth — the critical path is the *same* `fp_add_sub` carry chain in both the pre-layout
and post-route-with-real-RC runs, just with the added routing parasitics pushing it from met to a
sizeable violation.

**This is not "pick an easier clock and move on" territory per ADR-0001** — the critical path is
a specific, previously-flagged, structurally-fixable issue: `rtl/fp_add_sub.sv`'s carry chain
maps to a `maj3_1`/`xnor3_1` ripple structure in the synthesized netlist rather than the
carry-select structure the `e107100` commit message says was intended but left unexploited. That
is squarely an RTL/arithmetic fix (out of this agent's file ownership — flagged for the
arithmetic agent/lead, not implemented here), not a "this is just the measured ceiling, document
it" situation. Padding the SDC clock out to ~13.6 ns to force a clean TNS=0 post-route report
would satisfy the letter of ADR-0001 ("measure, don't target 100 MHz") while obscuring a genuine,
fixable structural bottleneck — which the repair brief explicitly says not to do. Accordingly,
`constraints/cordic.sdc` is left at 11.5 ns in this pass, honestly documented here as *not
closing post-route*, pending either the carry-chain fix or an explicit, deliberate decision by
the lead to relax the constraint with the real number in hand.

**Bottom line:** pre-layout (ideal-wire) STA is clean at 11.5 ns; **post-route STA with real
extracted parasitics is not** (WNS -2.07 ns / TNS -46.77 ns / real Fmax ≈73.7 MHz). DRC/LVS were
not re-verified against the current RTL in this session and should not be cited as passing until
re-run. Toggle coverage (46% vs. 85% target, from prior passes) remains a separate open item.

---

## Toolchain Setup (this environment)

`flake.nix` provides `verilator`, `yosys`, `openroad`, `magic-vlsi`, `netgen-vlsi`, and the build
dependencies for standalone OpenSTA (`cmake`, `tcl`, `cudd`, `eigen`, `swig`, `flex`, `bison`,
`gtest`). Enter the shell with `nix develop`.

**Netgen name collision:** nixpkgs' plain `netgen` package is the unrelated NGSolve/Netgen finite
element mesh generator (a GUI tool by TU Wien) — running `netgen -batch lvs ...` against it just
opens its GUI and does nothing useful. The VLSI LVS tool from opencircuitdesign is packaged as
**`netgen-vlsi`** (confirm with `netgen -batch quit` printing `Netgen 1.x.xxx` from
opencircuitdesign, not `NETGEN-x.x.xxxx` from TU Wien/RWTH/JKU).

**OpenSTA** is not in `nixpkgs` as a standalone package. `nixpkgs`'s `openroad` package (which
normally bundles it) previously failed to build: one of its dependencies, `or-tools`, pulled in
`pybind11`, whose bundled test suite failed under Python 3.14. That was an upstream nixpkgs
packaging issue (pybind11 2.13.6 was pinned by `or-tools`, and only pybind11 ≥3.0.0 supports
Python 3.14), and it has since been fixed and merged upstream — nixpkgs PR
[#551898](https://github.com/NixOS/nixpkgs/pull/551898), merged 2026-09-07. This flake's
`flake.lock` has been bumped past that fix, and `nix build nixpkgs#openroad` now succeeds
(verified 2026-09-17). We still build OpenSTA standalone below rather than switching to
`nixpkgs#openroad` for timing analysis, since OpenSTA alone is a much smaller build and this
project's STA flow already depends on it directly:

```bash
nix develop
./tools/build_opensta.sh      # builds tools/OpenSTA/build/sta
```

**Sky130 PDK** (Liberty timing libraries) is fetched via `volare` (not in `nixpkgs`, installed
into a local venv):

```bash
nix develop
python3 -m venv .venv && source .venv/bin/activate
pip install volare
volare fetch --pdk sky130 <version>   # see `volare ls-remote --pdk sky130`
ln -sfn ~/.volare/volare/sky130/versions/<version>/sky130A/libs.ref/sky130_fd_sc_hd/lib \
  pdk/sky130_fd_sc_hd_lib
```

Also symlink the LEF, tech-LEF, and GDS directories `pdk/` expects (see `scripts/pr.tcl` and
`scripts/drc.tcl` for exact paths):

```bash
ln -sfn <version-dir>/sky130A/libs.ref/sky130_fd_sc_hd/lef      pdk/sky130_fd_sc_hd_lef
ln -sfn <version-dir>/sky130A/libs.ref/sky130_fd_sc_hd/techlef  pdk/sky130_fd_sc_hd_techlef
ln -sfn <version-dir>/sky130A/libs.ref/sky130_fd_sc_hd/gds      pdk/sky130_fd_sc_hd_gds
```

Both `tools/OpenSTA/` and `pdk/` are gitignored — local, machine-specific build/fetch outputs,
not part of the repo.

**OpenROAD (P&R)** is buildable via `nixpkgs#openroad` (confirmed 2026-09-17, see above) and is
wired into `make pr` (`scripts/pr.tcl`). Standalone OpenSTA remains the STA tool in use
(`make sta`), separate from OpenROAD's own bundled copy.

---

## Flow Options

### Option 1: Open-Source Tools (Recommended for Academia)

**Tools Required:**
- **OpenROAD** (https://github.com/The-OpenROAD-Project/OpenROAD)
  - Automated placement, clock tree synthesis, routing
  - Integrated timing analysis
  - Open-source, actively maintained
  
- **Magic** (http://opencircuitdesign.com/magic/)
  - Interactive layout editor
  - DRC (Design Rule Check)
  - LVS helpers (with Netgen)
  
- **Netgen** (http://opencircuitdesign.com/netgen/)
  - LVS (Layout vs Schematic)
  - Cross-layer verification
  
- **PDK (Process Design Kit)**
  - Technology files (e.g., SKY130)
  - DRC rules
  - Timing libraries

**Setup:**
```bash
# Install OpenROAD and dependencies
nix flake update
nix develop

# OR install from source:
# OpenROAD: git clone https://github.com/The-OpenROAD-Project/OpenROAD.git
# Magic: git clone git://opencircuitdesign.com/magic
# Netgen: git clone git://opencircuitdesign.com/netgen
```

**Run P&R:**
```bash
# With OpenROAD and SKY130 PDK installed
openroad -s scripts/pr.tcl
```

**Typical Flow:**
```
Synthesized Netlist (cordic_top_synth.v)
    ↓
Floorplanning (manual or OpenROAD)
    ↓
Global Placement (OpenROAD)
    ↓
Clock Tree Synthesis (OpenROAD)
    ↓
Detailed Placement (OpenROAD)
    ↓
Routing (OpenROAD)
    ↓
Layout (DEF format)
    ↓
DRC Check (Magic)
    ↓
LVS Verification (Magic + Netgen)
    ↓
GDSII Generation
```

---

### Option 2: Commercial Tools (Industry Standard)

**Tools Required:**
- **Cadence Innovus** OR **Synopsys ICC2**
  - Industry-standard P&R
  - Advanced optimization
  - Timing/power closure
  
- **Calibre** OR **Cadence Assura**
  - DRC/LVS/PEX
  - Comprehensive verification
  
- **PDK from Foundry**
  - Technology rules
  - Design libraries
  - Timing models

**Typical Flow:**
```
Synthesized Netlist (cordic_top_synth.v)
    ↓
Floorplan Setup (Innovus)
    ↓
Placement (Innovus)
    ↓
Clock Tree Synthesis (Innovus)
    ↓
Routing (Innovus)
    ↓
Power/Ground Routing (Innovus)
    ↓
Layout GDS
    ↓
Calibre DRC Check
    ↓
Calibre LVS Check
    ↓
Calibre PEX (parasitics)
    ↓
Post-layout STA (OpenSTA with extracted parasitics)
    ↓
Final GDSII
```

---

## Input Artifacts

**Synthesized Netlist:**
- Path: `output/cordic_top_synth.v`
- Type: Verilog gate-level netlist
- Cells: 417 gates (adders, muxes, DFFs, etc.)
- Size: 38 KB

**Design Specification:**
- WIDTH: 16 bits
- FRACT_W: 12 bits
- ITERATIONS: 8 CORDIC iterations
- Max frequency: 200 MHz (5ns clock period target)

**Design Metrics (from synthesis):**
- Total wires: 741
- Total wire bits: 7207
- Total cells: 417
- Adders: 42
- Comparators: 24
- Muxes: 192
- Flip-flops: 48 (+ 1 SDFFE)

---

## Constraint Files Needed

### Timing Constraints (SDC format)
```tcl
# constraints/cordic_timing.sdc
create_clock -name clk -period 5.0 [get_ports clk]
set_clock_uncertainty 0.5 [get_clocks clk]
set_clock_transition 0.2 [get_clocks clk]
```

### Placement Constraints (if needed)
```tcl
# constraints/cordic_placement.sdc
# Define don't-touch regions, keepout zones, etc.
```

---

## Expected Results

### Area Estimate (using SKY130 ~0.13µm equivalent)
- **Core Area**: ~200-300 µm² (rough estimate)
  - 417 gates × ~0.3-0.5 µm²/gate ≈ 125-210 µm²
  - Plus routing overhead (50-100%)
  
- **Total with I/O pads**: ~500-1000 µm²

### Power Estimate
- **Dynamic**: ~1-5 mW @ 200 MHz, 1.2V
- **Leakage**: ~0.1-1 µW (varies by process)

### Timing
- **Path delay**: Should be <5ns with typical synthesis
- **Slack**: Margin for routing overhead
- **CTS depth**: ~2-3 levels of buffering

---

## Verification Steps

### DRC (Design Rule Check)
```bash
# Using Magic
drc check
drc catchup
drc report
```

### LVS (Layout vs Schematic)
```bash
# Using Netgen
lvs output/cordic_top_routed.def output/cordic_top_synth.v sky130_tech_rules
```

### PEX (Parasitic Extraction)
```bash
# Extract parasitics from layout
ext2spice
# Or using commercial tool like Quantus
```

### Post-Layout STA
```bash
# Use OpenSTA with extracted parasitics
read_spef output/cordic_top_routed.spef
report_checks -path_delay max
```

---

## Next Steps

1. **Acquire PDK** (if using open-source flow)
   - SKY130: https://github.com/google/skywater-pdk
   - IHP: https://github.com/IHP-GmbH/IHP-Open-PDK
   
2. **Install Tools**
   ```bash
   # For open-source flow
   git clone https://github.com/The-OpenROAD-Project/OpenROAD.git
   cd OpenROAD && make
   ```

3. **Prepare Constraints**
   - Create timing constraints (SDC)
   - Define placement regions
   
4. **Run P&R**
   ```bash
   openroad -s scripts/pr.tcl
   ```

5. **Verify**
   - DRC check with Magic
   - LVS with Netgen
   - Post-layout timing
   
6. **Generate GDSII**
   - For fabrication or layout simulation
   - Requires GDS writer support in tool

---

## References

- **OpenROAD**: https://openroad.readthedocs.io/
- **SKY130 PDK**: https://skywater-pdk.readthedocs.io/
- **Magic VLSI**: http://opencircuitdesign.com/magic/
- **Netgen**: http://opencircuitdesign.com/netgen/
- **OpenSTAFlow**: https://github.com/The-OpenROAD-Project/OpenSTA

---

## Status Summary

| Step | Tool | Status | Notes |
|------|------|--------|-------|
| Synthesis | Yosys | ✅ PASS | 3980 cells / 454 FFs, Sky130 HD mapped |
| Timing Analysis (pre-layout, ideal wires) | OpenSTA | ✅ **Closed** | WNS +0.42 ns, WHS +0.26 ns, TNS 0.00 @ 11.5 ns |
| Timing Analysis (post-route, real extracted RC) | OpenSTA + OpenRCX SPEF | ❌ **NOT closed** | WNS -2.07 ns, WHS +0.32 ns, TNS -46.77 ns @ 11.5 ns — real Fmax ≈73.7 MHz |
| P&R (routing itself) | OpenROAD | ✅ Routes clean | `make pr`; 0 DRT violations |
| DRC | Magic | ⚠️ **Not re-verified** | stale (old netlist); re-run needed |
| LVS | Netgen (`netgen-vlsi`) | ⚠️ **Not re-verified** | stale (old netlist); re-run needed |
| GDSII | Magic | ⚠️ **Not re-verified** | depends on DRC re-run |

**Overall**: pre-layout STA closes at 11.5 ns on ideal wires; loading OpenROAD's own OpenRCX-
extracted parasitics from the actual routed layout into a standalone OpenSTA run shows it does
**not** close post-route — WNS -2.07 ns / TNS -46.77 ns, implied real Fmax ≈73.7 MHz, not the
~87 MHz the pre-layout-only number would suggest. The critical path in both cases is the same
`fp_add_sub` carry chain (`rtl/fp_add_sub.sv`), synthesized as a ripple-style `maj3_1`/`xnor3_1`
chain rather than a carry-select structure — see "Does 11.5 ns still hold?" above for why this is
flagged as an RTL fix candidate rather than grounds for further relaxing the clock. DRC/LVS/GDSII
were not re-verified against the current (post-repair) RTL in this pass and must not be read as
current. Toggle coverage (46% vs. 85%, from prior passes) remains a separate open item.
