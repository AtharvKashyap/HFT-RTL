#!/usr/bin/env bash
# Fuzz robustness run: build a corrupted MoldUDP64 stream (model/fuzz_stream.py)
# for each of 3 seeds and run it through the replay harness's --fuzz mode.
#
#   scripts/run_fuzz.sh [--seeds "1 2 3"] [--out-dir DIR] [--symbols LIST]
#
# See docs/results.md ("Fuzz robustness") for what --fuzz checks and why.
# Exit status is 0 only if every seed passes.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SEEDS="1 2 3"
OUT_DIR="build"
SYMBOLS="AAPL,MSFT,SPY,QQQ,TSLA,NVDA,AMD,INTC"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --seeds)   SEEDS="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --symbols) SYMBOLS="$2"; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "run_fuzz: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

mkdir -p "$OUT_DIR"

echo "== build replay harness =="
make -C tb/replay SYMBOLS="$SYMBOLS"
HARNESS="$(make -C tb/replay -s print-bin SYMBOLS="$SYMBOLS")"

fail=0
for seed in $SEEDS; do
  MOLD="$OUT_DIR/fuzz_${seed}.mold"
  META="$OUT_DIR/fuzz_${seed}.json"
  RTL="$OUT_DIR/fuzz_rtl_${seed}.jsonl"

  echo "== seed $seed: building corrupted stream =="
  python3 -m model.fuzz_stream --seed "$seed" --out "$MOLD" --meta "$META" --symbols "$SYMBOLS"
  TAIL_START="$(python3 -c "import json; print(json.load(open('$META'))['tail_start'])")"

  echo "== seed $seed: running --fuzz (tail_start=$TAIL_START) =="
  if ! "$HARNESS" --in "$MOLD" --out "$RTL" --fuzz --tail-start "$TAIL_START"; then
    echo "seed $seed: FAIL" >&2
    fail=1
  fi
done

exit "$fail"
