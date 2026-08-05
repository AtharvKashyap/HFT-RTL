"""Python golden-model parser for Nasdaq TotalView-ITCH 5.0 messages.

Only the fields needed to drive/verify the top-8 price-level order book are
decoded. Multi-byte fields are big-endian on the wire.
"""

import struct
from dataclasses import dataclass

_HDR_LEN = 11  # type[1] + stock_locate[2] + tracking[2] + timestamp[6]


@dataclass(frozen=True)
class DecodedMsg:
    kind: str  # "ADD", "EXEC", "CANCEL", "DELETE", "REPLACE", "SYSTEM"
    order_id: int = 0
    new_order_id: int = 0
    side: str = ""  # "B" / "S", ADD only
    shares: int = 0
    price: int = 0
    symbol: str = ""  # 8-char, ADD only; empty otherwise


def _decode_add(body: bytes) -> DecodedMsg:
    order_id, side, shares, symbol, price = struct.unpack('>QcI8sI', body[:25])
    return DecodedMsg(
        kind="ADD",
        order_id=order_id,
        side=side.decode('ascii'),
        shares=shares,
        symbol=symbol.decode('ascii'),
        price=price,
    )


def _decode_exec(body: bytes) -> DecodedMsg:
    order_id, shares = struct.unpack('>QI', body[:12])
    return DecodedMsg(kind="EXEC", order_id=order_id, shares=shares)


def _decode_cancel(body: bytes) -> DecodedMsg:
    order_id, shares = struct.unpack('>QI', body[:12])
    return DecodedMsg(kind="CANCEL", order_id=order_id, shares=shares)


def _decode_delete(body: bytes) -> DecodedMsg:
    (order_id,) = struct.unpack('>Q', body[:8])
    return DecodedMsg(kind="DELETE", order_id=order_id)


def _decode_replace(body: bytes) -> DecodedMsg:
    order_id, new_order_id, shares, price = struct.unpack('>QQII', body[:24])
    return DecodedMsg(
        kind="REPLACE",
        order_id=order_id,
        new_order_id=new_order_id,
        shares=shares,
        price=price,
    )


def _decode_system(body: bytes) -> DecodedMsg:
    return DecodedMsg(kind="SYSTEM")


# type byte -> (total payload length incl. common header, decoder(body_after_header))
LAYOUTS = {
    b'S': (12, _decode_system),
    b'A': (36, _decode_add),
    b'F': (40, _decode_add),
    b'E': (31, _decode_exec),
    b'C': (36, _decode_exec),
    b'X': (23, _decode_cancel),
    b'D': (19, _decode_delete),
    b'U': (35, _decode_replace),
}


def parse_message(payload: bytes) -> DecodedMsg | None:
    if len(payload) < 1:
        return None
    msg_type = payload[:1]
    entry = LAYOUTS.get(msg_type)
    if entry is None:
        return None
    expected_len, decoder = entry
    if len(payload) != expected_len:
        return None
    return decoder(payload[_HDR_LEN:])
