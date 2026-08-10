"""Golden OUCH 4.2 Enter Order encoder.

Encodes a fixed-format Enter Order message per the wire layout in the
project's global context (2B big-endian length = 49, then the 49-byte
Enter Order body). Symbols are space-padded to 8 characters in __init__,
matching the convention used by model/book.py's MarketModel.
"""

import struct


class OuchEncoder:
    """Builds OUCH 4.2 Enter Order wire frames with an incrementing token."""

    def __init__(self, symbols: list):
        self.symbols = [sym.ljust(8) for sym in symbols]
        self._counter = 0

    @property
    def order_count(self) -> int:
        return self._counter

    def encode(self, symbol_idx: int, side: str, shares: int, price: int) -> bytes:
        token = ("HFTRTL" + format(self._counter, "08X")).encode("ascii")
        self._counter += 1

        stock = self.symbols[symbol_idx].encode("ascii")

        msg = b"".join([
            b"O",
            token,
            side.encode("ascii"),
            struct.pack(">I", shares),
            stock,
            struct.pack(">I", price),
            struct.pack(">I", 0),      # TIF: IOC
            b"HFTR",                   # firm
            b"Y",                      # display
            b"P",                      # capacity
            b"N",                      # ISO
            struct.pack(">I", 0),      # min qty
            b"N",                      # cross type
            b"R",                      # customer type
        ])

        assert len(msg) == 49
        return struct.pack(">H", 49) + msg
