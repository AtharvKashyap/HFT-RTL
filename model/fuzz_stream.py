"""Seeded corruption of a wrapped MoldUDP64 byte stream.

Feeds the replay harness's `--fuzz` robustness mode (`tb/replay/replay_main.cpp`).
The design's error-handling contract (global-context.md) is "never fatal: count
+ drop, keep consuming" -- this module manufactures a stream that actually
exercises that contract: a run of otherwise-valid MoldUDP64/ITCH traffic with
in-band corruption injected (byte flips inside message bodies, bogus 2-byte
length prefixes clamped to <= 50, and a truncation cut), followed by a **clean
tail** of `n_tail_messages` valid messages.

RATIONALE for the clean tail using a fresh MoldUDP64 session/sequence (rather
than continuing the corrupted session's sequence numbering): `mold_framer`
treats its whole input as one continuous byte stream, not datagram-bounded --
real MoldUDP64 gets its framing resets for free from UDP packet boundaries,
which this design deliberately does not model (v1 is a byte-serial pipe with
no notion of "packet" independent of what the length fields inside the stream
say). That has a real consequence for this fuzz test's design: if corruption
ever makes the framer mis-consume even one byte too many or too few for a
*message* it is mid-way through, every length field after it is read at the
wrong offset and alignment is lost for good -- there is no sentinel byte to
resynchronize on. So `bytes_corrupted` here targets only whole-message
lengths and message-body content, and every corrupted message is repacked so
its length prefix always matches the bytes actually following it (a length
LIE the decoder will act on, but not a byte-accounting lie the framer's FSM
will act on) -- see `_corrupt_message`. Truncation likewise only ever drops
whole trailing packets, never cuts mid-message: that is what "truncated
packets" means here, and it is also what keeps the cut landing exactly on a
message boundary, so mold_framer's FSM is back in its packet-header state
(ST_SESSION) at the exact byte the clean tail begins -- the same state it is
in at the very start of any run. Given that, the tail's fresh session is not a
special case the harness needs to know about, it is simply the "first packet"
path reached mid-stream, and the large forced discontinuity in the raw
sequence number (the dirty section's sequence vs. the tail's fresh sequence 1)
is exactly what `mold_framer`'s existing `gap_count` mechanism exists to
absorb (sticky counter, resynchronizes off the received sequence -- see
rtl/mold_framer.sv). What is under test is exactly this: a hard sequence
discontinuity plus a burst of nonsense messages beforehand does not stop the
pipeline from decoding and applying whatever comes after correctly. State
equality with a clean-only run is explicitly out of scope (see the task
brief): the claim is liveness and continued correct operation on new input,
not recovery of the same book state that a clean run would have reached.

No inter-packet garbage is ever injected, and no byte is ever inserted: every
corrupted byte is a mutation of a byte a real MoldUDP64/ITCH stream would
already contain (a message-body byte, or the 2-byte length prefix, itself
kept consistent with the physical bytes that follow it -- see above), and
truncation only ever removes whole trailing packets. Nothing is added that
could not, in principle, already be "in the stream" as far as a byte-serial
consumer is concerned.
"""

import argparse
import io
import json
import random
import struct
import sys

from model.moldwrap import MoldWriter

DEFAULT_SYMBOLS = ["AAPL", "MSFT", "SPY", "QQQ", "TSLA", "NVDA", "AMD", "INTC"]

_HDR = struct.Struct('>10sQH')
_LEN = struct.Struct('>H')

MAX_BOGUS_LEN = 50


# --------------------------------------------------------------- ITCH bodies
def _hdr(t: bytes, stock_locate: int = 1, tracking: int = 0, timestamp: bytes = b'\x00' * 6) -> bytes:
    return t + struct.pack('>HH6s', stock_locate, tracking, timestamp)


def _sym8(name: str) -> bytes:
    return name.encode('ascii')[:8].ljust(8, b' ')


def _add(order_id, side, shares, symbol8, price, mpid=False) -> bytes:
    body = struct.pack('>QcI8sI', order_id, side, shares, symbol8, price)
    if mpid:
        return _hdr(b'F') + body + b'MPID'
    return _hdr(b'A') + body


def _exec(order_id, shares) -> bytes:
    return _hdr(b'E') + struct.pack('>QI8s', order_id, shares, b'\x00' * 8)


def _exec_price(order_id, shares, printable, price) -> bytes:
    return _hdr(b'C') + struct.pack('>QI8sBI', order_id, shares, b'\x00' * 8, printable, price)


def _cancel(order_id, shares) -> bytes:
    return _hdr(b'X') + struct.pack('>QI', order_id, shares)


def _delete(order_id) -> bytes:
    return _hdr(b'D') + struct.pack('>Q', order_id)


def _replace(order_id, new_order_id, shares, price) -> bytes:
    return _hdr(b'U') + struct.pack('>QQII', order_id, new_order_id, shares, price)


def _system(event: bytes) -> bytes:
    return _hdr(b'S') + struct.pack('>c', event)


def generate_messages(rng: random.Random, target_count: int, symbols: list) -> list:
    """A plausible, well-formed order-lifecycle ITCH message stream.

    Not semantically checked against the golden model (the fuzz harness does
    not compare book state -- see module docstring), just a realistic mix of
    ADD/EXEC/CANCEL/DELETE/REPLACE/SYSTEM traffic on the tracked symbols so
    ADDs actually reach the price books and produce updates.
    """
    messages = []
    order_id = 1
    while len(messages) < target_count:
        symbol = rng.choice(symbols)
        side = rng.choice((b'B', b'S'))
        price = rng.randrange(1, 100_000) * 100
        shares = rng.randrange(1, 5000)
        oid = order_id
        order_id += 1
        mpid = rng.random() < 0.1
        messages.append(_add(oid, side, shares, _sym8(symbol), price, mpid=mpid))

        follow = rng.random()
        if follow < 0.30:
            messages.append(_delete(oid))
        elif follow < 0.55:
            messages.append(_cancel(oid, rng.randrange(1, shares + 1)))
        elif follow < 0.75:
            ex_shares = rng.randrange(1, shares + 1)
            if rng.random() < 0.5:
                messages.append(_exec(oid, ex_shares))
            else:
                messages.append(_exec_price(oid, ex_shares, rng.randrange(0, 2), price))
        elif follow < 0.85:
            new_oid = order_id
            order_id += 1
            messages.append(_replace(oid, new_oid, rng.randrange(1, 5000),
                                      rng.randrange(1, 100_000) * 100))
        # else: order rests untouched.

        if rng.random() < 0.05:
            messages.append(_system(rng.choice([b'O', b'S', b'Q', b'M', b'E', b'C'])))

    return messages[:target_count]


# ------------------------------------------------------------ packet packing
def pack_packets(messages: list, session: bytes, msgs_per_packet: int, start_seq: int = 1):
    """Pack `messages` into a list of raw MoldUDP64 data packets (no
    end-of-session trailer), one packet (bytes) per list entry.

    Each message contributes exactly `_LEN.pack(len(m)) + m` -- the length
    prefix written is always the length of the bytes actually following it,
    by construction, so packing itself can never desync a byte-serial framer
    regardless of what `m` contains (see `_corrupt_message`, which is what
    makes a message's *declared* length a deliberate lie while keeping the
    physical bytes self-consistent with that lie).
    """
    session = session[:10].ljust(10, b'\x00')
    packets = []
    seq = start_seq
    for i in range(0, len(messages), msgs_per_packet):
        batch = messages[i:i + msgs_per_packet]
        pkt = bytearray(_HDR.pack(session, seq, len(batch)))
        for m in batch:
            pkt += _LEN.pack(len(m))
            pkt += m
        packets.append(bytes(pkt))
        seq += len(batch)
    return packets, seq


def pack_stream(messages: list, session: bytes, msgs_per_packet: int, start_seq: int = 1):
    """Convenience: `pack_packets` concatenated into one contiguous stream."""
    packets, seq = pack_packets(messages, session, msgs_per_packet, start_seq)
    return b''.join(packets), seq


def _corrupt_message(rng: random.Random, msg: bytes, flip_prob: float,
                      bogus_len_prob: float, max_bogus_len: int):
    """Corrupt one message: a body byte flip, and/or a bogus declared length.

    The bogus length is not just written into a length *field* -- the
    message's actual byte content is resized (truncated or padded with extra
    random bytes) to match it, so whatever `pack_packets` writes as the
    length prefix is always physically true of what follows. This is what
    keeps a corrupted message's lie local to itself: mold_framer reads
    exactly the number of bytes it is told to, always lands back on a real
    length-prefix field afterward, and the packet's own message count still
    accounts for it as one message. Without this, a length lie would shift
    every subsequent message in the packet by the (unbounded) difference
    between the lie and the truth -- a real byte-accounting corruption, not
    the "decoder receives a garbled but self-consistent message" corruption
    this fuzz is meant to exercise.

    Returns (corrupted_bytes, n_fields_changed, bogus_len_or_None).
    """
    body = bytearray(msg)
    changed = 0

    if body and rng.random() < flip_prob:
        k = rng.randrange(len(body))
        orig = body[k]
        new = rng.randrange(256)
        while new == orig:
            new = rng.randrange(256)
        body[k] = new
        changed += 1

    bogus_len = None
    if rng.random() < bogus_len_prob:
        bogus_len = rng.randrange(0, max_bogus_len + 1)
        changed += 1
        if bogus_len <= len(body):
            body = body[:bogus_len]
        else:
            body += bytes(rng.randrange(256) for _ in range(bogus_len - len(body)))

    return bytes(body), changed, bogus_len


def build_fuzz_stream(seed: int, symbols: list = None, n_dirty_target: int = 300,
                       n_tail_messages: int = 1000, msgs_per_packet: int = 16) -> dict:
    """Build one seeded fuzzed MoldUDP64 byte stream.

    Layout: [corrupted dirty section, truncated to a random whole number of
    packets][fresh-session clean tail of n_tail_messages valid messages,
    ending with the MoldUDP64 end-of-session trailer]. See the module
    docstring for why the tail starts a fresh session, and why truncation
    only ever drops whole trailing packets.
    """
    rng = random.Random(seed)
    symbols = symbols or DEFAULT_SYMBOLS

    dirty_messages = generate_messages(rng, n_dirty_target, symbols)
    corrupted_messages = []
    n_changed = 0
    bogus_lengths = []
    for m in dirty_messages:
        cm, c, bl = _corrupt_message(rng, m, flip_prob=0.15, bogus_len_prob=0.10,
                                      max_bogus_len=MAX_BOGUS_LEN)
        corrupted_messages.append(cm)
        n_changed += c
        if bl is not None:
            bogus_lengths.append(bl)

    all_packets, _ = pack_packets(corrupted_messages, session=b'FUZZDIRT01',
                                   msgs_per_packet=msgs_per_packet, start_seq=1)
    clean_packets, _ = pack_packets(dirty_messages, session=b'FUZZDIRT01',
                                     msgs_per_packet=msgs_per_packet, start_seq=1)

    # Truncated packet: drop a random suffix of whole packets (keep at least
    # one). Cutting only at a packet boundary keeps mold_framer's FSM in its
    # packet-header state (ST_SESSION) at the exact byte the clean tail
    # begins -- see the module docstring for why a mid-message cut would not.
    n_packets = len(all_packets)
    # Exclusive upper bound: with n_packets > 1, keep is always < n_packets, so
    # truncation always actually removes at least one trailing packet.
    keep = rng.randrange(max(1, n_packets // 2), n_packets) if n_packets > 1 else n_packets
    dirty_buf = b''.join(all_packets[:keep])
    corrupted_buf = b''.join(all_packets)
    clean_buf = b''.join(clean_packets)

    tail_messages = generate_messages(rng, n_tail_messages, symbols)
    tail_io = io.BytesIO()
    writer = MoldWriter(tail_io, session=b'FUZZTAIL01', msgs_per_packet=msgs_per_packet, start_seq=1)
    for m in tail_messages:
        writer.add(m)
    writer.close()
    tail_bytes = tail_io.getvalue()

    stream = dirty_buf + tail_bytes

    return {
        "stream": stream,
        "tail_start": len(dirty_buf),
        "dirty_messages": dirty_messages,
        "corrupted_messages": corrupted_messages,
        "tail_messages": tail_messages,
        "bytes_corrupted": n_changed,
        "bogus_lengths": bogus_lengths,
        "n_packets_total": n_packets,
        "n_packets_kept": keep,
        "clean_dirty_bytes": len(clean_buf),
        "corrupted_dirty_bytes": len(corrupted_buf),
        "truncated_dirty_bytes": len(dirty_buf),
    }


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--seed", type=int, required=True)
    parser.add_argument("--out", required=True, help="Output .mold byte-stream path")
    parser.add_argument("--meta", default=None, help="Optional JSON metadata sidecar path")
    parser.add_argument("--symbols", default=",".join(DEFAULT_SYMBOLS))
    parser.add_argument("--n-dirty", type=int, default=300,
                         help="Approx. message count in the corrupted section before truncation")
    parser.add_argument("--n-tail", type=int, default=1000,
                         help="Exact message count in the clean tail")
    parser.add_argument("--msgs-per-packet", type=int, default=16)
    args = parser.parse_args(argv)

    symbols = [s.strip() for s in args.symbols.split(",") if s.strip()]
    result = build_fuzz_stream(args.seed, symbols=symbols, n_dirty_target=args.n_dirty,
                                n_tail_messages=args.n_tail, msgs_per_packet=args.msgs_per_packet)

    with open(args.out, 'wb') as f:
        f.write(result["stream"])

    meta = {
        "seed": args.seed,
        "tail_start": result["tail_start"],
        "total_bytes": len(result["stream"]),
        "bytes_corrupted": result["bytes_corrupted"],
        "bogus_lengths": result["bogus_lengths"],
        "n_dirty_messages": len(result["dirty_messages"]),
        "n_tail_messages": len(result["tail_messages"]),
    }
    if args.meta:
        with open(args.meta, 'w') as f:
            json.dump(meta, f, indent=2)

    print(f"seed={args.seed} bytes={meta['total_bytes']} tail_start={meta['tail_start']} "
          f"bytes_corrupted={meta['bytes_corrupted']} "
          f"bogus_lengths={len(meta['bogus_lengths'])}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
