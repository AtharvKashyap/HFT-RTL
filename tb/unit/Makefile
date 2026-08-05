# Shared Verilator invocation for all unit testbenches.
#   make TOP=tb_itch_decoder run
TOP ?= tb_itch_decoder

# book_pkg.sv must be compiled first (it declares the package everything imports),
# and must not be repeated by the wildcard -- a duplicate file triggers MODDUP.
RTL := ../../rtl/book_pkg.sv \
       $(filter-out ../../rtl/book_pkg.sv,$(wildcard ../../rtl/*.sv))

# Waivers:
#  UNUSEDSIGNAL - decode views intentionally ignore ITCH fields the book doesn't need.
#  UNUSEDPARAM  - book_pkg.sv is a fixed contract; some parameters are used by later modules.
VFLAGS := --binary --timing --timescale 1ns/1ps -Wall \
          -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM

# Verilator's generated makefile cannot build in a directory whose path contains
# spaces, and this repo lives under ".../Claude projects/...", so build out of tree.
BUILD_DIR ?= /tmp/fpga_proj_vbuild/$(TOP)

run:
	mkdir -p $(BUILD_DIR)
	verilator $(VFLAGS) -I../../rtl --Mdir $(BUILD_DIR) $(RTL) $(TOP).sv --top $(TOP) -o $(TOP)
	$(BUILD_DIR)/$(TOP)

clean:
	rm -rf obj_dir $(BUILD_DIR)

.PHONY: run clean
