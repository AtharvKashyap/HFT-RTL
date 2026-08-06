# rtlbook — verification results

Golden-model vs RTL replay. The Python model (`model/`) and the SystemVerilog
pipeline (`rtl/`) consume a **byte-identical** input stream and their book
snapshots are compared field by field; a single differing price or share count at
any of the 16 tracked levels fails the run.

**Headline: 10,000,000 real Nasdaq ITCH messages, 260,053 book updates, 0
mismatches.**

## How a run works

```
scripts/run_replay.sh --limit N        # or: make replay LIMIT=N
make replay-headline                   # the 10M run below
```

1. `model/dump_trace.py` reads N messages from the capture, runs them through the
   Python golden model, and writes both the golden trace (`golden_N.jsonl`, one
   line per book update) and — via `--wrap-out` — the exact MoldUDP64 byte stream
   it consumed (`stream_N.mold`). Both come out of the same loop, so they cannot
   drift.
2. `tb/replay` (Verilator `--cc -O3`) feeds that same byte stream into
   `itch_book_top` one byte per cycle, honouring `in_ready`, and writes
   `rtl_N.jsonl` on every `upd_valid`.
3. `model/compare_traces.py` compares the two traces line for line, ignoring only
   the RTL-only `lat` field (cycles from message boundary to update — the sole
   hardware-only value in the trace; neither producer emits a timestamp).
   Message ordinal `n`, symbol index, and all 8 bid + 8 ask (price, shares) pairs
   must match exactly, and the two update sequences must line up 1:1.

Non-vacuity: "0 mismatches" is only meaningful if something was actually
compared, so every line is shape-checked before comparison (the four contract
keys must be present, and both level lists must be exactly 8 deep — two equally
degenerate stubs cannot match each other), and `run_replay.sh` passes
`--min-updates` to the comparator: 1 by default, 100 for `--limit ≥ 1,000,000`.
A run that matched fewer updates than that exits 1 with a `VACUOUS:` message.
The 10k rung is the one legitimate exception (see below) and needs an explicit
`--min-updates 0`.

Ordinal alignment: `n` is the index over **all** messages read from the capture
(parsed or not, tracked or not). In the RTL that ordinal is derived from the DUT's
`msg_boundary` pulse, so `n` is compared as data — a one-message skew in either
direction is a hard failure, not a silently absorbed offset. The harness also
counts updates arriving before any message boundary (`orphan updates`, 0 in every
run) as an independent check that the two numbering schemes start together.

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

## Fuzz robustness

`model/fuzz_stream.py` builds a seeded, corrupted MoldUDP64 byte stream: a
"dirty" section of otherwise-valid ITCH traffic with byte flips inside message
bodies and bogus declared lengths (≤ 50 bytes, resized so each message's
length prefix always matches its own actual bytes — see the module docstring
for why that matters), truncated to a random whole number of surviving
packets, followed by a **clean tail of 1,000 valid messages under a fresh
MoldUDP64 session**. `tb/replay/replay_main.cpp --fuzz --tail-start <N>` runs
that stream against `itch_book_top`.

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

- `python3 -m pytest -q` — 58 passed (golden model, ITCH parsing, BinaryFILE
  reader, MoldUDP64 wrapper, `--wrap-out` byte-identity, trace comparator
  including its shape check and `--min-updates` non-vacuity gate, fuzz-stream
  corruption/tail-integrity).
- `make -C tb/unit TOP=<tb> run` for `tb_mold_framer`, `tb_itch_decoder`,
  `tb_price_book`, `tb_book_router`, `tb_itch_book_top` — all pass.

Functional coverage is tallied by hand in the two random-stimulus TBs (Verilator
does not implement covergroups) and gated: `tb_price_book` requires all 14 bins
of {ADD-new-level, ADD-aggregate, ADD-evict-9th, ADD-reject-full,
REDUCE-partial, REDUCE-remove, REDUCE-miss} × {bid, ask} to be hit, and
`tb_book_router` all 10 bins of {ADD, EXEC, CANCEL, DELETE, REPLACE} ×
{hit, miss} (for ADD: tracked / untracked). An empty bin is a `$fatal`, not a
warning.

## Reproducing

```
scripts/download_data.sh              # ~3.5 GB
make test-model
make replay LIMIT=1000000             # ~30 s sim
make replay-headline                  # 10M messages, ~5 min sim

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
