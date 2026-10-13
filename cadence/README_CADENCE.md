# Cadence Genus & Innovus Execution Guide

## Adaptive-11 CORDIC Accelerator (Architecture B1)

### 1. Handoff Overview
- **Architecture:** Adaptive-11 CORDIC (`ARCH_SPEC.md` Architecture B1)
- **Top Module:** `cordic_top`
- **Clock Target:** 15.0 ns period (~66.7 MHz), 1.8V Sky130 HD (or target foundry PDK)
- **Latency Contract:** Exactly **12 clock cycles** (`ITERATIONS + 1` where `ITERATIONS = 11`)
- **Physical Stages:** 11 registered rotation stages with input operand isolation
- **Runtime Modes:** Modes 1–11 via `cfg_iterations` (clamped: $0 \to 1$, $>11 \to 11$ with sticky status flag)
- **Candidate Commit:** Frozen on `phase1-orchestration`

---

### 2. Package Manifest
```text
cadence/
├── filelist.f                  # SystemVerilog source list in strict dependency order
├── constraints/
│   └── cordic.sdc              # Golden SDC constraints (15.0 ns clock, I/O delays, uncertainties)
├── scripts/
│   ├── genus_synth.tcl         # Complete Cadence Genus synthesis script
│   └── innovus_pnr.tcl         # Complete Cadence Innovus place-and-route script
└── README_CADENCE.md           # This execution manual
```

---

### 3. Server Environment Setup

#### In C-Shell (`csh` / `tcsh`):
```csh
# Source EDA tools environment
source /home/install/cshrc   # Adapt to local EDA environment script

# Export target technology library path
setenv GENUS_TARGET_LIB /path/to/pdk/sky130_fd_sc_hd__tt_025C_1v80.lib
setenv INNOVUS_LEF_FILES "/path/to/pdk/sky130_fd_sc_hd.tlef /path/to/pdk/sky130_fd_sc_hd.lef"

# Optional GDS streamout variables
setenv GDS_MAP_FILE /path/to/pdk/sky130_fd_sc_hd.map
setenv GDS_FILES /path/to/pdk/sky130_fd_sc_hd.gds
```

#### In Bourne-Again Shell (`bash`):
```bash
export GENUS_TARGET_LIB="/path/to/pdk/sky130_fd_sc_hd__tt_025C_1v80.lib"
export INNOVUS_LEF_FILES="/path/to/pdk/sky130_fd_sc_hd.tlef /path/to/pdk/sky130_fd_sc_hd.lef"
export GDS_MAP_FILE="/path/to/pdk/sky130_fd_sc_hd.map"
export GDS_FILES="/path/to/pdk/sky130_fd_sc_hd.gds"
```

---

### 4. Step 1: Synthesis with Cadence Genus

Run Genus in batch mode:
```bash
genus -f cadence/scripts/genus_synth.tcl -log genus.log
```

Or run interactively:
```bash
genus
@genus:/> source cadence/scripts/genus_synth.tcl
```

#### Deliverables Generated:
- `outputs_genus/cordic_top_synth.v`: Synthesized gate-level netlist
- `outputs_genus/cordic_top_synth.sdc`: Structural SDC constraints
- `outputs_genus/cordic_top_synth.db`: Genus design database
- `reports_genus/qor.rpt`: Quality of Results summary
- `reports_genus/timing.rpt`: Setup timing report (WNS / TNS)
- `reports_genus/area.rpt`: Gate area and cell count
- `reports_genus/power.rpt`: Switching, internal, and leakage power

---

### 5. Step 2: Physical Design with Cadence Innovus

Run Innovus in batch mode:
```bash
innovus -files cadence/scripts/innovus_pnr.tcl -log innovus.log
```

Or run interactively with GUI:
```bash
innovus -win
innovus 1> source cadence/scripts/innovus_pnr.tcl
```

#### Deliverables Generated:
- `outputs_innovus/cordic_top_routed.v`: Post-route structural Verilog netlist
- `outputs_innovus/cordic_top_routed.def`: Placed and routed DEF
- `outputs_innovus/cordic_top.spef`: Extracted parasitics (RC)
- `outputs_innovus/cordic_top.gds`: Final taped-out GDSII layout
- `reports_innovus/postRoute_setup.tarpt`: Extracted-RC post-route setup timing
- `reports_innovus/postRoute_hold.tarpt`: Extracted-RC post-route hold timing
- `reports_innovus/drc.rpt`: Physical DRC report (target: 0 violations)
- `reports_innovus/connectivity.rpt`: LVS/connectivity verification (target: 0 violations)
- `reports_innovus/power.rpt`: Post-route power report

---

### 6. Expected Results & Quality Gates
| Metric | Expected Value (Sky130 HD) | Sign-off Criteria |
| :--- | :--- | :--- |
| **Logic Cell Count** | ~7,400 cells | Elaboration clean, 0 unresolved |
| **Clock Period** | 15.00 ns (66.7 MHz) | Preserved |
| **Post-Synthesis WNS** | $\ge +2.0$ ns | Setup MET |
| **Post-Route WNS** | $> 0.0$ ns | Setup MET with extracted RC |
| **Post-Route WHS** | $> 0.0$ ns | Hold MET with extracted RC |
| **DRC Violations** | 0 | Clean geometry |
| **Connectivity** | Clean | No floating or shorted nets |
| **Latency** | 12 cycles | Fixed unstalled latency |
