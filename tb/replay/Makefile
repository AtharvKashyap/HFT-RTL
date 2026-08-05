# Verilator C++ replay harness for itch_book_top.
#
#   make              # build the harness binary
#   make run IN=stream.mold OUT=rtl.jsonl
#   make clean
#
# SYMBOLS is fixed AT VERILATE TIME. `verilator -G` cannot set an unpacked
# array parameter (which is what itch_book_top's SYMBOLS is), so the list is
# rendered into a generated header, replay_symbols.svh, by
# scripts/gen_symbols.py and `include`d by tb/replay/replay_top.sv. Index i in
# this list is book_idx i, so it MUST match the order given to
# `model/dump_trace.py --symbols` for book_idx to equal symbol_idx. Override
# with e.g. `make SYMBOLS=AAPL,MSFT` (rebuilds the header and re-verilates).
SYMBOLS ?= AAPL,MSFT,SPY,QQQ,TSLA,NVDA,AMD,INTC

TOP := replay_top
BIN := replay

# book_pkg.sv must come first (it declares the package everything imports) and
# must not be repeated by the wildcard -- a duplicate file triggers MODDUP.
# RTL is the prerequisite list (relative to this directory); RTL_NAMES is the
# same set as bare filenames, used inside the build directory (see below).
RTL := ../../rtl/book_pkg.sv \
       $(filter-out ../../rtl/book_pkg.sv,$(wildcard ../../rtl/*.sv))
RTL_NAMES := $(addprefix rtl/,$(notdir $(RTL)))

# Neither verilator nor the makefile it generates can cope with a source path
# containing a space, and this repo lives under ".../Claude projects/...". So
# the whole verilate+compile step runs INSIDE a space-free build directory:
# the RTL directory is symlinked in as `rtl/`, the two local sources are copied
# in, and verilator is invoked with cwd = BUILD_DIR and only relative paths.
# (Passing relative ../../rtl paths from here instead does work for a clean
# build but breaks on rebuild: verilator records those paths in its generated
# dependency files, where they no longer resolve.)
BUILD_DIR ?= /tmp/fpga_proj_vbuild/replay
GEN_HDR   := $(BUILD_DIR)/replay_symbols.svh

# Waivers match tb/unit/Makefile:
#  UNUSEDSIGNAL - decode views intentionally ignore ITCH fields the book doesn't need.
#  UNUSEDPARAM  - book_pkg.sv is a fixed contract; some parameters are used by later modules.
VFLAGS := --cc --exe --build -O3 --timescale 1ns/1ps -Wall \
          -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
          -CFLAGS "-O3 -std=c++17" -LDFLAGS ""

IN  ?= /tmp/fpga_proj_vbuild/stream.mold
OUT ?= /tmp/fpga_proj_vbuild/rtl.jsonl

.PHONY: all run print-bin clean

all: $(BUILD_DIR)/$(BIN)

# scripts/run_replay.sh asks for the binary path and invokes it itself: file
# paths in this repo contain a space, and make cannot pass those through a
# recipe variable safely.
print-bin:
	@echo $(BUILD_DIR)/$(BIN)

$(GEN_HDR): ../../scripts/gen_symbols.py Makefile
	mkdir -p $(BUILD_DIR)
	python3 ../../scripts/gen_symbols.py '$(SYMBOLS)' > $@

$(BUILD_DIR)/$(BIN): $(GEN_HDR) replay_top.sv replay_main.cpp $(RTL)
	mkdir -p $(BUILD_DIR)
	ln -sfn "$(abspath ../../rtl)" $(BUILD_DIR)/rtl
	cp replay_main.cpp replay_top.sv $(BUILD_DIR)/
	cd $(BUILD_DIR) && verilator $(VFLAGS) -Irtl -I. --Mdir . \
	    $(RTL_NAMES) replay_top.sv --top $(TOP) replay_main.cpp -o $(BIN)

run: $(BUILD_DIR)/$(BIN)
	$(BUILD_DIR)/$(BIN) --in "$(IN)" --out "$(OUT)"

clean:
	rm -rf obj_dir $(BUILD_DIR)
