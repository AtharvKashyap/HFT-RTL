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


def end_of_session_packet(session: bytes, sequence: int) -> bytes:
    """The count==0xFFFF trailer packet (carries no messages)."""
    return _HDR.pack(session[:10].ljust(10, b'\x00'), sequence, 0xFFFF)


class MoldWriter:
    """Incremental MoldUDP64 writer over a binary file object.

    Same packet layout and sequence arithmetic as `wrap()` (which is a
    generator and therefore awkward to drive from a loop that is also doing
    other work with each message). `model/dump_trace.py --wrap-out` uses this
    to emit the byte stream for the RTL replay harness while simultaneously
    feeding the same messages to the Python model, guaranteeing the two
    consume a byte-identical message sequence.
    """

    def __init__(self, fileobj, session: bytes = b'SESSION001',
                 msgs_per_packet: int = 16, start_seq: int = 1):
        self.f = fileobj
        self.session = session[:10].ljust(10, b'\x00')
        self.msgs_per_packet = msgs_per_packet
        self.seq = start_seq
        self._batch = []
        self.packets = 0
        self.messages = 0

    def _flush(self):
        if not self._batch:
            return
        self.f.write(_pack_packet(self.session, self.seq, self._batch))
        self.seq += len(self._batch)
        self.packets += 1
        self._batch = []

    def add(self, msg: bytes):
        self._batch.append(msg)
        self.messages += 1
        if len(self._batch) == self.msgs_per_packet:
            self._flush()

    def close(self):
        """Flush the partial packet and append the end-of-session packet."""
        self._flush()
        self.f.write(end_of_session_packet(self.session, self.seq))
        self.packets += 1


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
