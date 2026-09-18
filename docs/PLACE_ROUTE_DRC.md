# Place & Route and DRC Flow

## Current Status

✅ **Synthesis Complete**: `output/cordic_top_synth.v`, mapped to Sky130 HD standard cells
   (`sky130_fd_sc_hd__*`), 3979 cells (454 `dfxtp_1` flip-flops)
✅ **Formal Verification**: All assertions pass
✅ **RTL Simulation**: 9/9 tests pass
✅ **Static Timing Analysis**: Runs clean via standalone OpenSTA against the Sky130 HD
   `tt_025C_1v80` corner. Clock target 11.5 ns (~87 MHz, the measured achievable Fmax — see
   `CORDIC_IMPLEMENTATION_TRACKER.md` Gate 4). Pre-layout slack +0.26 ns, TNS 0.00 — **timing
   closed**. `output/sta_checks.rpt`.
✅ **Place & Route**: OpenROAD, full flow (floorplan → tap/tracks → IO/global/detailed placement →
   PDN → CTS → filler cells → global/detailed route). `make pr`. Post-route: slack +0.92 ns, TNS
   0.00 — **timing closed**; 34,405 µm² at 43% utilization. `output/cordic_top_routed.def`,
   `output/cordic_top_routed.v`.
✅ **DRC**: Magic, Sky130 HD rule deck. `make drc`. **0 violations.** GDSII exported to
   `output/cordic_top.gds`.
✅ **LVS**: Magic extraction (LEF-only cells, so std cells stay as opaque devices matching the
   Verilog side) + Netgen, against OpenROAD's **post-route** netlist (not pre-P&R — CTS inserts
   buffers). `make lvs`. **Netlists match uniquely** (4107 devices / 4134 nets, exact on both
   sides). The one reported "error" (`valid_out`/`irq` shorted) is an intentional RTL choice, not
   a bug — see `CORDIC_IMPLEMENTATION_TRACKER.md` Gate 4. `output/lvs_report.txt`.

**Bottom line:** the full RTL→GDSII physical flow runs clean end-to-end, timing is closed, and
DRC/LVS pass. The one open item before tape-out is toggle coverage (46% vs. 85% target) — a
verification completeness gap, not a toolchain or design-correctness issue.

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
| RTL Simulation | Verilator | ✅ PASS | 9/9 tests |
| Synthesis | Yosys | ✅ PASS | Gate-level netlist, Sky130 HD mapped |
| Formal Verification | SymbiYosys | ✅ PASS | All assertions verified |
| Timing Analysis (pre-layout) | OpenSTA | ✅ **Closed** | +0.26 ns slack @ 11.5 ns (~87 MHz) |
| P&R | OpenROAD | ✅ **Closed** | `make pr`; +0.92 ns slack post-route |
| DRC | Magic | ✅ **0 violations** | `make drc`; GDSII exported |
| LVS | Netgen (`netgen-vlsi`) | ✅ **Match** | `make lvs`; 4107 devices / 4134 nets, exact |
| GDSII | Magic | ✅ DONE | `output/cordic_top.gds` |

**Overall**: The physical flow (synthesis → STA → P&R → DRC → LVS → GDSII) is complete, clean,
and timing-closed at 11.5 ns (~87 MHz — see `CORDIC_IMPLEMENTATION_TRACKER.md` Gate 4 for why
this isn't 100 MHz). Toggle coverage (46% vs. 85%) is the one remaining open item before
tape-out.
