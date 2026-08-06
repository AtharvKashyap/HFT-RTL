"""Tests for the golden-vs-RTL trace comparator (model/compare_traces.py).

The comparator's job in the replay flow is narrow and must be exact: two JSONL
traces line up 1:1, every field is compared except the one that is legitimately
implementation-specific (`lat`, the RTL harness's cycle latency). Exit code
0 == identical, 1 == divergence.

Two traces can also agree vacuously -- both empty, or both structurally
degenerate -- so the shape check and the `--min-updates` non-vacuity gate are
tested here as well.
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
    # RTL trace carries the extra `lat` field, which must be ignored.
    rtl = _write(tmp_path / "rtl.jsonl", [
        _line(0, lat=4),
        _line(1, lat=7),
        _line(5, lat=5),
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


def test_empty_traces_fail_the_non_vacuity_gate(tmp_path):
    """Two empty traces trivially "match"; --min-updates must reject that."""
    golden = _write(tmp_path / "golden.jsonl", [])
    rtl = _write(tmp_path / "rtl.jsonl", [])

    result = compare_files(golden, rtl)
    assert result["mismatches"] == 0 and result["compared"] == 0
    assert main([golden, rtl]) == 0                        # no gate: vacuous pass
    assert main([golden, rtl, "--min-updates", "1"]) == 1  # gate catches it


def test_min_updates_passes_when_enough_matched(tmp_path):
    golden = _write(tmp_path / "golden.jsonl", [_line(0), _line(1), _line(2)])
    rtl = _write(tmp_path / "rtl.jsonl", [_line(0), _line(1), _line(2)])

    assert main([golden, rtl, "--min-updates", "3"]) == 0
    assert main([golden, rtl, "--min-updates", "4"]) == 1


def test_short_level_lists_fail_even_when_both_sides_agree(tmp_path):
    """A stub with 4 levels per side must not pass just because both traces
    are equally malformed -- the shape is part of the contract."""
    stub = json.dumps({"n": 0, "symbol_idx": 0,
                       "bid": [[100, 10]] + [[0, 0]] * 3,
                       "ask": [[101, 20]] + [[0, 0]] * 3})
    golden = _write(tmp_path / "golden.jsonl", [stub])
    rtl = _write(tmp_path / "rtl.jsonl", [stub])

    result = compare_files(golden, rtl)
    assert result["mismatches"] == 1
    assert "bad shape" in result["first_mismatch"]["reason"]
    assert "4 levels" in result["first_mismatch"]["reason"]
    assert main([golden, rtl]) == 1


def test_missing_required_field_is_caught(tmp_path):
    stub = json.dumps({"n": 0, "bid": [[0, 0]] * 8, "ask": [[0, 0]] * 8})
    golden = _write(tmp_path / "golden.jsonl", [stub])
    rtl = _write(tmp_path / "rtl.jsonl", [stub])

    result = compare_files(golden, rtl)
    assert result["mismatches"] == 1
    assert "symbol_idx" in result["first_mismatch"]["reason"]
    assert main([golden, rtl]) == 1


def test_deeper_level_difference_is_caught(tmp_path):
    g = json.loads(_line(0))
    r = json.loads(_line(0))
    r["ask"][4] = [999, 1]
    golden = _write(tmp_path / "golden.jsonl", [json.dumps(g)])
    rtl = _write(tmp_path / "rtl.jsonl", [json.dumps(r)])

    assert main([golden, rtl]) == 1
