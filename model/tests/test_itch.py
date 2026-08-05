import struct

from model.itch import parse_message


def _hdr(t):
    return t + struct.pack('>HH6s', 1, 0, b'\x00' * 6)


def test_add_order():
    payload = _hdr(b'A') + struct.pack('>QcI8sI', 42, b'B', 100, b'AAPL    ', 1805000)
    m = parse_message(payload)
    assert m.kind == "ADD" and m.order_id == 42 and m.side == "B"
    assert m.shares == 100 and m.symbol == "AAPL    " and m.price == 1805000


def test_add_order_with_mpid():
    # 'F' decodes the same as 'A', plus a 4-byte attribution field that is ignored.
    payload = _hdr(b'F') + struct.pack('>QcI8sI4s', 7, b'S', 200, b'MSFT    ', 3210000, b'MPID')
    m = parse_message(payload)
    assert m.kind == "ADD" and m.order_id == 7 and m.side == "S"
    assert m.shares == 200 and m.symbol == "MSFT    " and m.price == 3210000


def test_executed():
    payload = _hdr(b'E') + struct.pack('>QI8s', 42, 30, b'\x00' * 8)
    m = parse_message(payload)
    assert m.kind == "EXEC" and m.order_id == 42 and m.shares == 30


def test_executed_with_price():
    payload = _hdr(b'C') + struct.pack('>QI8sBI', 42, 30, b'\x00' * 8, 0, 1805000)
    m = parse_message(payload)
    assert m.kind == "EXEC" and m.order_id == 42 and m.shares == 30


def test_cancel():
    payload = _hdr(b'X') + struct.pack('>QI', 42, 25)
    m = parse_message(payload)
    assert m.kind == "CANCEL" and m.order_id == 42 and m.shares == 25


def test_delete():
    payload = _hdr(b'D') + struct.pack('>Q', 42)
    m = parse_message(payload)
    assert m.kind == "DELETE" and m.order_id == 42


def test_replace():
    payload = _hdr(b'U') + struct.pack('>QQII', 42, 43, 50, 1804000)
    m = parse_message(payload)
    assert m.kind == "REPLACE" and m.order_id == 42 and m.new_order_id == 43
    assert m.shares == 50 and m.price == 1804000


def test_system_event():
    payload = _hdr(b'S') + struct.pack('>c', b'O')
    m = parse_message(payload)
    assert m.kind == "SYSTEM"


def test_unknown_type_returns_none():
    assert parse_message(_hdr(b'P') + b'\x00' * 33) is None


def test_truncated_payload_returns_none():
    # 'A' should be 36 bytes total; truncate it.
    payload = (_hdr(b'A') + struct.pack('>QcI8sI', 42, b'B', 100, b'AAPL    ', 1805000))[:-1]
    assert parse_message(payload) is None
