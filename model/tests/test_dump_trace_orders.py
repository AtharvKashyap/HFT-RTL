"""Tests for --orders-out order emission in model/dump_trace.py.

Builds a synthetic capture that forces the strategy to fire: a big bid ADD
followed by a small ask ADD for the same symbol drives the second update
into LONG with both sides nonzero, so a buy intent fires on entering LONG,
passes the risk gate (first order, first update, no position), and gets
OUCH-encoded.
"""

import json
import struct

from model.dump_trace import dump_trace


def _hdr(t):
    return t + struct.pack('>HH6s', 1, 0, b'\x00' * 6)


def _add(order_id, side, shares, symbol, price):
    return _hdr(b'A') + struct.pack('>QcI8sI', order_id, side.encode(), shares,
                                     symbol.encode(), price)


def _record(payload: bytes) -> bytes:
    return struct.pack('>H', len(payload)) + payload


def test_dump_trace_orders_out_emits_order_on_fire(tmp_path):
    # Filler updates on a second symbol (MSFT) pad the risk gate's global
    # order-spacing counter past min_order_spacing (default 10) before the
    # AAPL trigger fires, without touching AAPL's strategy state.
    filler = [_add(100 + i, 'B', 1, 'MSFT    ', 2000000) for i in range(10)]
    messages = filler + [
        # Small ask first: A=10, B=0 -> enters SHORT, but sell intent is
        # suppressed since bid0 == 0 (no bid yet).
        _add(1, 'S', 10, 'AAPL    ', 1510000),
        # Big bid: B=10000, A=10 -> B > (A << 2) so state flips SHORT -> LONG,
        # firing a buy intent with both bid0/ask0 nonzero.
        _add(2, 'B', 10000, 'AAPL    ', 1500000),
    ]
    capture = tmp_path / "synthetic.bin"
    capture.write_bytes(b''.join(_record(m) for m in messages))

    out_path = tmp_path / "trace.jsonl"
    orders_path = tmp_path / "orders.jsonl"
    summary = dump_trace(str(capture), ["AAPL", "MSFT"], str(out_path),
                         orders_out=str(orders_path))

    assert summary["intents"] >= 1
    assert summary["orders"] >= 1

    lines = orders_path.read_text().strip().split("\n")
    assert len(lines) >= 1

    order = json.loads(lines[0])
    assert order["n"] == len(filler) + 1  # triggering message ordinal (the second AAPL ADD)
    assert order["side"] == "B"
    assert order["symbol_idx"] == 0
    assert order["shares"] == 100  # default ORDER_SHARES
    assert order["price"] == 1510000  # ask0 (level-0 ask price) at time of fire

    raw = bytes.fromhex(order["raw"])
    assert len(raw) == 51
    assert order["token"] == "HFTRTL00000000"
    assert raw[3:9] == b"HFTRTL"
