"""Golden-trace vs RTL-trace comparator.

Both files are JSONL, one line per book update, in the format written by
`model/dump_trace.py` (golden) and `tb/replay/replay_main.cpp` (RTL):

    {"n": <message ordinal>, "symbol_idx": <book index>,
     "bid": [[price, shares] x 8], "ask": [[price, shares] x 8]}

The RTL trace carries two extra fields that are deliberately NOT compared:
`lat` (cycles from message boundary to update, a hardware-only measurement)
and `timestamp` (the DUT's free-running cycle counter, which has no meaning in
the Python model). Everything else -- including the message ordinal `n` and the
order of updates -- must be identical, so the two traces must line up 1:1.

Streaming by design: the headline run compares tens of millions of lines, so
neither file is ever loaded into memory.

Usage:
    python -m model.compare_traces golden.jsonl rtl.jsonl [--max-report N]
Exit codes: 0 = identical, 1 = divergence (or unreadable input).
"""

import argparse
import json
import sys
from typing import Iterator

# Fields present only in the RTL trace, or otherwise not part of the contract.
IGNORED_FIELDS = ("lat", "timestamp")


def _normalize(obj: dict) -> dict:
    """Strip ignored fields and canonicalize level lists to lists-of-lists.

    JSON gives lists already, but a producer could emit tuples-turned-lists of
    differing nesting; forcing the shape here means a real value difference is
    what fails, not a representation difference.
    """
    out = {}
    for key, value in obj.items():
        if key in IGNORED_FIELDS:
            continue
        if key in ("bid", "ask"):
            out[key] = [[int(p), int(s)] for p, s in value]
        else:
            out[key] = value
    return out


def _read_lines(path: str) -> Iterator[str]:
    with open(path, "r") as f:
        for line in f:
            line = line.strip()
            if line:
                yield line


def _unparsable(which: str, index: int, raw: str, exc: Exception, compared: int) -> dict:
    detail = {
        "index": index,
        "reason": f"{which} trace line is not valid JSON ({exc}) -- truncated file?",
        "golden": raw if which == "golden" else None,
        "rtl": raw if which == "rtl" else None,
    }
    return {"compared": compared, "mismatches": 1,
            "first_mismatch": detail, "reports": [detail]}


def compare_files(golden_path: str, rtl_path: str, max_report: int = 5) -> dict:
    """Compare two trace files line by line.

    Returns a summary dict: compared, mismatches, first_mismatch (or None).
    Stops reading at the first mismatch only if `max_report` is reached; it
    keeps counting up to `max_report` reported divergences so a bisect run can
    see whether a divergence is isolated or systemic.
    """
    golden = _read_lines(golden_path)
    rtl = _read_lines(rtl_path)

    compared = 0
    mismatches = 0
    first_mismatch = None
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
                "reason": f"{which} trace ended early",
                "golden": g_raw,
                "rtl": r_raw,
            }
            if first_mismatch is None:
                first_mismatch = detail
            reports.append(detail)
            break

        # A trace whose last line is truncated means the producer was killed
        # mid-write; report that as a divergence at a known ordinal rather than
        # letting a JSONDecodeError traceback escape after millions of good
        # lines.
        try:
            g_obj = _normalize(json.loads(g_raw))
        except ValueError as exc:
            return _unparsable("golden", index, g_raw, exc, compared)
        try:
            r_obj = _normalize(json.loads(r_raw))
        except ValueError as exc:
            return _unparsable("rtl", index, r_raw, exc, compared)

        if g_obj != r_obj:
            mismatches += 1
            detail = {"index": index, "reason": "field mismatch",
                      "golden": g_raw, "rtl": r_raw}
            if first_mismatch is None:
                first_mismatch = detail
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
        "reports": reports,
    }


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Compare a golden order-book trace against an RTL replay trace.")
    parser.add_argument("golden", help="Golden trace .jsonl (from model.dump_trace)")
    parser.add_argument("rtl", help="RTL trace .jsonl (from tb/replay)")
    parser.add_argument("--max-report", type=int, default=5,
                        help="Stop after reporting this many mismatches (default 5)")
    args = parser.parse_args(argv)

    try:
        result = compare_files(args.golden, args.rtl, max_report=args.max_report)
    except OSError as exc:
        print(f"compare_traces: {exc}", file=sys.stderr)
        return 1

    if result["mismatches"] == 0:
        print(f"MATCH: {result['compared']} updates identical "
              f"(ignoring {', '.join(IGNORED_FIELDS)})")
        return 0

    print(f"MISMATCH: {result['mismatches']} divergence(s) after "
          f"{result['compared']} matching updates", file=sys.stderr)
    for rep in result["reports"]:
        print(f"  update #{rep['index']} ({rep['reason']}):", file=sys.stderr)
        print(f"    golden: {rep['golden']}", file=sys.stderr)
        print(f"    rtl   : {rep['rtl']}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
