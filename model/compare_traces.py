"""Golden-trace vs RTL-trace comparator.

Both files are JSONL, one line per book update, in the format written by
`model/dump_trace.py` (golden) and `tb/replay/replay_main.cpp` (RTL):

    {"n": <message ordinal>, "symbol_idx": <book index>,
     "bid": [[price, shares] x 8], "ask": [[price, shares] x 8]}

The RTL trace carries one extra field that is deliberately NOT compared: `lat`
(cycles from message boundary to update, a hardware-only measurement).
Everything else -- including the message ordinal `n` and the order of updates --
must be identical, so the two traces must line up 1:1.

Every line is also shape-checked before comparison: the four contract keys must
be present and both level lists must be exactly N_LEVELS deep. Two traces that
agree only because both are empty (or both truncated to stubs) are a vacuous
pass, so `--min-updates N` fails a run that matched fewer than N updates.

Streaming by design: the headline run compares tens of millions of lines, so
neither file is ever loaded into memory.

Usage:
    python -m model.compare_traces golden.jsonl rtl.jsonl [--max-report N]
                                   [--min-updates N]
Exit codes: 0 = identical, 1 = divergence (or unreadable input).
"""

import argparse
import json
import sys
from typing import Iterator

# Fields present only in the RTL trace, or otherwise not part of the contract.
# `timestamp` is NOT here: neither producer emits one.
IGNORED_FIELDS = ("lat",)

# Every trace line must carry exactly these keys (plus any IGNORED_FIELDS)...
REQUIRED_FIELDS = ("n", "symbol_idx", "bid", "ask")
# ...and both level lists must be this deep (book_pkg::N_LEVELS).
N_LEVELS = 8


class TraceShapeError(ValueError):
    """A trace line parsed as JSON but is not a well-formed book update."""


def _normalize(obj: dict) -> dict:
    """Shape-check a line, strip ignored fields, canonicalize the level lists.

    The shape check is what stops a structurally degenerate trace (missing
    keys, short level lists) from comparing equal to an equally degenerate
    counterpart: both sides are checked independently, so agreement on garbage
    is a failure rather than a match.

    JSON gives lists already, but a producer could emit tuples-turned-lists of
    differing nesting; forcing the shape here means a real value difference is
    what fails, not a representation difference.
    """
    if not isinstance(obj, dict):
        raise TraceShapeError(f"line is a {type(obj).__name__}, expected an object")
    missing = [k for k in REQUIRED_FIELDS if k not in obj]
    if missing:
        raise TraceShapeError(f"missing required field(s): {', '.join(missing)}")

    out = {}
    for key, value in obj.items():
        if key in IGNORED_FIELDS:
            continue
        if key in ("bid", "ask"):
            if not isinstance(value, list) or len(value) != N_LEVELS:
                raise TraceShapeError(
                    f"`{key}` has {len(value) if isinstance(value, list) else '?'} "
                    f"levels, expected {N_LEVELS}")
            try:
                out[key] = [[int(p), int(s)] for p, s in value]
            except (TypeError, ValueError) as exc:
                raise TraceShapeError(f"`{key}` is not a list of [price, shares]: {exc}")
        else:
            out[key] = value
    return out


def _read_lines(path: str) -> Iterator[str]:
    with open(path, "r") as f:
        for line in f:
            line = line.strip()
            if line:
                yield line


def _bad_line(which: str, index: int, raw: str, reason: str, compared: int) -> dict:
    detail = {
        "index": index,
        "reason": f"{which} trace line {reason}",
        "golden": raw if which == "golden" else None,
        "rtl": raw if which == "rtl" else None,
    }
    return {"compared": compared, "mismatches": 1,
            "first_mismatch": detail, "matched_before_first": compared,
            "reports": [detail]}


def compare_files(golden_path: str, rtl_path: str, max_report: int = 5) -> dict:
    """Compare two trace files line by line.

    Returns a summary dict: compared, mismatches, first_mismatch (or None),
    reports, and matched_before_first (updates that matched *before* the first
    divergence -- `compared` keeps rising past it, since comparison continues up
    to `max_report` divergences so a bisect run can see whether a divergence is
    isolated or systemic).
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
                "reason": f"{which} trace ended early",
                "golden": g_raw,
                "rtl": r_raw,
            }
            if first_mismatch is None:
                first_mismatch = detail
                matched_before_first = compared
            reports.append(detail)
            break

        # A trace whose last line is truncated means the producer was killed
        # mid-write; report that as a divergence at a known ordinal rather than
        # letting a JSONDecodeError traceback escape after millions of good
        # lines. A well-formed JSON line that is not a well-formed book update
        # (missing keys, short level lists) is reported the same way -- it can
        # never be a legitimate match, even against an identical stub.
        for which, raw in (("golden", g_raw), ("rtl", r_raw)):
            try:
                obj = _normalize(json.loads(raw))
            except TraceShapeError as exc:
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
            detail = {"index": index, "reason": "field mismatch",
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
        description="Compare a golden order-book trace against an RTL replay trace.")
    parser.add_argument("golden", help="Golden trace .jsonl (from model.dump_trace)")
    parser.add_argument("rtl", help="RTL trace .jsonl (from tb/replay)")
    parser.add_argument("--max-report", type=int, default=5,
                        help="Stop after reporting this many mismatches (default 5)")
    parser.add_argument("--min-updates", type=int, default=0, metavar="N",
                        help="Fail if fewer than N updates matched -- a non-vacuity "
                             "gate, so two empty or stub traces cannot pass (default 0)")
    args = parser.parse_args(argv)

    try:
        result = compare_files(args.golden, args.rtl, max_report=args.max_report)
    except OSError as exc:
        print(f"compare_traces: {exc}", file=sys.stderr)
        return 1

    if result["mismatches"] == 0:
        if result["compared"] < args.min_updates:
            print(f"VACUOUS: only {result['compared']} update(s) matched, "
                  f"--min-updates requires at least {args.min_updates}. "
                  f"A run that compares (almost) nothing proves nothing -- check "
                  f"that both traces were actually produced.", file=sys.stderr)
            return 1
        print(f"MATCH: {result['compared']} updates identical "
              f"(ignoring {', '.join(IGNORED_FIELDS)})")
        return 0

    print(f"MISMATCH: {result['mismatches']} divergence(s); first after "
          f"{result['matched_before_first']} matching updates "
          f"({result['compared']} matched in total)", file=sys.stderr)
    for rep in result["reports"]:
        print(f"  update #{rep['index']} ({rep['reason']}):", file=sys.stderr)
        print(f"    golden: {rep['golden']}", file=sys.stderr)
        print(f"    rtl   : {rep['rtl']}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
