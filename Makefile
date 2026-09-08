#==============================================================================
# Makefile for CORDIC Accelerator ASIC Project
# Targets: lint, sim, test, synth, sta, clean, coverage
# Language: SystemVerilog (IEEE 1800-2012) — ASIC-safe subset
#==============================================================================

# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------
TOP_MODULE      := cordic_top
RTL_DIR         := rtl
TB_DIR          := tb
CONSTRAINTS_DIR := constraints
SCRIPTS_DIR     := scripts
OUTPUT_DIR      := output
ABS_OUTPUT      := $(abspath $(OUTPUT_DIR))

# Tool configuration
VERILATOR       := verilator
# -Wno-VARHIDDEN: modules intentionally re-expose package params (WIDTH, FRACT_W,
# ITERATIONS) as overridable parameters defaulting to cordic_pkg values; the
# name reuse shadows the wildcard-imported package identifiers by design.
# -Wno-IMPORTSTAR: compilation-unit scope import is used for Yosys 0.67
# compatibility (Yosys does not support module-header or module-body import).
VERILATOR_FLAGS := --lint-only -Wall -Wno-UNUSED -Wno-PINCONNECTEMPTY -Wno-DECLFILENAME \
                   -Wno-VARHIDDEN -Wno-IMPORTSTAR \
                   --top-module $(TOP_MODULE) \
                   --sv

YOSYS           := yosys
OPENSTA         := sta

# Simulation
SIM_TOOL        := verilator
SIM_FLAGS       := --binary -j 0 -O3 -CFLAGS "-O3 -std=c++17" \
                   --trace --trace-structs \
                   -Wno-VARHIDDEN \
                   -Wno-TIMESCALEMOD \
                   --sv --timing --assert

# Coverage
COVERAGE_TOOL   := verilator
COVERAGE_FLAGS  := --coverage --coverage-underscore

# -----------------------------------------------------------------------------
# FILE LISTS
# -----------------------------------------------------------------------------
RTL_SOURCES := \
	$(RTL_DIR)/pkg/cordic_pkg.sv \
	$(RTL_DIR)/common/cordic_assertions.sv \
	$(RTL_DIR)/fp_add_sub.sv \
	$(RTL_DIR)/cordic_lut.sv \
	$(RTL_DIR)/cordic_stage.sv \
	$(RTL_DIR)/cordic_pipeline.sv \
	$(RTL_DIR)/cordic_top.sv

TB_SOURCES := \
	$(TB_DIR)/fp_add_sub_tb.sv \
	$(TB_DIR)/cordic_lut_tb.sv \
	$(TB_DIR)/cordic_stage_tb.sv \
	$(TB_DIR)/cordic_pipeline_tb.sv \
	$(TB_DIR)/cordic_top_tb.sv

# Top-level simulation testbench (self-checking, --binary)
SIM_TB_TOP := cordic_top_tb

# -----------------------------------------------------------------------------
# DEFAULT TARGET
# -----------------------------------------------------------------------------
.PHONY: all
all: lint sim

# -----------------------------------------------------------------------------
# LINTING
# -----------------------------------------------------------------------------
.PHONY: lint
lint:
	@echo "=== Running Verilator Lint ==="
	@mkdir -p $(OUTPUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) $(RTL_SOURCES)
	@echo "=== Lint Complete ==="

.PHONY: lint-full
lint-full:
	@echo "=== Running Verilator Full Lint (with TB) ==="
	@mkdir -p $(OUTPUT_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) $(RTL_SOURCES) $(TB_SOURCES)

# -----------------------------------------------------------------------------
# SIMULATION
# -----------------------------------------------------------------------------
.PHONY: sim
sim:
	@echo "=== Building Simulation ==="
	@mkdir -p $(OUTPUT_DIR)
	$(VERILATOR) $(SIM_FLAGS) \
		--top-module $(SIM_TB_TOP) \
		$(RTL_SOURCES) \
		$(TB_DIR)/$(SIM_TB_TOP).sv \
		-o $(ABS_OUTPUT)/V$(SIM_TB_TOP)
	@echo "=== Simulation Build Complete ==="

.PHONY: sim-run
sim-run: sim
	@echo "=== Running Simulation ==="
	$(ABS_OUTPUT)/V$(SIM_TB_TOP)

# -----------------------------------------------------------------------------
# UNIT TESTS (per module)
# -----------------------------------------------------------------------------
.PHONY: test-unit-fp_add_sub
test-unit-fp_add_sub:
	@echo "=== Unit Test: fp_add_sub ==="
	@mkdir -p $(OUTPUT_DIR)
	$(VERILATOR) $(SIM_FLAGS) \
		--top-module fp_add_sub_tb \
		$(RTL_DIR)/pkg/cordic_pkg.sv \
		$(RTL_DIR)/fp_add_sub.sv \
		$(TB_DIR)/fp_add_sub_tb.sv \
		-o $(ABS_OUTPUT)/Vfp_add_sub_tb
	$(ABS_OUTPUT)/Vfp_add_sub_tb

.PHONY: test-unit-cordic_lut
test-unit-cordic_lut:
	@echo "=== Unit Test: cordic_lut ==="
	@mkdir -p $(OUTPUT_DIR)
	$(VERILATOR) $(SIM_FLAGS) \
		--top-module cordic_lut_tb \
		$(RTL_DIR)/pkg/cordic_pkg.sv \
		$(RTL_DIR)/cordic_lut.sv \
		$(TB_DIR)/cordic_lut_tb.sv \
		-o $(ABS_OUTPUT)/Vcordic_lut_tb
	$(ABS_OUTPUT)/Vcordic_lut_tb

.PHONY: test-unit-cordic_stage
test-unit-cordic_stage:
	@echo "=== Unit Test: cordic_stage ==="
	@mkdir -p $(OUTPUT_DIR)
	$(VERILATOR) $(SIM_FLAGS) \
		--top-module cordic_stage_tb \
		$(RTL_DIR)/pkg/cordic_pkg.sv \
		$(RTL_DIR)/fp_add_sub.sv \
		$(RTL_DIR)/cordic_stage.sv \
		$(TB_DIR)/cordic_stage_tb.sv \
		-o $(ABS_OUTPUT)/Vcordic_stage_tb
	$(ABS_OUTPUT)/Vcordic_stage_tb

.PHONY: test-unit-cordic_pipeline
test-unit-cordic_pipeline:
	@echo "=== Integration Test: cordic_pipeline ==="
	@mkdir -p $(OUTPUT_DIR)
	$(VERILATOR) $(SIM_FLAGS) \
		--top-module cordic_pipeline_tb \
		$(RTL_DIR)/pkg/cordic_pkg.sv \
		$(RTL_DIR)/fp_add_sub.sv \
		$(RTL_DIR)/cordic_lut.sv \
		$(RTL_DIR)/cordic_stage.sv \
		$(RTL_DIR)/cordic_pipeline.sv \
		$(TB_DIR)/cordic_pipeline_tb.sv \
		-o $(ABS_OUTPUT)/Vcordic_pipeline_tb
	$(ABS_OUTPUT)/Vcordic_pipeline_tb

.PHONY: test-unit-cordic_top
test-unit-cordic_top:
	@echo "=== Integration Test: cordic_top ==="
	@mkdir -p $(OUTPUT_DIR)
	$(VERILATOR) $(SIM_FLAGS) \
		--top-module cordic_top_tb \
		$(RTL_SOURCES) \
		$(TB_DIR)/cordic_top_tb.sv \
		-o $(ABS_OUTPUT)/Vcordic_top_tb
	$(ABS_OUTPUT)/Vcordic_top_tb

.PHONY: test-unit
test-unit: test-unit-fp_add_sub test-unit-cordic_lut test-unit-cordic_stage test-unit-cordic_pipeline test-unit-cordic_top

# -----------------------------------------------------------------------------
# REGRESSION TEST
# -----------------------------------------------------------------------------
.PHONY: test
test: test-unit
	@echo "=== All Unit Tests Passed ==="

# -----------------------------------------------------------------------------
# COVERAGE
# -----------------------------------------------------------------------------
.PHONY: coverage
coverage:
	@echo "=== Running with Coverage ==="
	@mkdir -p $(OUTPUT_DIR)/coverage
	$(VERILATOR) $(SIM_FLAGS) $(COVERAGE_FLAGS) \
		--top-module $(SIM_TB_TOP) \
		$(RTL_SOURCES) \
		$(TB_DIR)/$(SIM_TB_TOP).sv \
		-o $(ABS_OUTPUT)/V$(SIM_TB_TOP)_cov
	$(ABS_OUTPUT)/V$(SIM_TB_TOP)_cov
	@echo "=== Coverage Data Generated ==="

.PHONY: coverage-report
coverage-report:
	@echo "=== Generating Coverage Report ==="
	verilator_coverage --annotate $(OUTPUT_DIR)/coverage.annotated \
		$(OUTPUT_DIR)/coverage.dat
	@echo "=== Coverage Report Complete ==="

# -----------------------------------------------------------------------------
# SYNTHESIS
# -----------------------------------------------------------------------------
.PHONY: synth
synth:
	@echo "=== Running Yosys Synthesis ==="
	@mkdir -p $(OUTPUT_DIR)
	$(YOSYS) -s $(SCRIPTS_DIR)/synth.tcl 2>&1 | tee $(OUTPUT_DIR)/yosys_synth.log
	@echo "=== Synthesis Complete ==="

# -----------------------------------------------------------------------------
# STATIC TIMING ANALYSIS
# -----------------------------------------------------------------------------
.PHONY: sta
sta:
	@echo "=== Running OpenSTA ==="
	@mkdir -p $(OUTPUT_DIR)
	$(OPENSTA) $(SCRIPTS_DIR)/sta.tcl
	@echo "=== STA Complete ==="

# -----------------------------------------------------------------------------
# FORMAL VERIFICATION
# -----------------------------------------------------------------------------
.PHONY: formal
formal:
	@echo "=== Running Formal Verification (SymbiYosys) ==="
	@mkdir -p $(OUTPUT_DIR)/formal
	sby -f $(TB_DIR)/formal/cordic_formal.sby
	@echo "=== Formal Verification Complete ==="

# -----------------------------------------------------------------------------
# PLACE & ROUTE (Open-source flow)
# Note: Requires OpenROAD, Magic, and Netgen
# Install with: nix flake update && nix develop
# Or provide PDK and constraint files for commercial tools
# -----------------------------------------------------------------------------
.PHONY: pr
pr:
	@echo "=== Open-source P&R Flow Not Configured ==="
	@echo "To complete P&R, you have two options:"
	@echo ""
	@echo "Option 1: Install open-source tools"
	@echo "  - OpenROAD: https://github.com/The-OpenROAD-Project"
	@echo "  - Magic: http://opencircuitdesign.com/magic/"
	@echo "  - Netgen: http://opencircuitdesign.com/netgen/"
	@echo ""
	@echo "Option 2: Use commercial tools with synthesized netlist"
	@echo "  - Input: $(OUTPUT_DIR)/cordic_top_synth.v"
	@echo "  - Requires: PDK + Cadence Innovus/Synopsys ICC2"
	@echo ""
	@echo "Synthesized netlist ready at: $(OUTPUT_DIR)/cordic_top_synth.v"
	@echo "=== P&R Ready ==="

.PHONY: drc
drc:
	@echo "=== DRC/LVS Flow Not Configured ==="
	@echo "To run DRC and LVS checks, you need:"
	@echo ""
	@echo "Open-source:"
	@echo "  - Magic: Design Rule Checking"
	@echo "  - Netgen: Layout vs Schematic verification"
	@echo ""
	@echo "Commercial:"
	@echo "  - Cadence Assura or Calibre"
	@echo ""
	@echo "Available: Synthesized netlist at $(OUTPUT_DIR)/cordic_top_synth.v"

# -----------------------------------------------------------------------------
# PYTHON GOLDEN MODEL
# -----------------------------------------------------------------------------
.PHONY: golden
golden:
	@echo "=== Running Golden Model ==="
	python3 $(TB_DIR)/golden_model.py

.PHONY: gen-vectors
gen-vectors:
	@echo "=== Generating Test Vectors ==="
	@mkdir -p $(TB_DIR)/test_vectors
	python3 $(TB_DIR)/golden_model.py gen     10000 $(TB_DIR)/test_vectors/regression_10k.json
	python3 $(TB_DIR)/golden_model.py gen-mem 10000 $(TB_DIR)/test_vectors/regression.mem

# -----------------------------------------------------------------------------
# CLEAN
# -----------------------------------------------------------------------------
.PHONY: clean
clean:
	@echo "=== Cleaning Build Artifacts ==="
	rm -rf obj_dir
	rm -rf $(OUTPUT_DIR)
	rm -rf coverage.dat
	rm -rf *.vcd
	rm -rf *.fst
	@echo "=== Clean Complete ==="

.PHONY: clean-all
clean-all: clean
	rm -rf $(OUTPUT_DIR)/formal
	rm -rf $(OUTPUT_DIR)/coverage*

# -----------------------------------------------------------------------------
# HELP
# -----------------------------------------------------------------------------
.PHONY: help
help:
	@echo "CORDIC Accelerator ASIC Project - Makefile Targets"
	@echo ""
	@echo "Verification:"
	@echo "  make lint          - Run Verilator lint on RTL"
	@echo "  make lint-full     - Run Verilator lint on RTL + TB"
	@echo "  make sim           - Build simulation executable"
	@echo "  make sim-run       - Build and run simulation"
	@echo "  make test          - Run all unit tests"
	@echo "  make test-unit-*   - Run specific unit test"
	@echo "  make coverage      - Run simulation with coverage"
	@echo "  make formal        - Run formal verification (SymbiYosys)"
	@echo "  make golden        - Run Python golden model"
	@echo "  make gen-vectors   - Generate regression test vectors"
	@echo ""
	@echo "Synthesis & STA:"
	@echo "  make synth         - Run Yosys synthesis"
	@echo "  make sta           - Run OpenSTA timing analysis"
	@echo ""
	@echo "Physical Design (requires external P&R tool):"
	@echo "  make pr            - Show P&R flow options"
	@echo "  make drc           - Show DRC/LVS flow options"
	@echo ""
	@echo "Maintenance:"
	@echo "  make clean         - Remove build artifacts"
	@echo "  make clean-all     - Remove all generated files"
	@echo "  make help          - Show this help"