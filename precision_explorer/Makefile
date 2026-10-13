#==============================================================================
# Makefile for precision_explorer
# Runs the full precision explorer harness: simulation, analysis, and tests.
#==============================================================================

.PHONY: all run test clean

all: run

run:
	bash run_explorer.sh

test:
	python3 test_precision_explorer.py

clean:
	rm -f Vadaptive_precision_tb* rtl_sim_results.txt
