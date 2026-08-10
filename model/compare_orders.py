"""Golden vs RTL OUCH order-stream comparator.

Both files are JSONL, one line per accepted-and-encoded order. The golden side
is written by `model/dump_trace.py --orders-out`:

    {"n": <message ordinal>, "token": ..., "side": ..., "symbol_idx": ...,
     "shares": ..., "price": ..., "raw": "<hex of the 51-byte OUCH frame>"}

and the RTL side by `tb/replay/replay_main.cpp`, which sees only wire bytes:

    {"n": <message ordinal at frame_start>, "raw": "<hex>", "lat": <cycles>}

Only `n` and `raw` are compared. `raw` is the whole wire frame, so every
decoded field the golden side also prints (token, side, symbol_idx, shares,
price) is already covered by it byte for byte -- comparing them separately
would only re-check the golden model against itself. `lat` is a hardware-only
measurement and has no golden counterpart.

The two streams must line up 1:1: same orders, same sequence. Each line is
shape-checked first (both keys present, `raw` a hex string of exactly
ORDER_FRAME_BYTES bytes), so two equally degenerate stubs cannot pass by
agreeing with each other; and `--min-orders N` fails a run that matched fewer
than N orders, so "0 mismatches" can never mean "nothing compared".

Streaming by design, like model/compare_traces.py: neither file is loaded whole.

Usage:
    python -m model.compare_orders golden_orders.jsonl rtl_orders.jsonl
                                   [--max-report N] [--min-orders N]
Exit codes: 0 = identical, 1 = divergence (or unreadable input).
"""

import argparse
import json
import sys
from typing import Iterator

# Both sides must carry these; everything else on either line is ignored.
REQUIRED_FIELDS = ("n", "raw")

# OUCH 4.2 Enter Order as this project frames it: a 2-byte big-endian length
# prefix plus the 49-byte body (see rtl/ouch_encoder.sv and model/ouch.py).
ORDER_FRAME_BYTES = 51


class OrderShapeError(ValueError):
    """A line parsed as JSON but is not a well-formed order record."""


def _normalize(obj: dict) -> tuple:
    """Shape-check a line and reduce it to the compared pair (n, raw_bytes).

    `raw` is decoded from hex rather than string-compared so that a producer
    emitting upper-case hex still matches one emitting lower-case: the contract
    is the bytes on the wire, not their transcription.
    """
    if not isinstance(obj, dict):
        raise OrderShapeError(f"line is a {type(obj).__name__}, expected an object")
    missing = [k for k in REQUIRED_FIELDS if k not in obj]
    if missing:
        raise OrderShapeError(f"missing required field(s): {', '.join(missing)}")

    raw = obj["raw"]
    if not isinstance(raw, str):
        raise OrderShapeError(f"`raw` is a {type(raw).__name__}, expected a hex string")
    try:
        blob = bytes.fromhex(raw)
    except ValueError as exc:
        raise OrderShapeError(f"`raw` is not valid hex: {exc}")
    if len(blob) != ORDER_FRAME_BYTES:
        raise OrderShapeError(
            f"`raw` is {len(blob)} byte(s), expected {ORDER_FRAME_BYTES}")

    n = obj["n"]
    if not isinstance(n, int) or isinstance(n, bool):
        raise OrderShapeError(f"`n` is a {type(n).__name__}, expected an integer")
    return (n, blob)


def _read_lines(path: str) -> Iterator[str]:
    with open(path, "r") as f:
        for line in f:
            line = line.strip()
            if line:
                yield line


def _bad_line(which: str, index: int, raw: str, reason: str, compared: int) -> dict:
    detail = {
        "index": index,
        "n": None,
        "reason": f"{which} order line {reason}",
        "golden": raw if which == "golden" else None,
        "rtl": raw if which == "rtl" else None,
    }
    return {"compared": compared, "mismatches": 1,
            "first_mismatch": detail, "matched_before_first": compared,
            "reports": [detail]}


def compare_files(golden_path: str, rtl_path: str, max_report: int = 5) -> dict:
    """Compare two order-stream files line by line.

    Returns a summary dict: compared, mismatches, first_mismatch (or None),
    reports, and matched_before_first (orders that matched *before* the first
    divergence). Comparison continues past the first divergence up to
    `max_report` of them, so an isolated slip is distinguishable from a
    systemic one.
    """
    golden = _read_lines(golden_path)
    rtl = _read_lines(rtl_path)

    compared = 0
    mismatches = 0
    first_mismatch = None
    matched_before_first = 0
    reports = []

    index = 0
    while True:
        g_raw = next(golden, None)
        r_raw = next(rtl, None)

        if g_raw is None and r_raw is None:
            break

        if g_raw is None or r_raw is None:
            mismatches += 1
            which = "golden" if g_raw is None else "rtl"
            detail = {
                "index": index,
                "n": None,
                "reason": f"{which} order stream ended early",
                "golden": g_raw,
                "rtl": r_raw,
            }
            if first_mismatch is None:
                first_mismatch = detail
                matched_before_first = compared
            reports.append(detail)
            break

        for which, raw in (("golden", g_raw), ("rtl", r_raw)):
            try:
                obj = _normalize(json.loads(raw))
            except OrderShapeError as exc:
                return _bad_line(which, index, raw, f"has a bad shape ({exc})", compared)
            except ValueError as exc:
                return _bad_line(which, index, raw,
                                 f"is not valid JSON ({exc}) -- truncated file?", compared)
            if which == "golden":
                g_obj = obj
            else:
                r_obj = obj

        if g_obj != r_obj:
            mismatches += 1
            reason = "ordinal mismatch" if g_obj[0] != r_obj[0] else "frame mismatch"
            detail = {"index": index, "n": g_obj[0], "reason": reason,
                      "golden": g_raw, "rtl": r_raw}
            if first_mismatch is None:
                first_mismatch = detail
                matched_before_first = compared
            if len(reports) < max_report:
                reports.append(detail)
            if mismatches >= max_report:
                break
        else:
            compared += 1

        index += 1

    return {
        "compared": compared,
        "mismatches": mismatches,
        "first_mismatch": first_mismatch,
        "matched_before_first": matched_before_first,
        "reports": reports,
    }


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Compare a golden OUCH order stream against an RTL replay order stream.")
    parser.add_argument("golden", help="Golden orders .jsonl (model.dump_trace --orders-out)")
    parser.add_argument("rtl", help="RTL orders .jsonl (from tb/replay)")
    parser.add_argument("--max-report", type=int, default=5,
                        help="Stop after reporting this many mismatches (default 5)")
    parser.add_argument("--min-orders", type=int, default=0, metavar="N",
                        help="Fail if fewer than N orders matched -- a non-vacuity "
                             "gate, so two empty streams cannot pass (default 0)")
    args = parser.parse_args(argv)

    try:
        result = compare_files(args.golden, args.rtl, max_report=args.max_report)
    except OSError as exc:
        print(f"compare_orders: {exc}", file=sys.stderr)
        return 1

    if result["mismatches"] == 0:
        if result["compared"] < args.min_orders:
            print(f"VACUOUS: only {result['compared']} order(s) matched, "
                  f"--min-orders requires at least {args.min_orders}. "
                  f"A run that compares (almost) nothing proves nothing -- check "
                  f"that both order streams were actually produced.", file=sys.stderr)
            return 1
        print(f"MATCH: {result['compared']} orders identical "
              f"(ordinal + {ORDER_FRAME_BYTES}-byte OUCH frame)")
        return 0

    print(f"MISMATCH: {result['mismatches']} divergence(s); first after "
          f"{result['matched_before_first']} matching orders "
          f"({result['compared']} matched in total)", file=sys.stderr)
    for rep in result["reports"]:
        at = f" (msg ordinal {rep['n']})" if rep["n"] is not None else ""
        print(f"  order #{rep['index']}{at} ({rep['reason']}):", file=sys.stderr)
        print(f"    golden: {rep['golden']}", file=sys.stderr)
        print(f"    rtl   : {rep['rtl']}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
