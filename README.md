# hft-rtl

A Nasdaq ITCH limit order book, trading strategy, risk gate, and OUCH order
encoder in synthesizable SystemVerilog. Consumes a TotalView-ITCH 5.0 feed one
byte per cycle, maintains live top-8 price-level books for 16 symbols, and
optionally turns book updates into OUCH 4.2 Enter Order frames:
MoldUDP64 framing → ITCH decode → order-ID hash table → per-symbol price books
→ imbalance strategy → risk gate → OUCH encoder.
10,000,000 messages from a real Nasdaq capture were replayed through the RTL and
a Python golden model in lockstep: 260,053 book updates and 798 OUCH order
frames, 0 mismatches on either. Latency from message boundary to book update is
4 cycles median, 7 worst case; boundary to first OUCH byte is 8 cycles median, 9
worst case. Verified in Verilator simulation only — no synthesis results yet.

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
                                              │
                                              ▼
                 ┌────────────────────────────────────────────────────────┐
                 │                  tick_to_trade_top                     │
                 │  ┌──────────────┐   ┌───────────┐   ┌───────────────┐  │
    book updates │  │  strategy_   │──▶│ risk_gate │──▶│ ouch_encoder  │──┼─▶ OUCH 4.2
    (from above) ─┼─▶│  imbalance   │   │           │   │ (depth-4 FIFO)│  │  Enter Order
                 │  └──────────────┘   └───────────┘   └───────────────┘  │  bytes
                 └────────────────────────────────────────────────────────┘
```

- **`mold_framer`** — strips MoldUDP64 framing (session, sequence, message
  count, per-message length prefix), tracks sequence continuity, emits one
  message at a time with a byte-accurate boundary pulse.
- **`itch_decoder`** — Add, Add-w-MPID, Executed, Executed-w-Price, Cancel,
  Delete, Replace, System-Event into a common struct; unknown types are counted
  and skipped by length.
- **`book_router`** — hash table with bounded linear probing (`MAX_PROBES = 8`)
  mapping order IDs to {book index, side, price, shares}; untracked symbols are
  filtered before insertion.
- **`price_book`** ×16 — sorted top-8 levels per side, insert/reduce/evict in a
  fixed cycle count via parallel compare rather than iterative search. In-RTL
  assertions check sort order, price uniqueness, and share underflow.
- **`strategy_imbalance`** — per-symbol weighted bid/ask imbalance over the top
  8 levels; fires a buy or sell intent only on the edge into an imbalanced
  state, then mutes that symbol for a cooldown window of its own updates.
- **`risk_gate`** — four fixed-order checks per intent (sanity, price collar,
  order-rate spacing, position cap), exactly one reject counter per check.
- **`ouch_encoder`** — serializes an accepted intent into a 51-byte OUCH 4.2
  Enter Order frame, one byte per cycle, through a depth-4 absorbing FIFO.

Every abnormal condition — sequence gap, unknown message type, full probe
window, untracked symbol, malformed frame — is counted and dropped, never fatal.

## Results

Byte-identical input to both implementations, field-by-field snapshot
comparison after every update.

| Metric | Value |
|---|---|
| Messages replayed | 10,000,000 |
| Book updates emitted | 260,053 |
| Mismatches vs golden model | **0** |
| Latency, msg boundary → update | 4 / 4 / 5 / 7 cycles (min / median / p99 / max) |
| Sim throughput | 33,543 msgs/sec (1 byte/cycle, so cycle-bound) |
| Order table | `TABLE_ADDR_W = 22` (4.19M slots), 0 probe-window overflows |
| Peak live orders in capture | ~94,800 |
| OUCH order frames emitted | 798, byte-identical to golden, 0 mismatches |
| Latency, msg boundary → first OUCH byte | 8 / 8 / 9 / 9 cycles (min / median / p99 / max) |

`TABLE_ADDR_W = 22` was found empirically, not by occupancy math: at 20 bits the
same run overflowed a probe window and diverged permanently. The failure mode is
clustering — near-sequential ITCH order IDs XOR-fold to near-sequential slots —
so address bits, not probe depth, are the lever.

Run ladder (10k/300k/1M/10M), counter definitions, and fuzz numbers:
[`docs/results.md`](docs/results.md).

## Quickstart

Requires Verilator ≥ 5.0 (`brew install verilator`), Python 3, and ~4 GB free
disk for the capture.

```bash
scripts/download_data.sh                  # 3.5 GB Nasdaq sample, one-time
make test-model                           # Python golden model suite, 94 tests
for tb in tb_mold_framer tb_itch_decoder tb_price_book tb_book_router \
          tb_itch_book_top tb_strategy_imbalance tb_risk_gate \
          tb_ouch_encoder tb_tick_to_trade_top; do
  make -C tb/unit TOP=$tb run || break    # per-module RTL testbenches
done
make replay LIMIT=300000                  # golden-vs-RTL, ~10 s sim
make replay-headline                      # the full 10M run, ~6 min end to end
make fuzz                                 # corrupted-stream robustness, 3 seeds
```

`make replay LIMIT=300000` now verifies orders as well as book updates — it
runs the strategy/risk/OUCH stages against `tick_to_trade_top`, prints
`MATCH: 1022 updates identical` and the order-stream and counter comparisons on
success, and exits nonzero on any mismatch in either.

## How it is verified

1. **Unit testbenches** (`tb/unit/`, one per module) — directed edge cases plus
   constrained-random stimulus, with in-RTL assertions and hand-tallied
   functional coverage bins that `$fatal` if left empty.
2. **Golden-model replay** (`model/`, `tb/replay/`) — an independent Python
   implementation of the same parsing, book, strategy, risk, and OUCH-encoding
   semantics, compared line for line against the RTL trace over the real
   capture — book snapshots, OUCH order frames, and strategy/risk counters
   all — with a non-vacuity gate so "0 mismatches" cannot mean "nothing
   compared".
3. **Fuzz** (`model/fuzz_stream.py`) — seeded corrupted MoldUDP64 stream plus a
   clean 1,000-message tail; checks no hang (10,000-cycle watchdog), nonzero
   error counters, and that updates resume after the corruption.

## Limitations

- Simulation only. No synthesis, no place-and-route, no Fmax — cycle counts here
  have not been converted to nanoseconds.
- Top-8 truncation is an approximation of a full book. A level evicted from the
  window is gone permanently, and a REDUCE landing outside it is dropped and
  counted (`reduce_miss_count`). The Python model reproduces this exactly, which
  is why the traces match; it is still not a full-depth book.
- `drop_count` mixes two events: untracked-symbol ADDs and order-ID lookup
  misses. Follow-ups to untracked ADDs necessarily miss, so the two are related
  but not 1:1 (300k rung: 24,829 vs 32,381). Normal behaviour on a filtered
  feed, not errors.
- The 2^22-slot order table with full 64-bit IDs will not fit in on-chip BRAM as
  written. A board port needs hash mixing and a compressed tag.
- The imbalance strategy is a demonstration signal, tuned only to produce a
  non-trivial, comparable order stream on this one capture. No profitability
  claim is made or checked; nothing here says the strategy makes money.
- `risk_gate`'s position tracking is sent-exposure, not inventory: it debits
  the position cap when an order is *accepted*, and nothing ever credits it
  back. There is no fill, cancel, or partial-fill feedback, so every sent
  order is treated as fully and permanently filled.
- The encoder emits bare OUCH 4.2 Enter Order frames only. There is no
  SoupBinTCP session layer — no login, no heartbeats, no sequenced-data
  wrapper, and no Accepted/Rejected/Executed messages coming back from a
  venue.

## Roadmap

- Vivado synthesis for a real target: achieved Fmax, cycle latencies converted
  to nanoseconds, resource utilization.
- UVM testbench (driver/monitor/scoreboard) reusing the Python golden trace as
  the reference model.
- Wider input datapath (8 or 16 bytes/cycle) now that the 1 byte/cycle pipeline
  is proven correct.
- Order-table hash mixing and tag compression to fit on-chip memory.
