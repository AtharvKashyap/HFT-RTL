# Hardware ITCH Order Book

A synthesizable SystemVerilog pipeline that ingests a real Nasdaq
TotalView-ITCH 5.0 market-data feed, byte by byte, and maintains live top-8
price-level order books for up to 16 symbols — the same job an FPGA sits in
front of an exchange feed to do in a real trading system, before a strategy
ever sees a price.

Market-data parsing is the first stage of any tick-to-trade pipeline, and it's
the stage where nanoseconds compound: every symbol, every book operation,
every cycle of latency here happens once per message, all day. This project
builds that stage for real — the actual wire protocol (ITCH 5.0 over
MoldUDP64), a real full-day capture from Nasdaq (not synthetic test vectors),
and a verification story built the way hardware teams actually verify
datapaths: a golden software model compared bit-for-bit against RTL simulation
over millions of real messages, directed and constrained-random unit tests per
module, and a fuzz pass that proves the design never hangs or corrupts state
on malformed input. Every number below is from an actual run, not a target.

## Architecture

```
                 ┌────────────────────────────────────────────────────────┐
                 │                    itch_book_top                       │
 raw byte  ──▶ ┌──────────┐   ┌──────────┐   ┌───────────┐   ┌──────────┐ │
 stream        │ MoldUDP64│──▶│  ITCH    │──▶│ Order-ID  │──▶│ Price-   │─┼─▶ book updates /
 (1 B/cycle)   │  framer  │   │ decoder  │   │ table +   │   │ level    │ │   best bid-ask
               └──────────┘   └──────────┘   │ symbol    │   │ books ×N │ │   (streaming)
                                             │ filter    │   └──────────┘ │
                                             └───────────┘                │
                 └────────────────────────────────────────────────────────┘
```

- **`mold_framer`** — strips MoldUDP64 packet framing (session, sequence,
  message count, per-message length prefix), tracks sequence continuity, and
  hands the ITCH decoder one message at a time with a byte-accurate boundary
  pulse.
- **`itch_decoder`** — decodes Add/Add-w-MPID, Executed, Executed-w-Price,
  Cancel, Delete, Replace, and System-Event messages into a common struct;
  unknown/malformed types are counted and dropped, never fatal.
- **`book_router`** (order-ID table + symbol filter) — a hash table with
  bounded linear probing maps ITCH order IDs to {book index, side, price,
  shares}; non-tracked symbols are filtered before they ever enter it.
- **`price_book`** ×16 (one per tracked symbol) — sorted top-8 price levels
  per side, insert/reduce/evict in a fixed small cycle count via parallel
  compare, not iterative search. In-RTL assertions check sort order, no
  duplicate prices, and no share underflow.
- **`itch_book_top`** — wires the above together behind one ready/valid byte
  stream in, one book-update stream out, plus a status/counter port.

Every abnormal condition — a sequence gap, an unknown message type, a full
probe window, an untracked symbol, a malformed frame — is **counted and
dropped, never fatal**. The pipeline always keeps consuming.

## Quickstart

Dependencies: [Verilator](https://verilator.org) ≥ 5.0 (`brew install
verilator` on macOS), Python 3.

```bash
# 1. Python golden model + its own test suite (parser, book, MoldUDP64 wrapper)
python3 -m pytest -q                        # or: make test-model

# 2. Per-module RTL testbenches (directed + constrained-random, Verilator)
make -C tb/unit TOP=tb_mold_framer   run
make -C tb/unit TOP=tb_itch_decoder  run
make -C tb/unit TOP=tb_price_book    run
make -C tb/unit TOP=tb_book_router   run
make -C tb/unit TOP=tb_itch_book_top run

# 3. Golden-model-vs-RTL replay over real Nasdaq ITCH data
scripts/download_data.sh                    # ~3.5 GB, one-time
make replay LIMIT=1000000                   # ~30 s sim, see docs/results.md
make replay-headline                        # the 10M-message headline run, ~5 min

# 4. Fuzz robustness: corrupted stream + clean-tail recovery, 3 seeds
make fuzz
```

## Headline results

10,000,000 real Nasdaq ITCH messages replayed through both the Python golden
model and the RTL in lockstep, byte-identical input, field-by-field snapshot
comparison after every book update.

| Metric | Value |
|---|---|
| Messages replayed | 10,000,000 |
| Book updates emitted | 260,053 |
| **Mismatches vs golden model** | **0** |
| Tracked-symbol book operations | ~363,000 (8.29M dropped by symbol filter, 1.34M unmodeled types) |
| Latency (msg boundary → book update) | min 4, median 4, p99 5, max 7 cycles |
| Throughput | ~33,500 msgs/sec sim (1 byte/cycle datapath, so cycle-bound, not logic-bound) |
| Order table sizing | `TABLE_ADDR_W = 22` (4.19M slots) — the smallest size, found empirically, with zero probe-window overflows on this capture's peak of ~94,800 live orders (see `rtl/book_pkg.sv`) |

Full breakdown, run ladder (10k/300k/1M/10M), and counter definitions in
[`docs/results.md`](docs/results.md).

## Verification approach

Three layers, each catching a different class of bug:

1. **Unit testbenches** (`tb/unit/`, one per module) — directed edge cases
   (gaps, heartbeats, split messages, every ITCH type, collision handling,
   table full, level eviction, side crossing) plus constrained-random
   stimulus with in-RTL immediate assertions compiled into the design.
2. **Golden-model replay** (`tb/replay/`, `model/`) — a from-scratch Python
   reference implementation of the same ITCH parsing and book semantics
   (including identical top-8 truncation rules), replayed against the RTL
   over a real 10M-message Nasdaq capture with a field-by-field comparator.
   This is the headline result above.
3. **Fuzz robustness** (`model/fuzz_stream.py`, `tb/replay/replay_main.cpp
   --fuzz`) — a seeded, corrupted MoldUDP64 stream (byte flips, bogus
   length fields, truncated packets) followed by a clean 1,000-message tail.
   Pass criteria: no hang (an internal watchdog requires observable progress
   within 10,000 cycles at all times), error counters end up nonzero, and the
   clean tail produces book updates again. Ran across 3 seeds, all pass — see
   [`docs/results.md`](docs/results.md#fuzz-robustness) for the numbers and
   for why book-state equality with a clean run is explicitly *not* checked.

## Phase-2 roadmap

Out of scope for this milestone, but the natural next steps:

- **UVM-on-VCS** — same RTL, a UVM testbench (driver/monitor/scoreboard)
  reusing the Python golden trace as the reference model, run on a
  university/lab VCS license.
- **Vivado synthesis + timing-derived latency** — synthesize for a real FPGA
  target, get an achieved Fmax, and convert the measured cycle latencies
  above into actual nanoseconds.
- **Tick-to-trade extension** — add a strategy block and order generator
  downstream of the book updates to turn this into a full round-trip
  tick-to-trade engine.
- **Wide datapath** — v1 is 1 byte/cycle by design (simplicity for
  verification); widening the input datapath (e.g. 8 or 16 bytes/cycle) is
  the natural throughput lever once the pipeline logic is proven correct.
- **Order-table hash mixing + board-fit compression** — the current table
  trades memory for correctness (2^22 slots, full 64-bit order IDs, sized
  empirically against this capture's clustering — see `rtl/book_pkg.sv`); a
  board port would mix the hash to break up near-sequential ITCH order-ID
  clustering and store a compressed tag instead of the full ID, so the table
  fits in on-chip memory instead of scaling with address bits.
