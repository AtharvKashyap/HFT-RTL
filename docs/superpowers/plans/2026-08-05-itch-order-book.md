# Hardware ITCH Limit Order Book — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A synthesizable SystemVerilog pipeline that parses a Nasdaq TotalView-ITCH 5.0 byte stream and maintains top-8 price-level order books for up to 16 symbols, verified against a Python golden model over ≥10M real market messages.

**Architecture:** Five streaming RTL modules (`mold_framer` → `itch_decoder` → `book_router` → 16× `price_book`, wrapped by `itch_book_top`), a Python golden model with identical truncation semantics, and a Verilator C++ replay harness that compares every book update against the model.

**Tech Stack:** SystemVerilog (synthesizable subset), Verilator ≥5.x, Python 3.11+ with pytest, C++17 (harness), Make, GTKWave.

## Global Constraints

- All RTL in `rtl/` must be synthesizable: no delays, no dynamic types, no `initial` blocks except in testbenches. Immediate assertions (`assert(...) else $error`) allowed in RTL under `` `ifndef SYNTHESIS ``.
- v1 datapath is **1 byte/cycle** input (`BYTES_PER_BEAT` parameter exists, only value 1 implemented). Wider datapath is phase-2.
- All multi-byte ITCH fields are **big-endian** on the wire; RTL and model normalize to native integers.
- Prices are 32-bit unsigned, units of 1/10000 USD. Sides: `1 = bid (buy 'B')`, `0 = ask (sell 'S')`.
- Error philosophy: nothing is fatal — every abnormal input increments a counter and drops the message; the pipeline keeps consuming.
- Commit after every task with a plain message describing the change. **No Co-Authored-By trailers.**
- Python: standard library only for the model (no pandas); pytest for tests.
- Book truncation semantics (RTL and model MUST match exactly): each side keeps only the best `N_LEVELS=8` price levels; a level pushed out of the top 8 is **permanently discarded**; a REDUCE whose price is not currently in the top 8 is dropped and counted. Documented approximation per spec.
- Directory layout per spec: `rtl/`, `tb/unit/`, `tb/replay/`, `model/`, `data/` (gitignored), `docs/`, `Makefile`.

## ITCH 5.0 message layouts (reference for all tasks)

Payload byte offsets (offset 0 = message type char). Common header: `type[0]`, `stock_locate[1:2]`, `tracking[3:4]`, `timestamp[5:10]`.

| Type | Len | Fields after common header |
|---|---|---|
| `S` System Event | 12 | event_code[11] |
| `A` Add Order | 36 | order_ref[11:18], side[19] ('B'/'S'), shares[20:23], stock[24:31] (8 ASCII, space-padded), price[32:35] |
| `F` Add w/ MPID | 40 | same as `A`, plus attribution[36:39] (ignored) |
| `E` Order Executed | 31 | order_ref[11:18], exec_shares[19:22], match_num[23:30] (ignored) |
| `C` Executed w/ Price | 36 | as `E`, plus printable[31], exec_price[32:35] (both ignored — book reduces at the order's resting price) |
| `X` Order Cancel | 23 | order_ref[11:18], canceled_shares[19:22] |
| `D` Order Delete | 19 | order_ref[11:18] |
| `U` Order Replace | 35 | orig_ref[11:18], new_ref[19:26], shares[27:30], price[31:34] |

All other types: skipped by length, counted as `unknown`. Nasdaq sample capture files ("BinaryFILE" format) are a flat sequence of `{2-byte big-endian length, message}` records — no MoldUDP64; the harness wraps them into synthetic MoldUDP64 packets.

MoldUDP64 packet: `session[0:9]` (10B), `sequence[10:17]` (8B BE), `count[18:19]` (2B BE), then `count` × `{2B BE length, message}`. `count=0x0000` = heartbeat; `count=0xFFFF` = end of session.

## Book semantics (RTL `price_book` and Python model MUST both implement exactly this)

- State per side: up to 8 `(price, shares)` levels, bids sorted descending, asks ascending.
- `ADD(side, price, shares)`: if price matches an existing level → `shares += `. Else insert sorted; if that makes 9 levels, drop the worst one. If price is worse than a full book's worst level → drop, count `book_evict`.
- `REDUCE(side, price, shares)`: find level; `shares -=`; if result ≤ 0 remove the level (shift up). If price not found → drop, count `reduce_miss`.
- Emit a full snapshot (both sides, 8 levels each, zeros for empty levels) after every op that changed anything.

---

### Task 1: Repo scaffold + Python ITCH message parser (golden model part 1)

**Files:**
- Create: `.gitignore`, `Makefile`, `model/__init__.py`, `model/itch.py`, `model/tests/test_itch.py`, `pytest.ini`

**Interfaces:**
- Produces: `model/itch.py` with:
  - `@dataclass(frozen=True) class DecodedMsg: kind: str` (one of `"ADD","EXEC","CANCEL","DELETE","REPLACE","SYSTEM"`)`; order_id: int; new_order_id: int; side: str` (`"B"`/`"S"`, ADD only)`; shares: int; price: int; symbol: str` (8-char, ADD only; empty otherwise)
  - `def parse_message(payload: bytes) -> DecodedMsg | None` — returns `None` for ignored/unknown types.
- `.gitignore` must contain `data/`, `build/`, `__pycache__/`, `*.vcd`, `*.fst`.
- `pytest.ini`: `[pytest]\ntestpaths = model/tests`.
- `Makefile` targets in this task: `test-model: pytest -q`.

- [ ] **Step 1: Write failing tests** in `model/tests/test_itch.py` — build each message type from raw bytes with `struct.pack('>...')` and assert every decoded field. Include at minimum:

```python
import struct
from model.itch import parse_message

def _hdr(t): return t + struct.pack('>HH6s', 1, 0, b'\x00'*6)

def test_add_order():
    payload = _hdr(b'A') + struct.pack('>QcI8sI', 42, b'B', 100, b'AAPL    ', 1805000)
    m = parse_message(payload)
    assert m.kind == "ADD" and m.order_id == 42 and m.side == "B"
    assert m.shares == 100 and m.symbol == "AAPL    " and m.price == 1805000

def test_replace():
    payload = _hdr(b'U') + struct.pack('>QQII', 42, 43, 50, 1804000)
    m = parse_message(payload)
    assert m.kind == "REPLACE" and m.order_id == 42 and m.new_order_id == 43
    assert m.shares == 50 and m.price == 1804000

def test_unknown_type_returns_none():
    assert parse_message(_hdr(b'P') + b'\x00'*33) is None
```

Plus analogous tests for `F` (decodes same as ADD), `E`, `C` (both decode to kind `"EXEC"` with `shares` = exec_shares), `X` → `"CANCEL"`, `D` → `"DELETE"`, `S` → `"SYSTEM"`, and a truncated-payload test asserting `None` (parser must length-check before unpacking).

- [ ] **Step 2: Run to verify failure** — `pytest -q` → ImportError/FAIL.
- [ ] **Step 3: Implement `model/itch.py`** — a dict `LAYOUTS = {b'A': (...), ...}` mapping type byte → (expected length, struct format, field mapper); `parse_message` checks `len(payload)` against expected length (return `None` on mismatch, don't raise) and dispatches. No per-type if/elif chains longer than the dispatch table needs.
- [ ] **Step 4: Run to verify pass** — `pytest -q` → all pass.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "Add Python ITCH 5.0 message parser with tests"`

### Task 2: Python order book + order-ID table (golden model part 2)

**Files:**
- Create: `model/book.py`, `model/tests/test_book.py`

**Interfaces:**
- Consumes: `DecodedMsg` from `model/itch.py`.
- Produces: `model/book.py` with:
  - `class PriceBook(n_levels=8)` — methods `add(side: str, price: int, shares: int) -> bool`, `reduce(side: str, price: int, shares: int) -> bool` (return True iff book changed), `snapshot() -> dict` = `{"bid": [(price, shares)×8 zero-padded], "ask": [...]}`. Implements the Book semantics section verbatim, including permanent-discard truncation. Counters: `evict_count`, `reduce_miss_count`.
  - `class MarketModel(symbols: list[str], n_levels=8)` — owns `{symbol: PriceBook}` and an order table `dict[int, (symbol, side, price, shares)]`; method `on_message(msg: DecodedMsg) -> list[dict]` returning zero or more update events `{"symbol_idx": int, "bid": [...], "ask": [...]}` (REPLACE can change the book twice but emits updates per changed op — reduce then add, so up to 2). Handles: ADD (only if symbol tracked → insert table + book), EXEC/CANCEL (lookup table, reduce book at resting price, decrement/free table entry), DELETE (reduce book by remaining shares, free entry), REPLACE (delete old + add new **at the same symbol**; new order inherits symbol from old entry). Untracked symbols and unknown order IDs: dropped, counted in `drop_count`.

- [ ] **Step 1: Write failing tests** in `model/tests/test_book.py`. Concrete cases (each its own test): add creates level; same-price add aggregates; bids sort descending / asks ascending; 9th level evicts worst; add worse than full book's worst is dropped (evict_count increments, book unchanged); reduce to zero removes level and shifts; reduce at unknown price counted as miss; EXEC uses resting price (add at 100, exec msg carries no price, book reduces at 100); DELETE removes remaining shares; REPLACE moves shares to new price and old order_id no longer resolvable; partial CANCEL leaves remainder both in table and book; untracked symbol ADD produces no update and later DELETE of that order_id is a counted drop. Example:

```python
from model.itch import DecodedMsg
from model.book import MarketModel

def _add(oid, sym, side, sh, px):
    return DecodedMsg(kind="ADD", order_id=oid, new_order_id=0,
                      side=side, shares=sh, price=px, symbol=sym.ljust(8))

def test_exec_reduces_at_resting_price():
    m = MarketModel(["AAPL"])
    m.on_message(_add(1, "AAPL", "B", 100, 1805000))
    ev = m.on_message(DecodedMsg(kind="EXEC", order_id=1, new_order_id=0,
                                 side="", shares=40, price=0, symbol=""))
    assert ev[0]["bid"][0] == (1805000, 60)
```

- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement `model/book.py`** per the interface above. Keep `PriceBook` sides as plain sorted lists of `[price, shares]`.
- [ ] **Step 4: Run to verify pass** — `pytest -q`.
- [ ] **Step 5: Commit** — `"Add Python golden order book with top-8 truncation semantics"`

### Task 3: Real data tooling — download, MoldUDP64 wrapper, trace dumper

**Files:**
- Create: `data/README.md`, `scripts/download_data.sh`, `model/binaryfile.py`, `model/moldwrap.py`, `model/dump_trace.py`, `model/tests/test_binaryfile.py`, `model/tests/test_moldwrap.py`

**Interfaces:**
- Produces:
  - `model/binaryfile.py`: `def read_messages(path: str, limit: int | None = None) -> Iterator[bytes]` — yields raw ITCH payloads from a Nasdaq BinaryFILE capture (`{2B BE length, message}` records; supports `.gz` transparently via `gzip.open`).
  - `model/moldwrap.py`: `def wrap(messages: Iterable[bytes], session: bytes = b'SESSION001', msgs_per_packet: int = 4, start_seq: int = 1, gap_after: int | None = None) -> Iterator[bytes]` — yields MoldUDP64 packets per the layout in the reference section; `gap_after=N` skips sequence numbers after the Nth packet (for gap testing). Ends with an end-of-session packet (`count=0xFFFF`).
  - `model/dump_trace.py`: CLI `python -m model.dump_trace <capture> --symbols AAPL,MSFT,... --limit N --out trace.jsonl` — runs messages through `MarketModel`, writes one JSON line per update event: `{"n": <msg ordinal>, "symbol_idx": i, "bid": [[px,sh]...8], "ask": [[px,sh]...8]}`, prints summary (messages, updates, drops) to stderr.
  - `scripts/download_data.sh`: `curl -o data/sample.NASDAQ_ITCH50.gz https://emi.nasdaq.com/ITCH/Nasdaq%20ITCH/<dayfile>.NASDAQ_ITCH50.gz` — pick the smallest current file listed at https://emi.nasdaq.com/ITCH/Nasdaq%20ITCH/ at execution time; record the chosen file + date in `data/README.md` (provenance note: free public Nasdaq sample data).

- [ ] **Step 1: Write failing tests** — `test_binaryfile.py`: write a temp file with 3 length-prefixed records, assert `read_messages` yields exactly those payloads; also a `.gz` variant. `test_moldwrap.py`: wrap 10 fake messages with `msgs_per_packet=4`, parse packets back by hand with `struct`, assert session/sequence/count and payload round-trip; assert `gap_after=1` produces a sequence discontinuity; assert final packet has count `0xFFFF`.
- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement the three modules + script.**
- [ ] **Step 4: Run tests, then the real thing:** `bash scripts/download_data.sh` then `python -m model.dump_trace data/sample.NASDAQ_ITCH50.gz --symbols AAPL,MSFT,SPY,QQQ,TSLA,NVDA,AMD,INTC --limit 1000000 --out build/trace_1m.jsonl`. Expected: runs to completion, prints nonzero update count, spot-check first lines are plausible (bid < ask).
- [ ] **Step 5: Commit** (data/ stays gitignored) — `"Add capture reader, MoldUDP64 wrapper, and golden trace dumper"`

### Task 4: RTL foundation — `book_pkg` + `itch_decoder` + unit TB

**Files:**
- Create: `rtl/book_pkg.sv`, `rtl/itch_decoder.sv`, `tb/unit/tb_itch_decoder.sv`, `tb/unit/Makefile` (verilator invocation shared by later TBs)

**Interfaces:**
- Produces `rtl/book_pkg.sv` exactly:

```systemverilog
package book_pkg;
  parameter int NUM_SYMBOLS   = 16;
  parameter int N_LEVELS      = 8;
  parameter int TABLE_ADDR_W  = 16;
  parameter int MAX_PROBES    = 8;
  parameter int BOOK_IDX_W    = $clog2(NUM_SYMBOLS);

  typedef enum logic [2:0] {MSG_ADD, MSG_EXEC, MSG_CANCEL, MSG_DELETE,
                            MSG_REPLACE, MSG_SYSTEM} msg_kind_e;

  typedef struct packed {
    msg_kind_e   kind;
    logic [63:0] order_id;      // original ref for REPLACE
    logic [63:0] new_order_id;  // REPLACE only, else 0
    logic        side;          // 1=bid('B'), 0=ask('S'); ADD only
    logic [31:0] shares;
    logic [31:0] price;         // 1/10000 USD; ADD and REPLACE only
    logic [63:0] symbol;        // 8 ASCII chars; ADD only, else 0
  } decoded_msg_t;

  typedef enum logic {OP_ADD, OP_REDUCE} book_op_e;

  typedef struct packed {
    book_op_e                op;
    logic [BOOK_IDX_W-1:0]   book_idx;
    logic                    side;
    logic [31:0]             price;
    logic [31:0]             shares;
  } book_op_t;

  typedef struct packed {
    logic [BOOK_IDX_W-1:0]        book_idx;
    logic [N_LEVELS-1:0][31:0]    bid_price;
    logic [N_LEVELS-1:0][31:0]    bid_shares;
    logic [N_LEVELS-1:0][31:0]    ask_price;
    logic [N_LEVELS-1:0][31:0]    ask_shares;
    logic [63:0]                  timestamp;
  } book_update_t;
endpackage
```

  Index 0 of each level array = best level. Empty levels are all-zeros.
- Produces `rtl/itch_decoder.sv`:

```systemverilog
module itch_decoder (
  input  logic        clk, rst_n,
  input  logic        in_valid,
  input  logic [7:0]  in_data,
  input  logic        in_last,       // final byte of one ITCH message
  output book_pkg::decoded_msg_t out_msg,
  output logic        out_valid,     // 1-cycle pulse, cycle after in_last
  output logic [31:0] unknown_count
);
```

  Behavior: accumulate bytes into a 40-byte buffer + byte counter; on `in_last`, combinationally decode per the ITCH layout table (registered out). Length mismatch for a known type, or unknown type → `unknown_count++`, no `out_valid`. Buffer resets after every message.

**Testbench pattern for all unit TBs (this and later tasks):** self-checking SV testbench with a `initial` stimulus block, task-based drivers (`task send_msg(input byte payload[])` driving byte-by-byte), immediate assertions on outputs, `$fatal(1, ...)` on mismatch, `$display("PASS")` + `$finish` at end. Run under Verilator `--binary --timing -Wall`. `tb/unit/Makefile`:

```makefile
TOP ?= tb_itch_decoder
run:
	verilator --binary --timing -Wall -Wno-UNUSEDSIGNAL -I../../rtl \
	  ../../rtl/book_pkg.sv ../../rtl/*.sv $(TOP).sv --top $(TOP) -o $(TOP)
	./obj_dir/$(TOP)
```

- [ ] **Step 1: Write `tb_itch_decoder.sv` (failing)** — directed tests mirroring Task 1's Python tests: one `send_msg` per ITCH type built from local byte arrays (same field values as the Python tests so both golden sources agree), assert every field of `out_msg` and that `out_valid` pulses exactly once per message; send an unknown type `P` and a truncated `A` (19 bytes), assert `unknown_count` increments and no `out_valid`; back-to-back messages with no idle cycles.
- [ ] **Step 2: Run to verify failure** — `make -C tb/unit TOP=tb_itch_decoder run` fails (module missing).
- [ ] **Step 3: Implement `book_pkg.sv` + `itch_decoder.sv`.**
- [ ] **Step 4: Run to verify pass.**
- [ ] **Step 5: Commit** — `"Add book package and ITCH decoder with unit testbench"`

### Task 5: `mold_framer` + unit TB

**Files:**
- Create: `rtl/mold_framer.sv`, `tb/unit/tb_mold_framer.sv`

**Interfaces:**
- Produces `rtl/mold_framer.sv`:

```systemverilog
module mold_framer (
  input  logic        clk, rst_n,
  input  logic        in_valid,
  input  logic [7:0]  in_data,
  output logic        in_ready,       // always 1 in v1; kept for interface stability
  output logic        out_valid,
  output logic [7:0]  out_data,
  output logic        out_last,       // last byte of current ITCH message
  output logic [31:0] gap_count,
  output logic        end_of_session  // sticky, set on count==16'hFFFF
);
```

  FSM: `SESSION(10B) → SEQ(8B) → COUNT(2B) → MSG_LEN(2B) → MSG_BODY(len B, pass through with out_valid; out_last on final byte) → (more messages? MSG_LEN : SESSION)`. Track `expected_seq`; on header `seq != expected_seq`, `gap_count += 1` and resync to received seq. `expected_seq += count` per packet. Heartbeat (`count==0`) → straight back to SESSION. Zero-length message (`len==0`) → counted as gap-style anomaly? No: increment `gap_count`? — No. Add separate `logic [31:0] malformed_count` output; `len==0` increments it and FSM proceeds to next MSG_LEN.
- Consumes: nothing upstream; output feeds `itch_decoder` byte interface from Task 4.

- [ ] **Step 1: Write `tb_mold_framer.sv` (failing)** — a `send_packet(seq, byte msgs[][])` task that serializes MoldUDP64 bytes. Tests: single packet/single message passes payload through with correct `out_last`; multi-message packet (4 msgs) frames each; heartbeat produces no output; sequence gap increments `gap_count` exactly once and stream continues; end-of-session sets sticky flag; zero-length message increments `malformed_count` and following message still decodes; bytes with idle gaps (in_valid deasserted mid-packet) frame identically.
- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to verify pass.** Also re-run Task 4 TB (shared Makefile compiles all RTL — catches breakage).
- [ ] **Step 5: Commit** — `"Add MoldUDP64 framer with gap detection and unit testbench"`

### Task 6: `price_book` + unit TB (hardest module)

**Files:**
- Create: `rtl/price_book.sv`, `tb/unit/tb_price_book.sv`

**Interfaces:**
- Produces `rtl/price_book.sv`:

```systemverilog
module price_book #(parameter logic [book_pkg::BOOK_IDX_W-1:0] MY_IDX = '0) (
  input  logic                  clk, rst_n,
  input  book_pkg::book_op_t    op,
  input  logic                  op_valid,      // one op per cycle accepted
  input  logic [63:0]           timestamp_in,
  output book_pkg::book_update_t upd,
  output logic                  upd_valid,     // 1-cycle pulse when book changed
  output logic [31:0]           evict_count,
  output logic [31:0]           reduce_miss_count
);
```

  Implementation: per side, `logic [N_LEVELS-1:0][31:0] price, shares; logic [N_LEVELS-1:0] vld`. Single-cycle op: parallel per-level comparators produce `match` one-hot and (for ADD) an insertion index from a priority network; next-state computed combinationally as shift-down (insert) / shift-up (remove) / in-place add-sub; registered. Implements the Book semantics section verbatim. `upd` snapshot registered same cycle, `upd_valid` pulses the following cycle.
  In-RTL assertions (under `` `ifndef SYNTHESIS ``): each side strictly sorted among valid levels; no duplicate prices; `vld` is contiguous from index 0; when both sides non-empty, `bid_price[0] < ask_price[0]` is **not** asserted (real feeds cross momentarily during opens) — instead count crossings in a `crossed_count` debug counter (add as output).
- Consumes: `book_op_t` from `book_pkg` (Task 4).

- [ ] **Step 1: Write `tb_price_book.sv` (failing)** — directed cases mirroring Task 2's Python tests exactly (same prices/shares so both goldens agree): insert at top/middle/bottom; aggregate same price; 9th-level eviction; add-worse-than-full drop + `evict_count`; reduce partial / to-zero-with-shift / miss + `reduce_miss_count`; ops on both sides; op every cycle back-to-back. Then a **constrained-random phase**: 10,000 random ops (price ∈ {90..110}×10000 to force collisions, shares ∈ {1..500}, op/side random) checked against a behavioral reference model implemented as SV functions inside the TB (unsorted associative array rebuilt/sorted per op — slow but obviously correct); compare full snapshot after every op; `$fatal` on first divergence with op number printed.
- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to verify pass** (directed + 10k random).
- [ ] **Step 5: Commit** — `"Add single-cycle top-8 price level book with randomized unit testbench"`

### Task 7: `book_router` (symbol filter + order-ID table) + unit TB

**Files:**
- Create: `rtl/book_router.sv`, `tb/unit/tb_book_router.sv`

**Interfaces:**
- Produces `rtl/book_router.sv`:

```systemverilog
module book_router #(
  parameter logic [63:0] SYMBOLS [book_pkg::NUM_SYMBOLS] = '{default: '0}
) (
  input  logic                    clk, rst_n,
  input  book_pkg::decoded_msg_t  in_msg,
  input  logic                    in_valid,
  output book_pkg::book_op_t      out_op,
  output logic                    out_valid,
  output logic                    busy,          // processing a lookup/replace
  output logic [31:0]             drop_count,    // untracked symbol / unknown order id
  output logic [31:0]             table_full_count,
  output logic [31:0]             occupancy
);
```

  Symbol filter: parallel compare of `in_msg.symbol` against the `SYMBOLS` parameter array → `book_idx` (combinational).
  Order table: `(1<<TABLE_ADDR_W)` entries `{vld, order_id[63:0], book_idx, side, price[31:0], shares[31:0]}` in a synchronous-read memory array. Hash = XOR-fold of order_id down to `TABLE_ADDR_W` bits. Linear probe FSM, up to `MAX_PROBES` reads (1/cycle): insert on ADD (first free slot; all probes occupied → `table_full_count++`, drop); lookup on EXEC/CANCEL/DELETE/REPLACE (probe until id match; miss after `MAX_PROBES` or empty-slot-hit → `drop_count++`).
  Op emission: ADD → `OP_ADD` (after insert). EXEC/CANCEL → `OP_REDUCE` with stored price and message shares; decrement stored shares, free entry if ≤0. DELETE → `OP_REDUCE` with stored remaining shares, free entry. REPLACE → **two ops**: `OP_REDUCE` (old price, full remaining) then, next cycle(s), insert new_order_id (inheriting book_idx; side kept from old entry) and emit `OP_ADD` (new price/shares).
  Timing contract: byte-wide upstream guarantees ≥19 idle cycles between messages; assert (`` `ifndef SYNTHESIS ``) that `in_valid` never arrives while `busy`.
- Consumes: `decoded_msg_t` (Task 4). Produces ops consumed by `price_book` (Task 6).

- [ ] **Step 1: Write `tb_book_router.sv` (failing)** — instantiate with `SYMBOLS[0]="AAPL    "`, `SYMBOLS[1]="MSFT    "` (as 64-bit ASCII literals). Directed: ADD tracked symbol → OP_ADD with right idx/side/price; ADD untracked → no op, `drop_count++`; EXEC resolves resting price and partial-decrements (second EXEC on same id still resolves with reduced shares); DELETE emits remaining shares and frees (subsequent EXEC on that id → drop); REPLACE emits REDUCE-then-ADD with inherited book_idx/side; unknown order id EXEC → drop; two ids that collide in hash (craft ids equal modulo fold) both resolve via probing; fill `MAX_PROBES` colliding ids then one more → `table_full_count++`. Random phase: 5,000 messages mirroring a scoreboard `dict`-style associative-array model in the TB; compare every emitted op.
- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to verify pass; re-run all prior unit TBs.**
- [ ] **Step 5: Commit** — `"Add symbol filter and hashed order-ID table router with unit testbench"`

### Task 8: `itch_book_top` integration + smoke TB

**Files:**
- Create: `rtl/itch_book_top.sv`, `tb/unit/tb_itch_book_top.sv`

**Interfaces:**
- Produces `rtl/itch_book_top.sv`:

```systemverilog
module itch_book_top #(
  parameter logic [63:0] SYMBOLS [book_pkg::NUM_SYMBOLS] = '{default: '0}
) (
  input  logic        clk, rst_n,
  input  logic        in_valid,
  input  logic [7:0]  in_data,
  output logic        in_ready,
  output book_pkg::book_update_t upd,
  output logic        upd_valid,
  // status
  output logic [31:0] gap_count, malformed_count, unknown_count,
  output logic [31:0] drop_count, table_full_count,
  output logic        end_of_session
);
```

  Wires framer → decoder → router → `generate` loop of 16 `price_book`s (op fanned out, `op_valid` gated by `book_idx == i`); update outputs muxed by a registered `last_book_idx` (one op in flight at a time ⇒ no collision; assert it). Free-running 64-bit cycle counter feeds `timestamp_in`.
- Consumes: all prior modules.

- [ ] **Step 1: Write `tb_itch_book_top.sv` (failing)** — end-to-end smoke: serialize a MoldUDP64 packet containing `A`(AAPL bid 100@1805000), `A`(ask 50@1806000), `E`(40 of order 1), `D`(order 2) byte-by-byte into the top; assert the four `upd` snapshots match hand-computed books and `upd.book_idx==0`; assert `upd.timestamp` strictly increases; end with heartbeat + end-of-session packet, assert sticky flag.
- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to verify pass; re-run all unit TBs.**
- [ ] **Step 5: Commit** — `"Add top-level integration wiring framer, decoder, router, and books"`

### Task 9: Verilator C++ replay harness + golden comparison (headline)

**Files:**
- Create: `tb/replay/replay_main.cpp`, `tb/replay/Makefile`, `model/compare_traces.py`, `scripts/run_replay.sh`
- Modify: root `Makefile` (add `replay` target chaining the steps)

**Interfaces:**
- Consumes: `itch_book_top` (Task 8), `model/dump_trace.py` + `model/moldwrap.py` (Task 3).
- Produces:
  - `tb/replay/replay_main.cpp`: Verilates `itch_book_top` (`verilator --cc -O3`). Reads a **pre-wrapped byte stream** file (produced by a new `--wrap-out FILE` option added to `model/dump_trace.py` in this task: dumps the exact MoldUDP64 byte stream alongside the golden trace so RTL and model consume byte-identical input). Drives one byte/cycle; on each `upd_valid`, writes a JSONL line in the exact `dump_trace` format plus `"lat": <cycle_now - cycle_last_byte_of_msg>`; tracks message boundaries by watching the DUT's framer `out_last` (expose via a `/* verilator public */` comment or top-level debug port `msg_boundary` — add the debug port). Prints totals + latency min/median/p99/max at exit. `SYMBOLS` parameter fixed at verilate time to the 8 symbols used in Task 3 (pass via `-GSYMBOLS=...` or a small generated header — implementer's choice, document in Makefile).
  - `model/compare_traces.py`: CLI `python -m model.compare_traces golden.jsonl rtl.jsonl` — field-by-field compare ignoring `lat`/`timestamp`; on mismatch prints both lines + ordinal and exits 1; on success prints match count and exits 0.
  - `scripts/run_replay.sh`: end-to-end — dump golden trace + wrapped bytes (1M messages), build + run harness, run compare. Root `Makefile` target `replay` calls it.

- [ ] **Step 1: Write the comparison test first** — `model/tests/test_compare.py`: two tiny JSONL fixtures, one matching, one with a single differing share count; assert exit codes 0/1. Run → fails.
- [ ] **Step 2: Implement `compare_traces.py`**, pass the test. Add `--wrap-out` to `dump_trace.py` (test: wrapped bytes parse back through `moldwrap`-format reader assertions in `test_moldwrap.py`).
- [ ] **Step 3: Implement harness + Makefiles.** Build: `make -C tb/replay`. Smoke: replay the first **10,000** messages; run compare. Expected: zero mismatches. Debug divergences one message at a time (`--limit` bisect) before scaling up.
- [ ] **Step 4: Scale to 1M, then full run:** `scripts/run_replay.sh --limit 10000000`. Expected: **≥10M messages, zero mismatches**; capture the printed latency distribution. Record message rate (msgs/sec of sim) for the README.
- [ ] **Step 5: Save results** — write `docs/results.md` with: message count, mismatch count (0), latency table (min/median/p99/max cycles, per op where the harness distinguishes), counter totals (gaps, unknowns, drops), data file provenance.
- [ ] **Step 6: Commit** — `"Add Verilator replay harness and golden-trace comparison; 10M-message zero-mismatch run"`

### Task 10: Fuzz robustness + README polish

**Files:**
- Create: `model/fuzz_stream.py`, `tb/unit/tb_fuzz_recovery.sv` (or harness mode `--fuzz`), `README.md`
- Modify: `docs/results.md`

**Interfaces:**
- Consumes: everything.
- Produces: `model/fuzz_stream.py` — takes a wrapped byte stream and a seed; injects bursts of corruption (random byte flips inside message bodies, truncated packets, bogus lengths ≤ 50, random garbage between packets is NOT injected — MoldUDP is a continuous stream, corruption stays in-band), then appends a **clean tail** of 1,000 valid messages. Harness `--fuzz` mode: run corrupted stream; assertion = DUT never hangs (watchdog: output or state-machine progress within 10,000 cycles), error counters are nonzero, and the final 1,000-message clean tail produces updates again (books may legitimately differ from a clean-only run — the check is liveness + counting, not state equality; state re-sync after garbage is out of scope and documented).

- [ ] **Step 1: Write `fuzz_stream.py` + a pytest** asserting corruption actually changed bytes and the clean tail is intact.
- [ ] **Step 2: Add `--fuzz` mode to the harness; run with 3 seeds.** Expected: no hangs, nonzero `malformed/unknown/drop` counters, updates resume on clean tail.
- [ ] **Step 3: Write `README.md`** — what it is (2 paragraphs, the elevator pitch from the spec), architecture diagram (ASCII from spec), how to run (`make test-model`, `make -C tb/unit run TOP=...`, `make replay`), headline results copied from `docs/results.md`, phase-2 roadmap (UVM-on-VCS, Vivado timing, tick-to-trade, wide datapath).
- [ ] **Step 4: Full regression** — all pytest, all unit TBs, 10M replay, fuzz ×3. All green.
- [ ] **Step 5: Commit** — `"Add fuzz robustness testing and project README"` — **M6/portfolio-ready point.**

---

## Execution notes

- Tasks 1→2→3 and 4→5→6→7 have strict order within their chains, but the Python chain (1–3) and RTL chain (4–7) only join at Task 9 (Task 8 needs 4–7). Task 4 depends on Task 1's field-value conventions for mirrored tests.
- Dispatch per user preference: **Opus** subagents for Tasks 6, 7, 9 (hard); **Sonnet** for Tasks 1, 2, 3, 5, 8, 10.
- Verilator must be installed first (`brew install verilator`, need ≥5.0 for `--binary --timing`); fold into Task 1 setup.
- Nasdaq occasionally reorganizes the sample-file listing; Task 3's executor must verify the URL and record the actual filename used.
