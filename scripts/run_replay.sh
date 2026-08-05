#!/usr/bin/env bash
# End-to-end replay verification: golden model -> RTL -> compare.
#
#   scripts/run_replay.sh [--limit N] [--capture PATH] [--out-dir DIR] [--keep]
#
# Steps:
#   1. model/dump_trace.py runs N messages of the capture through the Python
#      golden model, writing the golden trace AND (--wrap-out) the exact
#      MoldUDP64 byte stream it consumed.
#   2. tb/replay is built (Verilator --cc -O3) and fed that same byte stream.
#   3. model/compare_traces.py compares the two JSONL traces field by field
#      (ignoring the RTL-only `lat`/`timestamp`).
#
# Exit status is 0 only if every update matched. --limit defaults to 1,000,000;
# the headline run is `scripts/run_replay.sh --limit 10000000`.
#
# SYMBOLS is passed identically to dump_trace (--symbols) and to the harness
# build (which bakes it in at verilate time via scripts/gen_symbols.py), so
# book_idx in the RTL always equals symbol_idx in the golden trace.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

LIMIT=1000000
CAPTURE="data/sample.NASDAQ_ITCH50.gz"
OUT_DIR="build"
SYMBOLS="AAPL,MSFT,SPY,QQQ,TSLA,NVDA,AMD,INTC"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit)   LIMIT="$2"; shift 2 ;;
    --capture) CAPTURE="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --symbols) SYMBOLS="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "run_replay: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

if [[ ! -f "$CAPTURE" ]]; then
  echo "run_replay: capture not found: $CAPTURE (see scripts/download_data.sh)" >&2
  exit 2
fi

TAG="$LIMIT"
GOLDEN="$OUT_DIR/golden_${TAG}.jsonl"
STREAM="$OUT_DIR/stream_${TAG}.mold"
RTL="$OUT_DIR/rtl_${TAG}.jsonl"
mkdir -p "$OUT_DIR"

echo "== 1/3 golden model: $LIMIT messages of $CAPTURE =="
time python3 -m model.dump_trace "$CAPTURE" --symbols "$SYMBOLS" \
    --limit "$LIMIT" --out "$GOLDEN" --wrap-out "$STREAM"

echo "== 2/3 build + run RTL replay harness =="
make -C tb/replay SYMBOLS="$SYMBOLS"
# The harness is invoked directly rather than via `make run`: this repo's path
# contains a space, which make cannot pass through a recipe variable intact.
HARNESS="$(make -C tb/replay -s print-bin SYMBOLS="$SYMBOLS")"
time "$HARNESS" --in "$STREAM" --out "$RTL"

echo "== 3/3 compare golden vs RTL =="
python3 -m model.compare_traces "$GOLDEN" "$RTL"
