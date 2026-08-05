"""Tests for the MoldUDP64 packet wrapper (model/moldwrap.py)."""

import struct

from model.moldwrap import MoldWriter, wrap


def parse_stream(data: bytes):
    """Walk a concatenated MoldUDP64 byte stream, returning (packets, messages).

    This is the reader the RTL framer implements in hardware; using it on the
    bytes `--wrap-out` produced is what proves the harness input is well formed.
    """
    packets = []
    messages = []
    offset = 0
    while offset < len(data):
        session, sequence, count = struct.unpack('>10sQH', data[offset:offset + 20])
        offset += 20
        pkt_msgs = []
        for _ in range(count if count not in (0x0000, 0xFFFF) else 0):
            (length,) = struct.unpack('>H', data[offset:offset + 2])
            offset += 2
            pkt_msgs.append(data[offset:offset + length])
            offset += length
        packets.append((session, sequence, count))
        messages.extend(pkt_msgs)
    return packets, messages


def _parse_packet(packet: bytes):
    session, sequence, count = struct.unpack('>10sQH', packet[:20])
    messages = []
    offset = 20
    for _ in range(count if count != 0xFFFF else 0):
        (length,) = struct.unpack('>H', packet[offset:offset + 2])
        offset += 2
        messages.append(packet[offset:offset + length])
        offset += length
    return session, sequence, count, messages


def test_wrap_round_trips_payloads_and_headers():
    messages = [f"msg{i}".encode() for i in range(10)]
    packets = list(wrap(messages, session=b'SESSION001', msgs_per_packet=4))

    # 10 messages / 4 per packet -> 3 data packets + 1 end-of-session packet.
    assert len(packets) == 4

    session0, seq0, count0, msgs0 = _parse_packet(packets[0])
    assert session0 == b'SESSION001'
    assert seq0 == 1
    assert count0 == 4
    assert msgs0 == messages[0:4]

    session1, seq1, count1, msgs1 = _parse_packet(packets[1])
    assert session1 == b'SESSION001'
    assert seq1 == 5
    assert count1 == 4
    assert msgs1 == messages[4:8]

    session2, seq2, count2, msgs2 = _parse_packet(packets[2])
    assert seq2 == 9
    assert count2 == 2
    assert msgs2 == messages[8:10]

    session3, seq3, count3, msgs3 = _parse_packet(packets[3])
    assert session3 == b'SESSION001'
    assert count3 == 0xFFFF


def test_wrap_gap_after_creates_sequence_discontinuity():
    messages = [f"msg{i}".encode() for i in range(10)]
    packets = list(wrap(messages, session=b'SESSION001', msgs_per_packet=4, gap_after=1))

    _, seq0, _, _ = _parse_packet(packets[0])
    _, seq1, _, _ = _parse_packet(packets[1])

    assert seq0 == 1
    # Without the gap, packet 1 would start at seq 5 (1 + 4 msgs). gap_after=1
    # skips a sequence number after the 1st packet, so it starts at seq 6.
    assert seq1 == 6


def test_wrap_start_seq():
    messages = [f"msg{i}".encode() for i in range(4)]
    packets = list(wrap(messages, session=b'SESSION001', msgs_per_packet=4, start_seq=100))

    _, seq0, _, _ = _parse_packet(packets[0])
    assert seq0 == 100


def test_wrap_ends_with_end_of_session_packet():
    messages = [b'x']
    packets = list(wrap(messages, session=b'SESSION001', msgs_per_packet=4))

    last_session, last_seq, last_count, _ = _parse_packet(packets[-1])
    assert last_count == 0xFFFF
    assert last_session == b'SESSION001'


def test_wrap_session_padded_or_truncated_to_10_bytes():
    packets = list(wrap([b'x'], session=b'SESSION001', msgs_per_packet=4))
    session, _, _, _ = _parse_packet(packets[0])
    assert len(session) == 10


def test_mold_writer_stream_round_trips(tmp_path):
    messages = [bytes([0x41]) + bytes(i % 256 for i in range(30 + (i % 5)))
                for i in range(37)]
    path = tmp_path / "stream.mold"
    with open(path, 'wb') as f:
        writer = MoldWriter(f, session=b'SESSION001', msgs_per_packet=8)
        for m in messages:
            writer.add(m)
        writer.close()

    packets, parsed = parse_stream(path.read_bytes())

    # Every message comes back byte-identical, in order.
    assert parsed == messages
    assert writer.messages == len(messages)
    # 37 messages / 8 = 4 full + 1 partial + 1 end-of-session trailer.
    assert len(packets) == 6
    assert writer.packets == 6
    assert packets[-1][2] == 0xFFFF

    # Sequence numbers advance by the message count of each data packet, which
    # is what mold_framer's gap detector predicts.
    counts = [c for _, _, c in packets[:-1]]
    seqs = [s for _, s, _ in packets]
    expected = 1
    for i, c in enumerate(counts):
        assert seqs[i] == expected
        expected += c
    assert seqs[-1] == expected  # end-of-session packet carries the next sequence


def test_mold_writer_matches_wrap_bytes(tmp_path):
    """MoldWriter and wrap() must produce identical bytes for the same input."""
    messages = [f"msg{i}".encode() for i in range(10)]
    path = tmp_path / "stream.mold"
    with open(path, 'wb') as f:
        writer = MoldWriter(f, session=b'SESSION001', msgs_per_packet=4)
        for m in messages:
            writer.add(m)
        writer.close()

    assert path.read_bytes() == b''.join(wrap(messages, session=b'SESSION001',
                                              msgs_per_packet=4))
