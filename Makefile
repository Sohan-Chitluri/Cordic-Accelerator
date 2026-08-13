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

# Tool configuration
VERILATOR       := verilator
VERILATOR_FLAGS := --lint-only -Wall -Wno-UNUSED -Wno-PINCONNECTEMPTY -Wno-DECLFILENAME \
                   --top-module $(TOP_MODULE) \
                   --sv

YOSYS           := yosys
OPENSTA         := sta

# Simulation
SIM_TOOL        := verilator
SIM_FLAGS       := --cc --exe --build -j 0 -O3 -CFLAGS "-O3 -std=c++17" --no-timing \
                   --trace --trace-structs \
                   --sv

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

# C++ test harness for Verilator
SIM_MAIN := $(TB_DIR)/sim_main.cpp

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
sim: $(SIM_MAIN)
	@echo "=== Building Simulation ==="
	@mkdir -p $(OUTPUT_DIR)
	$(VERILATOR) $(SIM_FLAGS) $(RTL_SOURCES) $(TB_SOURCES) $(SIM_MAIN) \
		-o $(OUTPUT_DIR)/V$(TOP_MODULE)
	@echo "=== Simulation Build Complete ==="

.PHONY: sim-run
sim-run: sim
	@echo "=== Running Simulation ==="
	$(OUTPUT_DIR)/V$(TOP_MODULE)

# -----------------------------------------------------------------------------
# UNIT TESTS (per module)
# -----------------------------------------------------------------------------
.PHONY: test-unit-fp_add_sub
test-unit-fp_add_sub:
	@echo "=== Unit Test: fp_add_sub ==="
	$(VERILATOR) $(SIM_FLAGS) \
		$(RTL_DIR)/pkg/cordic_pkg.sv \
		$(RTL_DIR)/fp_add_sub.sv \
		$(TB_DIR)/fp_add_sub_tb.sv \
		$(SIM_MAIN) \
		-o $(OUTPUT_DIR)/Vfp_add_sub_test
	$(OUTPUT_DIR)/Vfp_add_sub_test

.PHONY: test-unit-cordic_lut
test-unit-cordic_lut:
	@echo "=== Unit Test: cordic_lut ==="
	$(VERILATOR) $(SIM_FLAGS) \
		$(RTL_DIR)/pkg/cordic_pkg.sv \
		$(RTL_DIR)/cordic_lut.sv \
		$(TB_DIR)/cordic_lut_tb.sv \
		$(SIM_MAIN) \
		-o $(OUTPUT_DIR)/Vcordic_lut_test
	$(OUTPUT_DIR)/Vcordic_lut_test

.PHONY: test-unit-cordic_stage
test-unit-cordic_stage:
	@echo "=== Unit Test: cordic_stage ==="
	$(VERILATOR) $(SIM_FLAGS) \
		$(RTL_DIR)/pkg/cordic_pkg.sv \
		$(RTL_DIR)/fp_add_sub.sv \
		$(RTL_DIR)/cordic_lut.sv \
		$(RTL_DIR)/cordic_stage.sv \
		$(TB_DIR)/cordic_stage_tb.sv \
		$(SIM_MAIN) \
		-o $(OUTPUT_DIR)/Vcordic_stage_test
	$(OUTPUT_DIR)/Vcordic_stage_test

.PHONY: test-unit-cordic_pipeline
test-unit-cordic_pipeline:
	@echo "=== Unit Test: cordic_pipeline ==="
	$(VERILATOR) $(SIM_FLAGS) \
		$(RTL_DIR)/pkg/cordic_pkg.sv \
		$(RTL_DIR)/fp_add_sub.sv \
		$(RTL_DIR)/cordic_lut.sv \
		$(RTL_DIR)/cordic_stage.sv \
		$(RTL_DIR)/cordic_pipeline.sv \
		$(TB_DIR)/cordic_pipeline_tb.sv \
		$(SIM_MAIN) \
		-o $(OUTPUT_DIR)/Vcordic_pipeline_test
	$(OUTPUT_DIR)/Vcordic_pipeline_test

.PHONY: test-unit-cordic_top
test-unit-cordic_top:
	@echo "=== Unit Test: cordic_top ==="
	$(VERILATOR) $(SIM_FLAGS) \
		$(RTL_SOURCES) \
		$(TB_DIR)/cordic_top_tb.sv \
		$(SIM_MAIN) \
		-o $(OUTPUT_DIR)/Vcordic_top_test
	$(OUTPUT_DIR)/Vcordic_top_test

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
	$(VERILATOR) $(SIM_FLAGS) $(COVERAGE_FLAGS) $(RTL_SOURCES) $(TB_SOURCES) $(SIM_MAIN) \
		-o $(OUTPUT_DIR)/V$(TOP_MODULE)_cov
	$(OUTPUT_DIR)/V$(TOP_MODULE)_cov
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
	$(YOSYS) -s $(SCRIPTS_DIR)/synth.tcl
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
# PYTHON GOLDEN MODEL
# -----------------------------------------------------------------------------
.PHONY: golden
golden:
	@echo "=== Running Golden Model ==="
	python3 $(TB_DIR)/golden_model.py

.PHONY: gen-vectors
gen-vectors:
	@echo "=== Generating Test Vectors ==="
	python3 $(TB_DIR)/golden_model.py gen 10000 $(TB_DIR)/test_vectors/regression_10k.json

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
	@echo "Maintenance:"
	@echo "  make clean         - Remove build artifacts"
	@echo "  make clean-all     - Remove all generated files"
	@echo "  make help          - Show this help"