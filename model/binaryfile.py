"""Reader for Nasdaq BinaryFILE ITCH captures.

BinaryFILE format is a flat sequence of {2-byte big-endian length, message}
records with no MoldUDP64 framing (see global-context.md). Transparently
supports gzip-compressed captures (`.gz`).
"""

import gzip
import struct
from typing import Iterator

_LEN_HDR = struct.Struct('>H')


def read_messages(path: str, limit: int | None = None) -> Iterator[bytes]:
    opener = gzip.open if path.endswith('.gz') else open
    with opener(path, 'rb') as f:
        count = 0
        while limit is None or count < limit:
            hdr = f.read(2)
            if len(hdr) < 2:
                break
            (length,) = _LEN_HDR.unpack(hdr)
            payload = f.read(length)
            if len(payload) < length:
                break
            yield payload
            count += 1
