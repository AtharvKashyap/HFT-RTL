import struct

from model.ouch import OuchEncoder


def test_first_order_frame_bytes():
    enc = OuchEncoder(["AAPL", "MSFT"])
    frame = enc.encode(1, "B", 100, 1805000)
    assert len(frame) == 51
    assert frame[:2] == struct.pack(">H", 49)
    msg = frame[2:]
    assert msg[0:1] == b"O"
    assert msg[1:15] == b"HFTRTL00000000"
    assert msg[15:16] == b"B"
    assert struct.unpack(">I", msg[16:20])[0] == 100
    assert msg[20:28] == b"MSFT    "
    assert struct.unpack(">I", msg[28:32])[0] == 1805000
    assert struct.unpack(">I", msg[32:36])[0] == 0        # TIF IOC
    assert msg[36:40] == b"HFTR"
    assert msg[40:43] == b"YPN"
    assert struct.unpack(">I", msg[43:47])[0] == 0        # min qty
    assert msg[47:49] == b"NR"


def test_token_increments_and_is_hex():
    enc = OuchEncoder(["AAPL"])
    enc.encode(0, "S", 100, 1)
    f2 = enc.encode(0, "B", 100, 1)
    assert f2[2:][1:15] == b"HFTRTL00000001"
    assert enc.order_count == 2
