"""Tests for the golden-vs-RTL order-stream comparator (model/compare_orders.py).

The order comparator's contract is narrower than the book comparator's: the two
JSONL order streams line up 1:1, and for each pair only two things are compared
-- the message ordinal `n` and the OUCH frame `raw` (hex, byte for byte). The
golden side carries decoded convenience fields (token, side, symbol_idx, shares,
price) that are already fully determined by `raw`, and the RTL side carries
`lat`; neither is part of the comparison.

Exit code 0 == identical, 1 == divergence, and `--min-orders N` is the
non-vacuity gate, because two empty order streams trivially "match".
"""

import json

from model.compare_orders import compare_files, main

def _hex(seed: int) -> str:
    """A distinct but well-formed frame per seed.

    A 51-byte OUCH 4.2 Enter Order frame is 102 hex characters; the comparator
    shape-checks that length, so the fixtures must honour it.
    """
    return "004f" + f"{seed:02x}" + "aa" * 48


def _golden(n, raw=None, **extra):
    line = {
        "n": n,
        "token": "HFTRTL00000000",
        "side": "B",
        "symbol_idx": 0,
        "shares": 100,
        "price": 1000,
        "raw": raw if raw is not None else _hex(n),
    }
    line.update(extra)
    return json.dumps(line)


def _rtl(n, raw=None, lat=7):
    return json.dumps({"n": n, "raw": raw if raw is not None else _hex(n),
                       "lat": lat})


def _write(path, lines):
    path.write_text("".join(l + "\n" for l in lines))
    return str(path)


def test_identical_order_streams_match(tmp_path):
    golden = _write(tmp_path / "g.jsonl", [_golden(3), _golden(9), _golden(42)])
    rtl = _write(tmp_path / "r.jsonl",
                 [_rtl(3, lat=6), _rtl(9, lat=7), _rtl(42, lat=6)])

    result = compare_files(golden, rtl)
    assert result["mismatches"] == 0
    assert result["compared"] == 3
    assert main([golden, rtl]) == 0


def test_single_differing_hex_byte_is_caught(tmp_path):
    good = _hex(9)
    bad = good[:20] + ("0" if good[20] != "0" else "1") + good[21:]
    assert len(bad) == len(good) and bad != good

    golden = _write(tmp_path / "g.jsonl", [_golden(3), _golden(9), _golden(42)])
    rtl = _write(tmp_path / "r.jsonl",
                 [_rtl(3), _rtl(9, raw=bad), _rtl(42)])

    result = compare_files(golden, rtl)
    assert result["mismatches"] == 1
    assert result["first_mismatch"]["index"] == 1
    # The report must name the ordinal of the offending order, not just its
    # position in the file.
    assert result["first_mismatch"]["n"] == 9
    assert main([golden, rtl]) == 1


def test_differing_ordinal_is_caught(tmp_path):
    golden = _write(tmp_path / "g.jsonl", [_golden(3), _golden(9)])
    rtl = _write(tmp_path / "r.jsonl", [_rtl(3), _rtl(10, raw=_hex(9))])

    result = compare_files(golden, rtl)
    assert result["mismatches"] == 1
    assert result["first_mismatch"]["index"] == 1
    assert main([golden, rtl]) == 1


def test_length_mismatch_is_caught(tmp_path):
    golden = _write(tmp_path / "g.jsonl", [_golden(1), _golden(2), _golden(3)])
    short = _write(tmp_path / "r.jsonl", [_rtl(1), _rtl(2)])

    assert main([golden, short]) == 1
    # ...and in the other direction (RTL emitted an extra order).
    assert main([short, golden]) == 1


def test_hex_case_is_not_a_difference(tmp_path):
    """`raw` is compared as bytes, so an upper-case producer still matches."""
    golden = _write(tmp_path / "g.jsonl", [_golden(1)])
    rtl = _write(tmp_path / "r.jsonl", [_rtl(1, raw=_hex(1).upper())])

    assert compare_files(golden, rtl)["mismatches"] == 0
    assert main([golden, rtl]) == 0


def test_below_min_orders_is_vacuous(tmp_path):
    golden = _write(tmp_path / "g.jsonl", [_golden(1), _golden(2)])
    rtl = _write(tmp_path / "r.jsonl", [_rtl(1), _rtl(2)])

    assert main([golden, rtl, "--min-orders", "2"]) == 0
    assert main([golden, rtl, "--min-orders", "3"]) == 1


def test_empty_streams_fail_the_non_vacuity_gate(tmp_path, capsys):
    golden = _write(tmp_path / "g.jsonl", [])
    rtl = _write(tmp_path / "r.jsonl", [])

    result = compare_files(golden, rtl)
    assert result["mismatches"] == 0 and result["compared"] == 0
    assert main([golden, rtl]) == 0                       # no gate: vacuous pass
    assert main([golden, rtl, "--min-orders", "1"]) == 1  # gate catches it
    assert "VACUOUS" in capsys.readouterr().err


def test_truncated_stream_reports_cleanly(tmp_path):
    golden = _write(tmp_path / "g.jsonl", [_golden(1), _golden(2)])
    truncated = tmp_path / "r.jsonl"
    truncated.write_text(_rtl(1) + "\n" + _rtl(2)[:30])

    result = compare_files(golden, str(truncated))
    assert result["mismatches"] == 1
    assert "not valid JSON" in result["first_mismatch"]["reason"]
    assert main([golden, str(truncated)]) == 1


def test_missing_required_field_is_caught(tmp_path):
    stub = json.dumps({"n": 1})
    golden = _write(tmp_path / "g.jsonl", [stub])
    rtl = _write(tmp_path / "r.jsonl", [stub])

    result = compare_files(golden, str(rtl))
    assert result["mismatches"] == 1
    assert "raw" in result["first_mismatch"]["reason"]
    assert main([golden, rtl]) == 1


def test_short_frame_fails_even_when_both_sides_agree(tmp_path):
    """A truncated frame must not pass just because both sides are equally
    truncated -- the 51-byte frame length is part of the contract."""
    stub = json.dumps({"n": 1, "raw": "004faabb"})
    golden = _write(tmp_path / "g.jsonl", [stub])
    rtl = _write(tmp_path / "r.jsonl", [stub])

    result = compare_files(golden, rtl)
    assert result["mismatches"] == 1
    assert "bad shape" in result["first_mismatch"]["reason"]
    assert main([golden, rtl]) == 1


def test_non_hex_raw_is_caught(tmp_path):
    stub = json.dumps({"n": 1, "raw": "zz" * 51})
    golden = _write(tmp_path / "g.jsonl", [_golden(1)])
    rtl = _write(tmp_path / "r.jsonl", [stub])

    result = compare_files(golden, rtl)
    assert result["mismatches"] == 1
    assert "bad shape" in result["first_mismatch"]["reason"]
    assert main([golden, rtl]) == 1


def test_max_report_bounds_the_output(tmp_path):
    golden = _write(tmp_path / "g.jsonl", [_golden(i) for i in range(10)])
    rtl = _write(tmp_path / "r.jsonl",
                 [_rtl(i, raw=_hex(i + 100)) for i in range(10)])

    result = compare_files(golden, rtl, max_report=3)
    assert result["mismatches"] == 3
    assert len(result["reports"]) == 3
