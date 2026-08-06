# Hardware Limit Order Book — Design Spec

**Date:** 2026-08-05
**Status:** Approved for planning

## Purpose

A synthesizable SystemVerilog engine that consumes a raw Nasdaq TotalView-ITCH 5.0
market data stream and maintains live limit order books for a configurable set of
symbols, emitting best-bid/best-ask and top-of-book depth updates within a few clock
cycles of each input message.

Primary goal: a portfolio piece for HFT/FPGA roles. The credibility comes from
(a) using the real exchange protocol and real captured market data, and
(b) verification rigor — golden-model replay over tens of millions of real messages,
constrained-random unit tests, in-RTL assertions, and measured latency numbers.

Phase-2 extension path (out of scope for this spec): strategy block + order
generator to become a full tick-to-trade engine; Vivado synthesis; board deployment.

## Scope decisions (locked)

| Decision | Choice |
|---|---|
| Protocol | Nasdaq TotalView-ITCH 5.0 over MoldUDP64 framing |
| Symbols | Multi-symbol, configurable up to 16 (parameter `NUM_SYMBOLS`) |
| Book style | Aggregated price-level book, top `N_LEVELS` = 8 per side |
| Order tracking | Order-ID table required (ITCH cancels/executes reference order IDs only) |
| Target | Simulation-first; all RTL synthesizable from day one; board port later |
| Primary sim | Verilator on macOS; VCS + UVM on university Linux server as a later bonus |

## Architecture

```
                 ┌────────────────────────────────────────────────────────┐
                 │                    itch_book_top                       │
 raw byte  ──▶ ┌──────────┐   ┌──────────┐   ┌───────────┐   ┌──────────┐ │
 stream        │ MoldUDP64│──▶│  ITCH    │──▶│ Order-ID  │──▶│ Price-   │─┼─▶ book updates /
 (AXI-Stream)  │  framer  │   │ decoder  │   │ table +   │   │ level    │ │   best bid-ask
               └──────────┘   └──────────┘   │ symbol    │   │ books ×N │ │   (AXI-Stream)
                                             │ filter    │   └──────────┘ │
                                             └───────────┘                │
                 └────────────────────────────────────────────────────────┘
```

All inter-module interfaces are ready/valid streaming. Shared types, parameters,
and message structs live in a common package (`book_pkg`).

### Module 1: `mold_framer`

- Input: raw byte stream (AXI-Stream, width parameterizable; v1 implements 1 byte/cycle — ample for simulation, widening is a phase-2 item).
- Unwraps MoldUDP64: session (10B), sequence number (8B), message count (2B),
  then length-prefixed messages.
- Checks sequence continuity; on a gap, asserts a sticky `gap_detected` status
  and continues (no re-request in scope).
- Output: one ITCH message per beat group with message-boundary framing.

### Module 2: `itch_decoder`

- Decodes the ITCH 5.0 message types needed for a book:
  - `A` Add Order, `F` Add Order with MPID
  - `E` Order Executed, `C` Order Executed with Price
  - `X` Order Cancel (partial), `D` Order Delete
  - `U` Order Replace
  - `S` System Event (start/end of day markers, pass-through for harness use)
- Output: `decoded_msg_t` struct — msg kind, order ID (64b), symbol (8×8b),
  side, shares (32b), price (32b, fixed-point 1/10000 dollars per ITCH spec).
- Unknown/ignored message types increment a counter and are dropped; never fatal.
- Note: ITCH fields are big-endian; decoder normalizes.

### Module 3: `symbol_filter` + `order_id_table`

- Symbol filter: small CAM mapping symbol → book index for up to `NUM_SYMBOLS`
  configured symbols (set via parameter/config port at reset). Non-tracked
  symbols: Add messages are dropped; by construction their order IDs never
  enter the table, so their cancels/executes miss and are dropped too.
- Order-ID table: memory mapping order ID → {book index, side, price, shares}.
  - Written on Add; looked up and updated on Execute/Cancel; freed on Delete
    and on Execute/Cancel that zeroes remaining shares.
  - Replace (`U`) = delete old ID + add new ID with new price/shares.
  - Implementation: hash table in BRAM-style memory with a bounded-probe
    scheme; capacity `TABLE_SIZE` parameter (default 2^16 live orders).
    Table-full and lookup-miss increment error counters, message dropped.
- Output: a resolved book operation: {book index, side, price, qty delta kind}.

### Module 4: `price_book` (one per tracked symbol, generate loop)

- Per side (bid, ask): sorted array of top `N_LEVELS`=8 price levels held in
  registers: {price, aggregate shares}. Bids sorted descending, asks ascending.
- Operations: insert new level (shift), add shares to existing level, reduce
  shares, remove level on zero (shift up). Fixed small cycle count per op;
  parallel compare across levels (CAM-like), not iterative search.
- Prices falling outside the tracked top-8 window are dropped from the
  book view (accepted approximation, documented; the order-ID table still
  tracks them so later cancels resolve correctly).
- Output: on any change to the book, emit `book_update_t`: {symbol index,
  side, best price, best shares, full 8-level snapshot, cycle timestamp}.
- In-RTL assertions: levels strictly sorted, no duplicate prices,
  best bid < best ask (when both sides non-empty), shares never underflow.

### Module 5: `itch_book_top`

- Wires modules together; AXI-Stream in (raw bytes) and out (book updates).
- Status/observability port: gap count, dropped-message counters, table
  occupancy — readable by the testbench (and later a control interface).

## Verification plan

### Layer 1 — Unit testbenches (Verilator, per module)

- Self-checking SV testbenches; directed tests for edge cases:
  - framer: gaps, heartbeats (count=0), messages split across beats
  - decoder: every message type, endianness, unknown types
  - order table: collision handling, table full, double delete, replace chains
  - price book: insert at top/middle/bottom, level eviction, side crossing,
    reduce-to-zero, book full/empty
- Constrained-random stimulus with functional coverage goals
  (message kind × book state cross).
- SVA assertions compiled into RTL (Verilator supports immediate +
  restricted concurrent assertions; keep to the supported subset).

### Layer 2 — Golden-model replay (headline result)

- Python reference model (`model/`): ITCH parser + order book with identical
  semantics, including identical top-8 truncation behavior, so outputs are
  bit-comparable. Few hundred lines, reviewable by eye.
- Data: real Nasdaq TotalView-ITCH 5.0 sample capture files (Nasdaq publishes
  free historical full-day files, e.g. via their FTP/S3 sample sets).
  `data/` is gitignored; a download script + README documents provenance.
- Harness: C++ Verilator driver streams the same bytes into the RTL and into
  the Python model's dumped event trace; compares every `book_update_t`
  field-by-field. Target: ≥10M real messages, zero mismatches.
- Robustness fuzz: mutated/truncated/corrupted frames — design must drop and
  count, never hang or corrupt book state (checked by resuming clean replay
  after fuzz burst).

### Layer 3 — Latency measurement

- Cycle timestamps at ingress (framer input) and egress (book update out);
  harness reports min/median/p99/max cycles per message kind.
- After later Vivado synthesis: achieved Fmax converts cycles → nanoseconds.

### Bonus phase (non-blocking)

- Same RTL under VCS on university server; UVM testbench at top level
  (driver/monitor/scoreboard reusing the Python-generated golden trace).

## Repo layout

```
rtl/           synthesizable modules + book_pkg
tb/unit/       per-module testbenches
tb/replay/     Verilator C++ replay harness
model/         Python golden model + trace dumper
data/          market data (gitignored) + download script
docs/          this spec, diagrams, results writeup
Makefile       build/sim/test entry points
```

## Milestones

1. **M1 — Golden model:** Python ITCH parser + book; download real data;
   print live book states. (Also serves as protocol learning.)
2. **M2 — `itch_decoder`** + unit TB.
3. **M3 — `mold_framer`** + unit TB.
4. **M4 — `price_book`** + unit TB (hardest module).
5. **M5 — `order_id_table` + `symbol_filter`** + unit TBs.
6. **M6 — Integration:** `itch_book_top` + replay harness; 10M-message
   zero-mismatch run; latency report. ← portfolio-ready point
7. **M7 (later) —** UVM-on-VCS bonus; Vivado synthesis/timing; board port.

## Error handling philosophy

Market data hardware must never hang or silently corrupt: every abnormal
condition (gap, unknown type, table full, untracked symbol, malformed frame)
is **counted, surfaced via status, and the message dropped** — the pipeline
always keeps consuming. No condition is fatal in hardware.

## Success criteria

- All unit TBs pass with coverage goals met.
- Replay of ≥10M real Nasdaq messages with zero golden-model mismatches.
- Measured per-message latency in cycles (target: ≤10 cycles ingress→update
  for non-shifting updates; document actuals).
- Clean, documented repo a hiring manager can skim in 10 minutes.

## Deviations from this spec (as shipped)

This spec was written before implementation and was not rewritten during it.
The list below is the complete set of places where the shipped design differs
from the text above, so the spec can be read as a record of intent without
being mistaken for a description of the code.

### Functional coverage — hand-rolled tallies, not covergroups

The verification plan asks for "constrained-random stimulus with functional
coverage goals (message kind × book state cross)". SystemVerilog covergroups
are not implemented by Verilator, which is this project's only simulator, so
coverage is collected **procedurally** instead: plain integer bin arrays
incremented inside the testbenches' existing reference models (which already
classify every op and every message), with an all-bins-hit gate that `$fatal`s
at the end of the random phase if any bin is zero. An uncovered case fails the
run rather than showing up as a percentage nobody reads.

Coverage lives in the unit TBs, at the op / message level, and the spec's
single "message kind × book state" cross is realized as two tallies either side
of the module boundary that separates order tracking from book state:

- **`tb/unit/tb_price_book.sv`** (book state) — op outcome × side, 14 bins:
  {ADD-new-level, ADD-aggregate, ADD-evict-9th, ADD-reject-full,
  REDUCE-partial, REDUCE-remove, REDUCE-miss} × {bid, ask}.
- **`tb/unit/tb_book_router.sv`** (message kind × order-table state) — 10 bins:
  {ADD, EXEC, CANCEL, DELETE, REPLACE} × {hit, miss}, where for ADD the split
  is tracked / untracked symbol (an untracked ADD never enters the table) and
  for the other four it is order-id lookup hit / miss.

Both were confirmed empirically to fill every bin with the shipped op mix; no
bin is unreachable and none required loosening.

### Structural and parameter deviations

| Spec says | Shipped | Why |
|---|---|---|
| `TABLE_SIZE` default 2^16 live orders (Module 3) | `TABLE_ADDR_W = 22`, i.e. 2^22 = 4,194,304 slots | Not an occupancy problem but a *clustering* problem: near-sequential ITCH order ids XOR-fold to near-sequential slots and linear probing piles them into contiguous runs, so at 2^20 the 8-deep probe window overflowed on the real capture and permanently diverged. Extra address bits spread the runs out; a bigger probe window does not. Rationale and the measured sizing experiment are in the comment in `rtl/book_pkg.sv`. |
| Module 3 = `symbol_filter` + `order_id_table` as separate modules | Merged into one module, `rtl/book_router.sv` | The two share a single FSM and one pass over the message: the symbol lookup decides whether the table insert happens at all. Splitting them would mean handing the filter result across a ready/valid boundary for no benefit. |
| Module 5 status port exposes "table occupancy" | `occupancy` exists on `book_router` and is checked by `tb_book_router`, but is **not** brought out of `itch_book_top` | Nothing above the top level consumes it; the replay harness checks the drop/full counters instead. Re-exposing it is a one-line change if a control interface ever needs it. |
| Module 1 input width "parameterizable" (`BYTES_PER_BEAT`) | 1 byte/cycle, hardwired; no such parameter exists | v1 was always specified as 1 byte/cycle and widening was flagged as a phase-2 item, but the parameter was never introduced even as a stub. The `mold_framer` datapath assumes single-byte beats throughout. |
| Layer 3: latency = ingress (framer input) → egress | Latency (`lat`) is measured **`msg_boundary` → `upd_valid`** | The definition used, and the reason for it, are documented under "Latency" in `docs/results.md`: it isolates the decode → table-lookup → book-update pipeline and excludes the 1 byte/cycle message shift-in, which is a datapath-width property rather than a pipeline property. Ingress→egress would mostly measure message length. |

### Robustness fuzz — scope actually verified

The plan says the design "must drop and count, never hang or corrupt book
state (checked by resuming clean replay after fuzz burst)". What
`scripts/run_fuzz.sh` verifies is **liveness under corruption**: no hang,
error counters move, and book updates resume from the clean tail. Book state
after the burst is never compared against a reference, so "never corrupt book
state" is *not* established — see "Fuzz robustness" in `docs/results.md` for
the precise claim and its caveats.
