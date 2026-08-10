#!/usr/bin/env bash
# End-to-end replay verification: golden model -> RTL -> compare.
#
#   scripts/run_replay.sh [--limit N] [--capture PATH] [--out-dir DIR]
#                         [--symbols LIST] [--min-updates N] [--min-orders N]
#                         [--thresh-log2 N] [--cooldown N] [--order-shares N]
#                         [--max-position N] [--min-spacing N] [--collar-shift N]
#
# Steps:
#   1. model/dump_trace.py runs N messages of the capture through the Python
#      golden chain (book + strategy + risk + OUCH encoder), writing the golden
#      book trace, the golden order stream (--orders-out) AND (--wrap-out) the
#      exact MoldUDP64 byte stream it consumed.
#   2. tb/replay is built (Verilator --cc -O3) around tick_to_trade_top and fed
#      that same byte stream, emitting its own book trace and order stream.
#   3. Both are compared: model/compare_traces.py on the book updates and
#      model/compare_orders.py on the OUCH frames. The DUT's strategy/risk/
#      encoder counters are also asserted equal to the golden model's own
#      summary, which catches a divergence that never reaches the wire (an
#      intent rejected on one side and accepted on the other, say, only shows
#      up in the order stream if it changes which orders are sent).
#
# Exit status is 0 only if every update matched, every order frame matched, and
# every counter agreed. --limit defaults to 1,000,000; the headline run is
# `scripts/run_replay.sh --limit 10000000`.
#
# --symbols is the comma-separated tracked-symbol list (default below). It is
# passed identically to dump_trace (--symbols) and to the harness build (which
# bakes it in at verilate time via scripts/gen_symbols.py), so book_idx in the
# RTL always equals symbol_idx in the golden trace.
#
# The strategy/risk parameters are likewise passed to BOTH sides -- to
# dump_trace as flags and to verilator as -G overrides -- from the single set
# of defaults below, which match trade_pkg's *_DEF values and the golden
# model's own defaults. Tuning on the real capture kept every default, so the
# usual run passes nothing.
#
# --min-updates and --min-orders are the comparators' non-vacuity gates: a run
# in which fewer than N updates (or orders) matched fails, so "0 mismatches"
# can never mean "nothing compared". --min-updates defaults to 1, raised to 100
# for --limit >= 1,000,000. The 10k rung of the ladder legitimately produces no
# updates at all (the first 10k records of the trading day are pre-open
# administrative messages), so that one run needs an explicit `--min-updates 0`.
# --min-orders defaults to 0 below 1,000,000 messages and 1 at or above it: the
# strategy is deliberately selective (tens of orders per 10M messages), so the
# small rungs legitimately send nothing at all and only the large rungs can
# assert that the order path did anything.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

LIMIT=1000000
CAPTURE="data/sample.NASDAQ_ITCH50.gz"
OUT_DIR="build"
SYMBOLS="AAPL,MSFT,SPY,QQQ,TSLA,NVDA,AMD,INTC"
MIN_UPDATES=""
MIN_ORDERS=""

# Strategy / risk parameters -- one source of truth for both sides.
THRESH_LOG2=2
COOLDOWN=16
ORDER_SHARES=100
MAX_POSITION=1000
MIN_SPACING=10
COLLAR_SHIFT=3

while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit)        LIMIT="$2"; shift 2 ;;
    --capture)      CAPTURE="$2"; shift 2 ;;
    --out-dir)      OUT_DIR="$2"; shift 2 ;;
    --symbols)      SYMBOLS="$2"; shift 2 ;;
    --min-updates)  MIN_UPDATES="$2"; shift 2 ;;
    --min-orders)   MIN_ORDERS="$2"; shift 2 ;;
    --thresh-log2)  THRESH_LOG2="$2"; shift 2 ;;
    --cooldown)     COOLDOWN="$2"; shift 2 ;;
    --order-shares) ORDER_SHARES="$2"; shift 2 ;;
    --max-position) MAX_POSITION="$2"; shift 2 ;;
    --min-spacing)  MIN_SPACING="$2"; shift 2 ;;
    --collar-shift) COLLAR_SHIFT="$2"; shift 2 ;;
    -h|--help) sed -n '2,48p' "$0"; exit 0 ;;
    *) echo "run_replay: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

# Non-vacuity floors: any real rung emits at least one update, and the rungs
# large enough to be called a verification run emit thousands.
if [[ -z "$MIN_UPDATES" ]]; then
  if (( LIMIT >= 1000000 )); then MIN_UPDATES=100; else MIN_UPDATES=1; fi
fi
if [[ -z "$MIN_ORDERS" ]]; then
  if (( LIMIT >= 1000000 )); then MIN_ORDERS=1; else MIN_ORDERS=0; fi
fi

if [[ ! -f "$CAPTURE" ]]; then
  echo "run_replay: capture not found: $CAPTURE (see scripts/download_data.sh)" >&2
  exit 2
fi

TAG="$LIMIT"
GOLDEN="$OUT_DIR/golden_${TAG}.jsonl"
GOLDEN_ORDERS="$OUT_DIR/golden_orders_${TAG}.jsonl"
STREAM="$OUT_DIR/stream_${TAG}.mold"
RTL="$OUT_DIR/rtl_${TAG}.jsonl"
RTL_ORDERS="$OUT_DIR/rtl_orders_${TAG}.jsonl"
GOLDEN_SUMMARY="$OUT_DIR/golden_summary_${TAG}.txt"
RTL_SUMMARY="$OUT_DIR/rtl_summary_${TAG}.txt"
mkdir -p "$OUT_DIR"

echo "== 1/4 golden model: $LIMIT messages of $CAPTURE =="
echo "   params: thresh_log2=$THRESH_LOG2 cooldown=$COOLDOWN shares=$ORDER_SHARES"
echo "           max_position=$MAX_POSITION min_spacing=$MIN_SPACING collar_shift=$COLLAR_SHIFT"
# The summary line dump_trace prints on stderr is the golden side of the
# counter assertion below, so stderr is redirected to a file and replayed
# afterwards. A plain redirect rather than a `tee` process substitution: the
# file is read much later in this script, and a process substitution's write
# is not synchronised with the shell that outlives it.
SECONDS=0
python3 -m model.dump_trace "$CAPTURE" --symbols "$SYMBOLS" \
    --limit "$LIMIT" --out "$GOLDEN" --wrap-out "$STREAM" \
    --orders-out "$GOLDEN_ORDERS" \
    --thresh-log2 "$THRESH_LOG2" --cooldown "$COOLDOWN" \
    --order-shares "$ORDER_SHARES" --max-position "$MAX_POSITION" \
    --min-spacing "$MIN_SPACING" --collar-shift "$COLLAR_SHIFT" \
    2>"$GOLDEN_SUMMARY" || { cat "$GOLDEN_SUMMARY" >&2; exit 1; }
cat "$GOLDEN_SUMMARY" >&2
echo "   golden model: ${SECONDS}s"

echo "== 2/4 build + run RTL replay harness =="
MAKE_ARGS=(SYMBOLS="$SYMBOLS" THRESH_LOG2="$THRESH_LOG2"
           COOLDOWN_UPDATES="$COOLDOWN" ORDER_SHARES="$ORDER_SHARES"
           MAX_POSITION="$MAX_POSITION" MIN_ORDER_SPACING="$MIN_SPACING"
           COLLAR_SHIFT="$COLLAR_SHIFT")
make -C tb/replay "${MAKE_ARGS[@]}"
# The harness is invoked directly rather than via `make run`: this repo's path
# contains a space, which make cannot pass through a recipe variable intact.
HARNESS="$(make -C tb/replay -s print-bin "${MAKE_ARGS[@]}")"
SECONDS=0
"$HARNESS" --in "$STREAM" --out "$RTL" --orders-out "$RTL_ORDERS" \
    | tee "$RTL_SUMMARY"
echo "   RTL replay: ${SECONDS}s"

echo "== 3/4 compare golden vs RTL =="
echo "-- book updates (--min-updates $MIN_UPDATES) --"
python3 -m model.compare_traces "$GOLDEN" "$RTL" --min-updates "$MIN_UPDATES"
echo "-- OUCH orders (--min-orders $MIN_ORDERS) --"
python3 -m model.compare_orders "$GOLDEN_ORDERS" "$RTL_ORDERS" \
    --min-orders "$MIN_ORDERS"

echo "== 4/4 strategy/risk counter agreement =="
# Golden: "... intents=N accepts=N rejects=sanity:A/collar:B/rate:C/pos:D orders=N"
# RTL   : the "--- trade counters ---" block of the harness summary.
g_field() { sed -n "s/.*[ =]$1=\([0-9][0-9]*\).*/\1/p" "$GOLDEN_SUMMARY" | tail -1; }
g_reject() { sed -n "s#.*rejects=sanity:\([0-9]*\)/collar:\([0-9]*\)/rate:\([0-9]*\)/pos:\([0-9]*\).*#\\$1#p" "$GOLDEN_SUMMARY" | tail -1; }
r_field() { sed -n "s/^$1 *: *\([0-9][0-9]*\).*/\1/p" "$RTL_SUMMARY" | tail -1; }

status=0
check() {  # check <label> <golden> <rtl>
  if [[ -z "$2" || -z "$3" ]]; then
    echo "   MISSING $1: golden='$2' rtl='$3'" >&2
    status=1
  elif [[ "$2" != "$3" ]]; then
    echo "   MISMATCH $1: golden=$2 rtl=$3" >&2
    status=1
  else
    printf '   %-16s %s\n' "$1" "$2"
  fi
}

check intents        "$(g_field intents)"  "$(r_field intent_count)"
check accepts        "$(g_field accepts)"  "$(r_field accept_count)"
check sanity_rejects "$(g_reject 1)"       "$(r_field sanity_reject_count)"
check collar_rejects "$(g_reject 2)"       "$(r_field collar_reject_count)"
check rate_rejects   "$(g_reject 3)"       "$(r_field rate_reject_count)"
check pos_rejects    "$(g_reject 4)"       "$(r_field pos_reject_count)"
check orders         "$(g_field orders)"   "$(r_field order_count)"

fifo_drops="$(r_field fifo_drop_count)"
if [[ "$fifo_drops" != "0" ]]; then
  echo "   FIFO DROPS: $fifo_drops accepted order(s) never reached the wire" >&2
  status=1
fi

if (( status != 0 )); then
  echo "run_replay: RTL counters disagree with the golden model" >&2
  exit 1
fi
echo "   all counters agree (fifo_drop_count=0)"
