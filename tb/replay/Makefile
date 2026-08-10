# Verilator C++ replay harness for tick_to_trade_top.
#
#   make              # build the harness binary
#   make run IN=stream.mold OUT=rtl.jsonl ORDERS=rtl_orders.jsonl
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

# Strategy/risk scalar parameters. These ARE settable by `verilator -G`, and
# replay_top re-declares them as top-level parameters for exactly that reason.
# The defaults below must stay equal to the trade_pkg *_DEF values and to
# model/dump_trace.py's own defaults -- scripts/run_replay.sh passes the same
# numbers to both sides of the comparison, so a divergence here would show up
# as an order mismatch rather than as a silent difference in what was tuned.
THRESH_LOG2       ?= 2
COOLDOWN_UPDATES  ?= 16
ORDER_SHARES      ?= 100
MAX_POSITION      ?= 1000
MIN_ORDER_SPACING ?= 10
COLLAR_SHIFT      ?= 3

GFLAGS := -GTHRESH_LOG2=$(THRESH_LOG2) -GCOOLDOWN_UPDATES=$(COOLDOWN_UPDATES) \
          -GORDER_SHARES=$(ORDER_SHARES) -GMAX_POSITION=$(MAX_POSITION) \
          -GMIN_ORDER_SPACING=$(MIN_ORDER_SPACING) -GCOLLAR_SHIFT=$(COLLAR_SHIFT)

TOP := replay_top
BIN := replay

# Packages must come before anything that imports them, and trade_pkg itself
# references book_pkg, so the order is book_pkg, trade_pkg, then the rest.
# Neither may be repeated by the wildcard -- a duplicate file triggers MODDUP.
# RTL is the prerequisite list (relative to this directory); RTL_NAMES is the
# same set as bare filenames, used inside the build directory (see below).
PKGS := ../../rtl/book_pkg.sv ../../rtl/trade_pkg.sv
RTL  := $(PKGS) $(filter-out $(PKGS),$(wildcard ../../rtl/*.sv))
RTL_NAMES := $(addprefix rtl/,$(notdir $(RTL)))

# Neither verilator nor the makefile it generates can cope with a source path
# containing a space, which a checkout path may well contain. So
# the whole verilate+compile step runs INSIDE a space-free build directory:
# the RTL directory is symlinked in as `rtl/`, the two local sources are copied
# in, and verilator is invoked with cwd = BUILD_DIR and only relative paths.
# (Passing relative ../../rtl paths from here instead does work for a clean
# build but breaks on rebuild: verilator records those paths in its generated
# dependency files, where they no longer resolve.)
BUILD_DIR ?= /tmp/fpga_proj_vbuild/replay
GEN_HDR   := $(BUILD_DIR)/replay_symbols.svh

# Configuration stamp. SYMBOLS and the -G parameters are baked in at verilate
# time but arrive on the make command line, which changes no file's timestamp
# -- so without this, `make SYMBOLS=AAPL` after a default build would happily
# reuse the previous binary and silently verify the wrong configuration. (Not a
# hypothetical: building at -GTHRESH_LOG2=3 and then rebuilding at the default
# kept the 3 binary, and the 300k replay failed with 15 intents instead of 22.)
#
# The check runs at PARSE time, via $(shell ...), and works by DELETING the
# generated header and the binary when the configuration string has changed.
# Both details are load-bearing. A normal target whose recipe rewrites a stamp
# file does not work here: make 3.81 (the system make on macOS) stats a target
# before remaking its prerequisites and does not re-stat afterwards, so a stamp
# rewritten -- or an output deleted -- during the same invocation is noticed
# only on the NEXT one. Deleting before any target is considered cannot be
# missed.
CONFIG := SYMBOLS=$(SYMBOLS) $(GFLAGS)
STAMP  := $(BUILD_DIR)/.build_config

ifeq (,$(filter clean,$(MAKECMDGOALS)))
_stamp_check := $(shell mkdir -p "$(BUILD_DIR)"; \
  printf '%s\n' '$(CONFIG)' | cmp -s - "$(STAMP)" || { \
    printf '%s\n' '$(CONFIG)' > "$(STAMP)"; \
    rm -f "$(GEN_HDR)" "$(BUILD_DIR)/$(BIN)"; \
  })
endif

# Waivers match tb/unit/Makefile:
#  UNUSEDSIGNAL - decode views intentionally ignore ITCH fields the book doesn't need.
#  UNUSEDPARAM  - book_pkg.sv is a fixed contract; some parameters are used by later modules.
#
# -MAKEFLAGS OPT_FAST=-O3: verilator's generated makefile compiles the model with
# OPT_FAST, which defaults to -Os in verilated.mk and is appended AFTER anything
# -CFLAGS adds, so -CFLAGS "-O3" alone loses. Overriding it on the sub-make
# command line is what actually gets the model built at -O3.
#
# Two traps, both of which silently cost the -O3 build once already:
#  1. Do NOT put a `#` comment line inside the backslash continuation below.
#     GNU make joins continuation lines BEFORE stripping comments, so the `#`
#     truncates the value and every flag after it is silently dropped -- the
#     build still succeeds, just not with the flags you think. Comments about
#     the flags belong here, above the assignment.
#  2. Do NOT add an empty `-LDFLAGS ""`. Verilator 5.050 mis-parses an empty
#     value for it and swallows the FOLLOWING option token, so
#     `-LDFLAGS "" -MAKEFLAGS OPT_FAST=-O3` loses -MAKEFLAGS and dies with
#     "Cannot find file containing module: 'OPT_FAST=-O3'".
# Verify with: make -B -n | grep -- '-MAKEFLAGS'
VFLAGS := --cc --exe --build -O3 --timescale 1ns/1ps -Wall \
          -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
          -CFLAGS "-std=c++17" \
          -MAKEFLAGS OPT_FAST=-O3

IN     ?= /tmp/fpga_proj_vbuild/stream.mold
OUT    ?= /tmp/fpga_proj_vbuild/rtl.jsonl
ORDERS ?= /tmp/fpga_proj_vbuild/rtl_orders.jsonl

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
	cd $(BUILD_DIR) && verilator $(VFLAGS) $(GFLAGS) -Irtl -I. --Mdir . \
	    $(RTL_NAMES) replay_top.sv --top $(TOP) replay_main.cpp -o $(BIN)

run: $(BUILD_DIR)/$(BIN)
	$(BUILD_DIR)/$(BIN) --in "$(IN)" --out "$(OUT)" --orders-out "$(ORDERS)"

clean:
	rm -rf obj_dir $(BUILD_DIR)
