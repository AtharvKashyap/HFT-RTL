"""Golden trace dumper CLI.

Runs a Nasdaq BinaryFILE ITCH capture through the Python golden MarketModel
and writes one JSON line per book-update event, for later comparison against
RTL simulation output.

Usage:
    python -m model.dump_trace <capture> --symbols AAPL,MSFT,... \
        [--limit N] --out trace.jsonl [--wrap-out stream.mold]

`--wrap-out` additionally writes the exact same message sequence, MoldUDP64
wrapped, so the RTL replay harness (tb/replay) consumes byte-identical input.
Because the wrapper is fed inside the same loop that feeds the model, the two
can never drift: message ordinal `n` in the trace is the ordinal of the same
message in the wrapped stream.
"""

import argparse
import json
import sys

from model.binaryfile import read_messages
from model.book import MarketModel
from model.itch import parse_message
from model.moldwrap import MoldWriter


def dump_trace(capture_path: str, symbols: list, out_path: str,
                limit: int | None = None, wrap_out: str | None = None,
                msgs_per_packet: int = 16) -> dict:
    model = MarketModel(symbols)
    messages = 0
    updates = 0

    wrap_file = open(wrap_out, 'wb') if wrap_out else None
    writer = MoldWriter(wrap_file, msgs_per_packet=msgs_per_packet) if wrap_file else None

    try:
        with open(out_path, 'w') as out:
            # n is the ordinal over ALL messages read (tracked or not), so RTL
            # comparison can align on ordinal even for dropped/unknown messages.
            for n, payload in enumerate(read_messages(capture_path, limit=limit)):
                messages = n + 1
                if writer is not None:
                    writer.add(payload)
                msg = parse_message(payload)
                if msg is None:
                    continue
                events = model.on_message(msg)
                for ev in events:
                    line = {
                        "n": n,
                        "symbol_idx": ev["symbol_idx"],
                        "bid": [[p, s] for p, s in ev["bid"]],
                        "ask": [[p, s] for p, s in ev["ask"]],
                    }
                    out.write(json.dumps(line) + "\n")
                    updates += 1
    finally:
        if writer is not None:
            writer.close()
        if wrap_file is not None:
            wrap_file.close()

    summary = {"messages": messages, "updates": updates, "drops": model.drop_count}
    if writer is not None:
        summary["wrapped_messages"] = writer.messages
        summary["wrapped_packets"] = writer.packets
    return summary


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Dump a golden order-book trace from an ITCH capture.")
    parser.add_argument("capture", help="Path to a BinaryFILE ITCH capture (.gz supported)")
    parser.add_argument("--symbols", required=True, help="Comma-separated list of symbols, e.g. AAPL,MSFT")
    parser.add_argument("--limit", type=int, default=None, help="Max number of messages to read")
    parser.add_argument("--out", required=True, help="Output .jsonl path")
    parser.add_argument("--wrap-out", default=None,
                        help="Also write the consumed messages as a MoldUDP64 byte stream "
                             "(byte-identical input for the RTL replay harness)")
    parser.add_argument("--msgs-per-packet", type=int, default=16,
                        help="Messages per MoldUDP64 packet in --wrap-out (default 16)")
    args = parser.parse_args(argv)

    symbols = [s.strip() for s in args.symbols.split(",") if s.strip()]
    summary = dump_trace(args.capture, symbols, args.out, limit=args.limit,
                         wrap_out=args.wrap_out,
                         msgs_per_packet=args.msgs_per_packet)

    extra = ""
    if "wrapped_messages" in summary:
        extra = (f" wrapped_messages={summary['wrapped_messages']}"
                 f" wrapped_packets={summary['wrapped_packets']}")
    print(
        f"messages={summary['messages']} updates={summary['updates']} "
        f"drops={summary['drops']}{extra}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
