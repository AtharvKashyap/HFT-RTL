"""Tests for the golden trace dumper CLI (model/dump_trace.py), using a
synthetic BinaryFILE capture built from raw ITCH-format bytes (no dependency
on real Nasdaq sample data)."""

import json
import struct

from model.dump_trace import dump_trace


def _hdr(t):
    return t + struct.pack('>HH6s', 1, 0, b'\x00' * 6)


def _add(order_id, side, shares, symbol, price):
    return _hdr(b'A') + struct.pack('>QcI8sI', order_id, side.encode(), shares,
                                     symbol.encode(), price)


def _delete(order_id):
    return _hdr(b'D') + struct.pack('>Q', order_id)


def _record(payload: bytes) -> bytes:
    return struct.pack('>H', len(payload)) + payload


def test_dump_trace_synthetic_capture(tmp_path):
    messages = [
        _add(1, 'B', 100, 'AAPL    ', 1500000),   # bid update for AAPL
        _add(2, 'S', 50, 'AAPL    ', 1510000),    # ask update for AAPL
        _add(3, 'B', 200, 'MSFT    ', 3000000),   # bid update for MSFT
        b'Z' + b'\x00' * 10,                       # unknown type, length matches nothing -> dropped
        _delete(1),                                # removes AAPL bid
    ]
    capture = tmp_path / "synthetic.bin"
    capture.write_bytes(b''.join(_record(m) for m in messages))

    out_path = tmp_path / "trace.jsonl"
    summary = dump_trace(str(capture), ["AAPL", "MSFT"], str(out_path))

    assert summary["messages"] == 5
    assert summary["updates"] == 4  # 3 adds + 1 delete each produced a snapshot
    assert summary["drops"] == 0    # unknown 'Z' type is unparsed, not a "drop"

    lines = out_path.read_text().strip().split("\n")
    assert len(lines) == 4

    first = json.loads(lines[0])
    assert first["n"] == 0
    assert first["symbol_idx"] == 0  # AAPL
    assert first["bid"][0] == [1500000, 100]
    assert first["ask"][0] == [0, 0]

    second = json.loads(lines[1])
    assert second["n"] == 1
    assert second["symbol_idx"] == 0
    assert second["bid"][0] == [1500000, 100]
    assert second["ask"][0] == [1510000, 50]
    # Sanity: best bid below best ask.
    assert second["bid"][0][0] < second["ask"][0][0]

    third = json.loads(lines[2])
    assert third["n"] == 2
    assert third["symbol_idx"] == 1  # MSFT

    fourth = json.loads(lines[3])
    assert fourth["n"] == 4  # ordinal counts the unknown message too
    assert fourth["bid"][0] == [0, 0]  # AAPL bid removed by delete


def test_dump_trace_wrap_out_matches_consumed_messages(tmp_path):
    """--wrap-out must reproduce exactly the messages the model consumed, in order.

    This is the guarantee the RTL replay harness relies on: the ordinal `n` in
    the golden trace indexes the same message the DUT sees at that position in
    the wrapped stream.
    """
    from model.tests.test_moldwrap import parse_stream

    messages = [
        _add(1, 'B', 100, 'AAPL    ', 1500000),
        _add(2, 'S', 50, 'AAPL    ', 1510000),
        _add(3, 'B', 200, 'MSFT    ', 3000000),
        b'Z' + b'\x00' * 10,   # unknown type: still part of the byte stream
        _delete(1),
    ]
    capture = tmp_path / "synthetic.bin"
    capture.write_bytes(b''.join(_record(m) for m in messages))

    out_path = tmp_path / "trace.jsonl"
    wrap_path = tmp_path / "stream.mold"
    summary = dump_trace(str(capture), ["AAPL", "MSFT"], str(out_path),
                         wrap_out=str(wrap_path), msgs_per_packet=2)

    assert summary["wrapped_messages"] == 5
    packets, parsed = parse_stream(wrap_path.read_bytes())
    assert parsed == messages          # byte-identical, including the unknown 'Z'
    assert packets[-1][2] == 0xFFFF    # end-of-session trailer present
    # 5 messages at 2 per packet -> 2 full + 1 partial + trailer.
    assert len(packets) == 4


def test_dump_trace_wrap_out_respects_limit(tmp_path):
    from model.tests.test_moldwrap import parse_stream

    messages = [_add(i, 'B', 10 * i, 'AAPL    ', 1500000 + i) for i in range(1, 11)]
    capture = tmp_path / "synthetic.bin"
    capture.write_bytes(b''.join(_record(m) for m in messages))

    wrap_path = tmp_path / "stream.mold"
    summary = dump_trace(str(capture), ["AAPL"], str(tmp_path / "trace.jsonl"),
                         limit=4, wrap_out=str(wrap_path))

    assert summary["messages"] == 4
    assert summary["wrapped_messages"] == 4
    _, parsed = parse_stream(wrap_path.read_bytes())
    assert parsed == messages[:4]
