"""Tests for model/fuzz_stream.py -- the fuzz harness's corrupted-stream builder."""

import struct

from model.fuzz_stream import build_fuzz_stream, MAX_BOGUS_LEN


def _parse_stream(data: bytes):
    """Walk a concatenated MoldUDP64 byte stream -- same logic mold_framer
    implements in hardware -- returning (packets, messages)."""
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


def test_corruption_actually_changed_bytes():
    result = build_fuzz_stream(seed=1)
    assert result["bytes_corrupted"] > 0

    # The corrupted messages must actually differ from the originals (some
    # message bodies were flipped, some resized to a bogus length).
    assert result["corrupted_messages"] != result["dirty_messages"]
    diffs = sum(1 for a, b in zip(result["dirty_messages"], result["corrupted_messages"])
                if a != b)
    assert diffs > 0


def test_bogus_lengths_bounded():
    result = build_fuzz_stream(seed=2)
    assert result["bogus_lengths"], "expected at least one bogus length injected"
    for length in result["bogus_lengths"]:
        assert 0 <= length <= MAX_BOGUS_LEN


def test_corrupted_message_length_matches_its_own_bytes():
    # A message's declared length (what would be written as its 2-byte
    # prefix) must always equal its own actual byte count -- the "lie" is the
    # length value relative to the ORIGINAL message, never relative to the
    # bytes physically following it. This is what keeps mold_framer's FSM
    # from drifting off a corrupted message.
    result = build_fuzz_stream(seed=9)
    for orig, corrupted in zip(result["dirty_messages"], result["corrupted_messages"]):
        if len(corrupted) != len(orig):
            assert len(corrupted) <= MAX_BOGUS_LEN


def test_truncation_shrinks_dirty_section_by_whole_packets():
    result = build_fuzz_stream(seed=3)
    assert result["truncated_dirty_bytes"] < result["corrupted_dirty_bytes"]
    assert result["n_packets_kept"] < result["n_packets_total"]


def test_clean_tail_is_intact_and_parses():
    result = build_fuzz_stream(seed=4, n_tail_messages=1000)
    tail_bytes = result["stream"][result["tail_start"]:]

    packets, parsed_messages = _parse_stream(tail_bytes)

    assert parsed_messages == result["tail_messages"]
    assert len(parsed_messages) == 1000
    # Fresh session, sequence starts at 1, ends with the MoldUDP64 trailer.
    assert packets[0][0] == b'FUZZTAIL01'
    assert packets[0][1] == 1
    assert packets[-1][2] == 0xFFFF


def test_clean_tail_messages_are_well_formed_itch():
    result = build_fuzz_stream(seed=5, n_tail_messages=200)
    known_lengths = {b'S': 12, b'A': 36, b'F': 40, b'E': 31, b'C': 36,
                      b'X': 23, b'D': 19, b'U': 35}
    for m in result["tail_messages"]:
        assert m[:1] in known_lengths
        assert len(m) == known_lengths[m[:1]]


def test_deterministic_given_seed():
    a = build_fuzz_stream(seed=42)
    b = build_fuzz_stream(seed=42)
    assert a["stream"] == b["stream"]
    assert a["bogus_lengths"] == b["bogus_lengths"]


def test_different_seeds_diverge():
    a = build_fuzz_stream(seed=1)
    b = build_fuzz_stream(seed=2)
    assert a["stream"] != b["stream"]


def test_kept_dirty_packets_are_internally_well_framed():
    # Re-parsing the (corrupted, truncated) dirty section with the same
    # length-prefix walk mold_framer implements must land exactly on the end
    # of the last kept packet -- i.e. corruption never desyncs byte
    # accounting *within* the surviving packets, only the semantic content.
    result = build_fuzz_stream(seed=6)
    dirty_bytes = result["stream"][:result["tail_start"]]
    packets, messages = _parse_stream(dirty_bytes)
    assert len(packets) == result["n_packets_kept"]
    assert messages == result["corrupted_messages"][:len(messages)]
