# hft-rtl — verification results

Golden-model vs RTL replay. The Python model (`model/`) and the SystemVerilog
pipeline (`rtl/`) consume a **byte-identical** input stream, and two things are
compared: the book snapshots field by field (a single differing price or share
count at any of the 16 tracked levels fails the run) and the OUCH order frames
byte for byte.

**Headline: 10,000,000 real Nasdaq ITCH messages, 260,053 book updates and 798
OUCH order frames, 0 mismatches.**

## How a run works

```
scripts/run_replay.sh --limit N        # or: make replay LIMIT=N
make replay-headline                   # the 10M run below
```

1. `model/dump_trace.py` reads N messages from the capture, runs them through the
   Python golden chain, and writes the golden trace (`golden_N.jsonl`, one line
   per book update), the golden order stream (`golden_orders_N.jsonl`, one line
   per accepted and encoded order) and — via `--wrap-out` — the exact MoldUDP64
   byte stream it consumed (`stream_N.mold`). All three come out of the same
   loop, so they cannot drift.
2. `tb/replay` (Verilator `--cc -O3`) feeds that same byte stream into
   `tick_to_trade_top` one byte per cycle, honouring `in_ready`, and writes
   `rtl_N.jsonl` on every `upd_valid` and `rtl_orders_N.jsonl` on every
   completed OUCH frame.
3. `model/compare_traces.py` compares the two book traces line for line, ignoring
   only the RTL-only `lat` field (cycles from message boundary to update — the
   sole hardware-only value in the trace; neither producer emits a timestamp).
   Message ordinal `n`, symbol index, and all 8 bid + 8 ask (price, shares) pairs
   must match exactly, and the two update sequences must line up 1:1.
4. `model/compare_orders.py` compares the two order streams: ordinal `n` and the
   51-byte OUCH frame, byte for byte, 1:1. `run_replay.sh` then asserts the DUT's
   strategy/risk counters against the golden model's own summary — see
   [Tick-to-trade](#tick-to-trade).

Non-vacuity: "0 mismatches" is only meaningful if something was actually
compared, so every line is shape-checked before comparison (the four contract
keys must be present, and both level lists must be exactly 8 deep — two equally
degenerate stubs cannot match each other), and `run_replay.sh` passes
`--min-updates` to the comparator: 1 by default, 100 for `--limit ≥ 1,000,000`.
A run that matched fewer updates than that exits 1 with a `VACUOUS:` message.
The 10k rung is the one legitimate exception (see below) and needs an explicit
`--min-updates 0`. The order comparator has the same gate under the name
`--min-orders`, defaulting to 20 at `--limit ≥ 1,000,000` and 0 below it: the
strategy is selective enough (hundreds of orders per 10M messages) that a small
rung can legitimately send nothing, while the large rungs measure 62 orders at
1M and 798 at 10M — so a floor of 20 sits comfortably under the real counts but
still fails a run whose order path collapsed to a handful of frames.

Ordinal alignment: `n` is the index over **all** messages read from the capture
(parsed or not, tracked or not). In the RTL that ordinal is derived from the DUT's
`msg_boundary` pulse, so `n` is compared as data — a one-message skew in either
direction is a hard failure, not a silently absorbed offset. The harness also
counts updates arriving before any message boundary (`orphan updates`, 0 in every
run) as an independent check that the two numbering schemes start together, and
the same check for order frames (`orphan orders`, likewise 0 in every run).

## Data provenance

| | |
|---|---|
| Capture | `12302019.NASDAQ_ITCH50.gz` (Nasdaq TotalView-ITCH 5.0 free public sample, trade date 2019-12-30) |
| Source | <https://emi.nasdaq.com/ITCH/Nasdaq%20ITCH/> (listing checked 2026-08-05) |
| Local path | `data/sample.NASDAQ_ITCH50.gz` (gitignored; fetched by `scripts/download_data.sh`) |
| Size | 3,524,013,057 bytes compressed |
| SHA-256 | `ef03df46a27e6bda4dead017f84c2e3979df7211f02c7868b51d53fceb99c689` |
| Wire format | BinaryFILE (`{2B BE length, message}` records), re-wrapped into MoldUDP64 by `model/moldwrap.py` at 16 messages/packet plus an end-of-session trailer |
| Messages replayed | the first 10,000,000 records of the file (352,162,965 bytes once MoldUDP64-wrapped) |
| Symbols tracked | AAPL, MSFT, SPY, QQQ, TSLA, NVDA, AMD, INTC — `book_idx` = position in this list, fixed at verilate time and passed identically to `dump_trace --symbols` |

Environment: Verilator 5.050, macOS (Darwin 25.5.0) on Apple Silicon, single
threaded. Verilated with `-O3`; the generated C++ model is compiled at `-O3` via
`-MAKEFLAGS OPT_FAST=-O3` (see the note under [Throughput](#throughput) — it
turns out not to matter for speed).

## Headline run — 10,000,000 messages

| Metric | Value |
|---|---|
| Messages replayed | 10,000,000 |
| Bytes fed to the DUT | 352,162,965 (1 byte/cycle) |
| Book updates emitted | 260,053 |
| **Mismatches vs golden model** | **0** |
| Orphan updates | 0 |
| Simulated cycles | 356,357,526 (incl. the 4,194,305-cycle post-reset table sweep) |
| Sim wall time | 298.12 s (4 min 58 s) |
| Throughput | 33,543 msgs/sec, 1,195,336 cycles/sec |
| End-to-end wall time (dump + build + run + compare) | 5 min 33 s |

Of the 10M messages, 8,292,456 were dropped by `book_router` (`drop_count` —
untracked-symbol ADDs *plus* follow-up messages whose order id was never
inserted; see the counter table below) and 1,344,052 were message types the book
does not model (counted as unknown), leaving ~363k messages that actually touched
a book.

## Run ladder

Each rung is a complete dump → replay → compare cycle. The 10k rung exercises the
plumbing only: the first 10k records of the trading day are pre-open
administrative messages (9,999 unknown, 1 system event), so no book update exists
to compare — which is exactly the vacuous case the `--min-updates` gate rejects,
so that rung must be run as
`scripts/run_replay.sh --limit 10000 --min-updates 0`.

| Messages | Updates | Mismatches | Cycles | Sim wall | msgs/sec |
|---|---|---|---|---|---|
| 10,000 | 0 | 0 | 4,599,022 | 3.0 s | 3,319 |
| 300,000 | 1,022 | 0 | 13,123,297 | 8.7 s | 34,420 |
| 1,000,000 | 13,526 | 0 | 34,455,373 | 28.7 s | 34,821 |
| 10,000,000 | 260,053 | **0** | 356,357,526 | 298.1 s | 33,543 |

## Throughput

Sim throughput is ~33-37k msgs/sec (~1.2M cycles/sec) and is dominated by the 1
byte/cycle input rate: 10M messages is 352M bytes, hence 352M+ cycles, whatever
the message mix. It dips over the run (37.5k msgs/sec through the first 5M, 33.2k
after) because the later part of the session carries more tracked-symbol traffic,
so more cycles do book work rather than being filtered away.

Compiling the generated model at `-O3` instead of Verilator's `-Os` default made
no useful difference — measured over the same 1M-message rung, `-Os` ran the first
1M messages in 29.4 s and `-O3` in 28.7-28.8 s, inside run-to-run noise. The
`-O3` build is kept because it is what the recorded numbers above were
produced with, but it is not a speed lever: the model is
memory-bound on the order table, not compute-bound. (An earlier 22.8 s figure for
a standalone 1M run reflected a warm page cache, not the compiler flag.)

## Latency

`lat` = cycles from the DUT's `msg_boundary` pulse (last byte of a framed ITCH
message) to the `upd_valid` carrying the resulting book snapshot. It measures the
decode → order-table lookup → price-book update path; it excludes the 1 byte/cycle
message shift-in, which is a datapath-width property, not a pipeline property.

| Run | min | median | p99 | max |
|---|---|---|---|---|
| 300,000 msgs | 4 | 4 | 4 | 5 |
| 1,000,000 msgs | 4 | 4 | 5 | 5 |
| 10,000,000 msgs | 4 | 4 | 5 | 7 |

Deterministic and tightly bounded: 4 cycles in the common case, never worse than 7
over 260k updates. The tail comes from REPLACE (two order-table operations) and
from linear-probe depth on a table lookup.

This is the book half of the path. For boundary → first OUCH byte, see
[Tick-to-trade latency](#tick-to-trade-latency).

## Counters (10M run)

| Counter | Value | Meaning |
|---|---|---|
| `gap_count` | 0 | MoldUDP64 sequence gaps — none, the stream is locally generated and contiguous |
| `malformed_count` | 0 | zero-length message records (`len == 0` in a MoldUDP64 block) — the only framing violation `mold_framer` counts |
| `unknown_count` | 1,344,052 | ITCH types the book does not model, skipped by length |
| `drop_count` | 8,292,456 | untracked-symbol ADDs **+** order-ID lookup misses (see below) |
| `table_full_count` | **0** | ADDs rejected because all 8 probe slots were taken |
| `reduce_miss_count` | 17,882 | REDUCE at a price not in the top 8 — dropped by contract, matched by the model |
| `evict_count` | 102,998 | price levels pushed out of the top 8 and permanently discarded — matched by the model |
| `end_of_session` | 1 | MoldUDP64 end-of-session trailer seen |

`drop_count` is **not** a symbol-filter counter, despite being dominated by
untracked symbols. `book_router` increments it in two distinct places: an ADD
whose symbol is not one of the tracked 8 (dropped, and deliberately never
inserted into the order table), and an EXEC/CANCEL/DELETE/REPLACE whose order id
is not in the table. The second case is mostly *caused* by the first — every
child message of an untracked ADD necessarily misses — but the two are separate
events and the split is not 1:1. Measured on the 300k rung: 24,829
untracked-symbol ADDs against 32,381 order-table lookup misses, i.e. the miss
count is the larger of the two. Both are normal, expected behaviour on a
symbol-filtered feed, not error conditions; the Python model makes the identical
free/keep decisions, which is why the traces still match exactly.

`reduce_miss` and `evict` are non-zero *by design*: the top-8 truncation contract
says a level pushed out of the window is gone forever and a REDUCE that lands
outside the window is dropped and counted. Both counts represent real behaviour
the Python model reproduces exactly — which is why 260,053 snapshots still match
bit for bit.

`table_full_count == 0` is a result, not a given. The resting-order table is
`TABLE_ADDR_W = 22` (4,194,304 slots, `MAX_PROBES = 8`). At 20 bits this same run
overflowed a probe window once, dropping one ADD and then every follow-up message
for that order id — a permanent divergence. The failure mode is clustering, not
occupancy: near-sequential ITCH order ids XOR-fold to near-sequential slots and
linear probing piles them into contiguous runs, so extra address bits (which
spread the runs out) are the effective lever, not a bigger probe window. See the
comment in `rtl/book_pkg.sv`.

## Tick-to-trade

The replay DUT is `tick_to_trade_top`: pure wiring around
`itch_book_top` → `strategy_imbalance` → `risk_gate` → `ouch_encoder`. Bytes go
in, OUCH 4.2 Enter Order frames come out. The book stage's outputs are still
exposed unchanged, which is why the book comparison above is unaffected — the
10M tick-to-trade run reproduces the phase-1 book numbers exactly (260,053
updates, 356,357,526 cycles, 0 mismatches).

The chain, one stage per cycle after the book update:

1. **`strategy_imbalance`** — per symbol, weighted masses `B = Σ bid_shares[i]>>i`
   and `A = Σ ask_shares[i]>>i` over the 8 levels; state is LONG iff
   `B > A<<THRESH_LOG2`, SHORT iff `A > B<<THRESH_LOG2`, else NEUTRAL. An intent
   fires only on the *edge* into LONG (buy at `ask_price[0]`) or into SHORT (sell
   at `bid_price[0]`); staying never fires, and after firing that symbol is muted
   for `COOLDOWN_UPDATES` of its own updates while the state machine keeps
   running.
2. **`risk_gate`** — four checks in a fixed order, exactly one reject counter per
   rejection (the first check that fails): sanity (`bid0 != 0 && ask0 != 0 &&
   bid0 < ask0`), collar (`|price − mid| > mid>>COLLAR_SHIFT`), rate (fewer than
   `MIN_ORDER_SPACING` book updates since the last *accepted* order), position
   (post-trade `|pos[symbol]|` would exceed `MAX_POSITION`).
3. **`ouch_encoder`** — serializes an accepted intent into the 51-byte wire frame
   (2-byte big-endian length + 49-byte Enter Order body) one byte per cycle,
   through a depth-4 FIFO that absorbs bursts.

**Rate-counter coincidence semantics.** The risk gate's rate check counts book
updates, and in the RTL a book update (`upd_valid`) can land on the very cycle
an intent is being judged — a case the sequential golden model, which handles
one event at a time, has no direct analogue for. The rule is that the RTL
matches the model *by construction*, not by coincidence of tuning: the model
counts update *k* and then judges the intent update *k* produced, and the RTL
gets exactly that from the strategy's 1-cycle intent register — update *k* was
already counted on the previous edge by the time its intent arrives. A
`upd_valid` coincident with the intent is therefore a **later** book event
(*k+1*), one the model has not reached yet, so it is *not* folded into the
comparison: the intent is judged against the pre-coincident count, and after an
accept (which clears the count) that coincident update survives the reset as a
count of 1, exactly as the model's next iteration would count it. Both halves
matter and they err in opposite directions — an earlier "increment the count
before comparing" formulation was simultaneously one too high at the compare
and one too low after an accept. It happened to produce identical results on
this capture because no coincident intent ever sat on the rate boundary, which
is precisely why the equivalence is now argued from the wiring rather than
inferred from a matching run. `tb/unit/tb_risk_gate.sv` pins both halves with
directed cases (a coincident update on an accepted intent must leave the count
at 1; a coincident update on an intent whose pre-coincident count is
`MIN_ORDER_SPACING − 1` must still rate-reject).

### Parameters

Tuned on this capture; every default held, so the headline run passes no
overrides. They are fed from a single place in `scripts/run_replay.sh` to both
sides — as flags to `model/dump_trace.py` and as `verilator -G` overrides to the
harness build — so the two can never be tuned apart.

| Parameter | Value | Effect |
|---|---|---|
| `THRESH_LOG2` | 2 | one side's weighted mass must exceed 4× the other |
| `COOLDOWN_UPDATES` | 16 | per-symbol mute after firing, in that symbol's updates |
| `ORDER_SHARES` | 100 | shares per order |
| `MAX_POSITION` | 1000 | max absolute signed position per symbol (10 orders' worth) |
| `MIN_ORDER_SPACING` | 10 | book updates (any symbol) between accepted orders |
| `COLLAR_SHIFT` | 3 | order price must be within mid/8 of mid |

### Order stream — 10,000,000 messages

| Metric | Value |
|---|---|
| Strategy intents | 1,827 |
| Risk-gate accepts | 798 |
| OUCH frames on the wire | 798 (40,698 bytes) |
| **Order mismatches vs golden model** | **0** |
| Orphan orders / truncated frames | 0 / 0 |
| `fifo_drop_count` | 0 |
| Sim wall time (whole pipeline) | 236.97 s, 42,200 msgs/sec |

The two 10M-message wall-clock figures in this document (298.12 s in the
headline run above, 236.97 s here) are separate measurements taken at
different times, not a regression in either direction — the cycle counts they
correspond to (356,357,526) are identical, so the wall-time gap is machine
load variance between runs, not a change in what got simulated.

Reject breakdown of the 1,029 intents that did not become orders:

| Check | Rejects | Reading |
|---|---|---|
| sanity | 0 | the book never presented a crossed or one-sided top of book to a firing intent |
| collar | 0 | the strategy prices at top of book, i.e. half a spread from mid; on these 8 liquid symbols no firing intent ever saw a spread wider than mid/4, so the collar never bound |
| rate | 40 | intents arriving within 10 book updates of the previous accepted order |
| position | 989 | the dominant limiter — the position cap, not the market, is what stops this strategy |

The counters are compared, not just the wire: `run_replay.sh` asserts each of
`intent_count`, `accept_count`, the four reject counters and `order_count`
against the golden model's own summary line. That catches a divergence the order
stream alone would miss — two implementations that reject *different* intents for
*different* reasons can still emit the same frames if the difference happens not
to change which orders survive.

`raw` is compared byte for byte, and the frame contains the order token
(`HFTRTL` + 8 hex digits of a free-running counter). So the comparison is
stricter than "same orders": the RTL's counter and the model's must stay in
lockstep, which they can only do if both accepted exactly the same intents in
exactly the same sequence.

`fifo_drop_count == 0` matters because the encoder's input FIFO is only 4 deep
and a drop there would silently remove an accepted order from the wire. At
`MIN_ORDER_SPACING = 10` the gate cannot accept two orders closer than 10 book
updates apart, and a frame takes 51 cycles, so the FIFO is never under pressure
on this workload — the depth-4 slack is a consequence of that parameter, not a
bound that binds, and at `--min-spacing 1` drops become reachable. Either way
the harness fails the run if `fifo_drop_count` is ever nonzero, rather than
letting the order stream quietly shorten.

### Tick-to-trade latency

Cycles from the DUT's `msg_boundary` pulse (last byte of the framed ITCH message
that caused the order) to `frame_start` (first byte of the OUCH frame on the
wire). Same convention as the book-update `lat` above: it excludes the 1
byte/cycle shift-in on the way in and the 51-cycle shift-out on the way out, both
of which are datapath-width properties rather than pipeline properties.

| Run | Orders | min | median | p99 | max |
|---|---|---|---|---|---|
| 300,000 msgs | 20 | 8 | 8 | 8 | 8 |
| 1,000,000 msgs | 62 | 8 | 8 | 8 | 8 |
| 10,000,000 msgs | 798 | 8 | 8 | 9 | 9 |

8 cycles is the structural floor and the overwhelmingly common case: 4 cycles of
book update (decode → order table → price book), 1 for the strategy, 1 for the
risk gate, and 2 in the encoder (the accepted intent is pushed into the FIFO,
then popped onto the wire as byte 0, which is the cycle `frame_start` pulses). The
trade stages add a fixed 4, so a 9-cycle order must come from a book update that
itself took 5 — the same probe-depth/REPLACE tail the book-update latency table
shows. Nothing in the trade stages is data-dependent in time; the whole spread
in this table is inherited from the book.

### Scope caveats

**Position is sent-exposure, not inventory.** There is no execution feedback
path: `risk_gate` adds `±ORDER_SHARES` to a symbol's position when it *accepts*
an order, and nothing ever removes it. Orders that would be rejected, cancelled,
or partially filled by a real venue are all counted as fully filled here. The
989 position rejects above are therefore rejects against orders *sent*, not
against shares *owned*, and the position cap is reached faster than it would be
against a venue that filled only some of them.

**OUCH only, no session layer.** The encoder emits bare OUCH 4.2 Enter Order
frames with their 2-byte length prefix. There is no SoupBinTCP session — no
login, no sequenced-data wrapper, no heartbeats, no server-side Accepted/Rejected
or Executed messages coming back, and hence no order-state tracking, no cancel
or replace path, and no reconciliation of what the venue thinks against what the
gate thinks. The verified claim is exactly "the correct Enter Order bytes, in the
correct order, N cycles after the tick that caused them" — everything a real
order entry gateway does after that is out of scope.

## Fuzz robustness

`model/fuzz_stream.py` builds a seeded, corrupted MoldUDP64 byte stream: a
"dirty" section of otherwise-valid ITCH traffic with byte flips inside message
bodies and bogus declared lengths (≤ 50 bytes, resized so each message's
length prefix always matches its own actual bytes — see the module docstring
for why that matters), truncated to a random whole number of surviving
packets, followed by a **clean tail of 1,000 valid messages under a fresh
MoldUDP64 session**. `tb/replay/replay_main.cpp --fuzz --tail-start <N>` runs
that stream against `tick_to_trade_top` (the book stage is what the corruption
reaches; the trade stages downstream of it are along for the ride, and
`orphan orders` is checked to be 0 in fuzz mode too).

**What this actually proves: liveness under corruption, and nothing stronger.**
The three pass criteria are exactly three liveness properties —

1. **No hang.** Some observable output — a status counter, `msg_boundary`, or
   `upd_valid` — must change within 10,000 cycles at every point while bytes
   remain. The pipeline never wedges.
2. **Counters move.** The error counters end up nonzero, i.e. the corruption
   was noticed and accounted rather than silently swallowed.
3. **Updates resume.** At least one book update is emitted from bytes at or
   after the tail boundary, so the pipeline is still decoding, routing and
   updating books after the disruption — not merely still clocking.

None of these is a *state-level* robustness claim. Book contents after the
fuzz burst are never compared against anything: resync semantics (recovering
the *same* state a clean run would reach) are out of scope, and a run in which
every post-tail book were wrong in value but present in form would still pass.
The claim is "never stops consuming, always accounts, comes back to life" — not
"state survives corruption".

Criterion 2 also deserves a caveat: `gap_count ≥ 1` is guaranteed by the test's
own construction, not by the corruption. The clean tail is spliced in under a
*fresh* MoldUDP64 session, so a sequence discontinuity exists at the boundary in
every seed by design. The genuinely corruption-driven signal is in the other
counters (`malformed_count` / `unknown_count`), which is why the table below
reports `error_counters_sum` rather than `gap_count` alone.

| Seed | Bytes fed | `hang_detected` | `error_counters_sum` | `updates_before_tail` | `updates_after_tail` | Result |
|---|---|---|---|---|---|---|
| 1 | 40,116 | no | 565 | 141 | 699 | **PASS** |
| 2 | 43,185 | no | 651 | 220 | 623 | **PASS** |
| 3 | 42,105 | no | 596 | 213 | 647 | **PASS** |

`gap_count` is 1 in every seed — the single discontinuity where the tail's fresh
session/sequence begins. As noted above this is *built in* by the splice, so it
is evidence that `mold_framer` absorbs a gap and keeps consuming rather than
treating it as fatal, and not evidence that the fuzzer found anything.
`updates_after_tail > 0` in every
run confirms the tail is not just passed through as bytes but actually
decoded, routed, and reaches a price book again.

An earlier review of `itch_decoder` flagged that its write-index clamp
for oversized messages (`widx` forced to 0 once `byte_cnt >= 40`) could in
principle let an oversized message corrupt `msg_buf[0]`, and this fuzz's
bogus lengths (up to 50 bytes) are exactly the kind of input that would
exercise it. It does not: both the buffer write and the combinational `view`
update are already gated by the identical `byte_cnt < LEN_MAX` condition the
clamp's false branch corresponds to, so that branch never fires a write in
the first place — it is dead code, not a live bug. Across all 3 fuzz seeds
(including runs against the pre-fix construction of this test, which produced
messages up to 50 bytes taking every code path in the decoder's final-byte
logic) no spurious `out_valid` on garbage was observed, and `malformed_count`
/ `unknown_count` behaved exactly as the "count and drop" contract predicts.
Left as-is.

## Unit tests

- `python3 -m pytest -q` — 95 passed (golden model, ITCH parsing, BinaryFILE
  reader, MoldUDP64 wrapper, `--wrap-out` byte-identity, the strategy, risk gate
  and OUCH encoder, `dump_trace --orders-out`, both comparators including their
  shape checks and non-vacuity gates, fuzz-stream corruption/tail-integrity).
- `make -C tb/unit TOP=<tb> run` for `tb_mold_framer`, `tb_itch_decoder`,
  `tb_price_book`, `tb_book_router`, `tb_itch_book_top`,
  `tb_strategy_imbalance`, `tb_risk_gate`, `tb_ouch_encoder`,
  `tb_tick_to_trade_top` — all pass.

Functional coverage is tallied by hand in the five random-stimulus TBs
(Verilator does not implement covergroups) and gated — an empty bin is a
`$fatal`, not a warning:

| TB | Bins | What must be hit |
|---|---|---|
| `tb_price_book` | 14 | {ADD-new-level, ADD-aggregate, ADD-evict-9th, ADD-reject-full, REDUCE-partial, REDUCE-remove, REDUCE-miss} × {bid, ask} |
| `tb_book_router` | 10 | {ADD, EXEC, CANCEL, DELETE, REPLACE} × {hit, miss} (for ADD: tracked / untracked) |
| `tb_strategy_imbalance` | 6 | fire-buy, fire-sell, suppress-cooldown, suppress-same-state, neutral-rearm, empty-side-suppress |
| `tb_risk_gate` | 5 | accept plus each of the four reject paths (sanity, collar, rate, position) |
| `tb_ouch_encoder` | 4 | side-B, side-S, queued-while-busy, immediate |

## Reproducing

```
scripts/download_data.sh              # ~3.5 GB
make test-model
make replay LIMIT=1000000             # ~25 s sim
make replay-headline                  # 10M messages, ~4 min sim

# Fuzz robustness (3 seeds), see "Fuzz robustness" above:
BIN="$(make -C tb/replay -s print-bin)"
for seed in 1 2 3; do
  python3 -m model.fuzz_stream --seed $seed --out build/fuzz_$seed.mold \
      --meta build/fuzz_$seed.json
  ts=$(python3 -c "import json; print(json.load(open('build/fuzz_$seed.json'))['tail_start'])")
  "$BIN" --in build/fuzz_$seed.mold --out build/fuzz_rtl_$seed.jsonl \
      --fuzz --tail-start "$ts"
done
```
