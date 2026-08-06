"""Tests for the golden-vs-RTL trace comparator (model/compare_traces.py).

The comparator's job in the replay flow is narrow and must be exact: two JSONL
traces line up 1:1, every field is compared except the ones that are legitimately
implementation-specific (`lat`, the RTL harness's cycle latency, and `timestamp`,
the RTL's free-running cycle counter). Exit code 0 == identical, 1 == divergence.
"""

import json

from model.compare_traces import compare_files, main


def _line(n, symbol_idx=0, bid0=(100, 10), ask0=(101, 20), **extra):
    line = {
        "n": n,
        "symbol_idx": symbol_idx,
        "bid": [list(bid0)] + [[0, 0]] * 7,
        "ask": [list(ask0)] + [[0, 0]] * 7,
    }
    line.update(extra)
    return json.dumps(line)


def _write(path, lines):
    path.write_text("".join(l + "\n" for l in lines))
    return str(path)


def test_identical_traces_match(tmp_path):
    golden = _write(tmp_path / "golden.jsonl", [_line(0), _line(1), _line(5)])
    # RTL trace carries the extra lat/timestamp fields, which must be ignored.
    rtl = _write(tmp_path / "rtl.jsonl", [
        _line(0, lat=4, timestamp=1234),
        _line(1, lat=7, timestamp=1290),
        _line(5, lat=5, timestamp=1400),
    ])

    result = compare_files(golden, rtl)
    assert result["mismatches"] == 0
    assert result["compared"] == 3
    assert main([golden, rtl]) == 0


def test_single_differing_share_count_is_caught(tmp_path):
    golden = _write(tmp_path / "golden.jsonl", [_line(0), _line(1), _line(2)])
    rtl = _write(tmp_path / "rtl.jsonl", [
        _line(0, lat=4),
        _line(1, bid0=(100, 11), lat=4),   # share count differs by one
        _line(2, lat=4),
    ])

    result = compare_files(golden, rtl)
    assert result["mismatches"] == 1
    assert result["first_mismatch"]["index"] == 1
    assert main([golden, rtl]) == 1


def test_differing_ordinal_is_caught(tmp_path):
    golden = _write(tmp_path / "golden.jsonl", [_line(0), _line(1)])
    rtl = _write(tmp_path / "rtl.jsonl", [_line(0), _line(2)])

    assert main([golden, rtl]) == 1


def test_differing_symbol_index_is_caught(tmp_path):
    golden = _write(tmp_path / "golden.jsonl", [_line(0, symbol_idx=3)])
    rtl = _write(tmp_path / "rtl.jsonl", [_line(0, symbol_idx=4)])

    assert main([golden, rtl]) == 1


def test_length_mismatch_is_caught(tmp_path):
    golden = _write(tmp_path / "golden.jsonl", [_line(0), _line(1), _line(2)])
    short = _write(tmp_path / "rtl.jsonl", [_line(0), _line(1)])

    assert main([golden, short]) == 1
    # ...and in the other direction (RTL emitted an extra update).
    assert main([short, golden]) == 1


def test_truncated_trace_reports_cleanly(tmp_path):
    """A producer killed mid-write leaves a half line; that must be a reported
    divergence with an ordinal, not a JSONDecodeError traceback."""
    golden = _write(tmp_path / "golden.jsonl", [_line(0), _line(1)])
    truncated = tmp_path / "rtl.jsonl"
    truncated.write_text(_line(0) + "\n" + _line(1)[:40])

    result = compare_files(golden, str(truncated))
    assert result["mismatches"] == 1
    assert result["first_mismatch"]["index"] == 1
    assert "not valid JSON" in result["first_mismatch"]["reason"]
    assert main([golden, str(truncated)]) == 1


def test_deeper_level_difference_is_caught(tmp_path):
    g = json.loads(_line(0))
    r = json.loads(_line(0))
    r["ask"][4] = [999, 1]
    golden = _write(tmp_path / "golden.jsonl", [json.dumps(g)])
    rtl = _write(tmp_path / "rtl.jsonl", [json.dumps(r)])

    assert main([golden, rtl]) == 1
