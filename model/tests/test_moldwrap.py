"""Tests for the MoldUDP64 packet wrapper (model/moldwrap.py)."""

import struct

from model.moldwrap import wrap


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
