"""MoldUDP64 packet wrapper.

Packs a stream of raw ITCH message payloads into MoldUDP64 packets per the
layout in global-context.md:

    session[0:9] (10B), sequence[10:17] (8B BE), count[18:19] (2B BE),
    then count x {2B BE length, message}.

count=0x0000 is a heartbeat, count=0xFFFF is end-of-session (no payload).
"""

import struct
from typing import Iterable, Iterator

_HDR = struct.Struct('>10sQH')
_LEN = struct.Struct('>H')


def _pack_packet(session: bytes, sequence: int, messages: list) -> bytes:
    count = len(messages)
    body = b''.join(_LEN.pack(len(m)) + m for m in messages)
    return _HDR.pack(session, sequence, count) + body


def wrap(messages: Iterable[bytes], session: bytes = b'SESSION001',
         msgs_per_packet: int = 4, start_seq: int = 1,
         gap_after: int | None = None) -> Iterator[bytes]:
    session = session[:10].ljust(10, b'\x00')

    seq = start_seq
    batch = []
    packet_idx = 0

    def flush():
        nonlocal batch, seq, packet_idx
        if not batch:
            return
        packet = _pack_packet(session, seq, batch)
        packet_idx += 1
        seq += len(batch)
        if gap_after is not None and packet_idx == gap_after:
            seq += 1  # skip a sequence number to create a discontinuity
        batch = []
        return packet

    for msg in messages:
        batch.append(msg)
        if len(batch) == msgs_per_packet:
            pkt = flush()
            yield pkt

    pkt = flush()
    if pkt is not None:
        yield pkt

    # End-of-session packet: count=0xFFFF, no payload.
    yield _HDR.pack(session, seq, 0xFFFF)
