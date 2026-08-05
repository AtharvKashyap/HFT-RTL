"""Golden trace dumper CLI.

Runs a Nasdaq BinaryFILE ITCH capture through the Python golden MarketModel
and writes one JSON line per book-update event, for later comparison against
RTL simulation output.

Usage:
    python -m model.dump_trace <capture> --symbols AAPL,MSFT,... \
        [--limit N] --out trace.jsonl
"""

import argparse
import json
import sys

from model.binaryfile import read_messages
from model.book import MarketModel
from model.itch import parse_message


def dump_trace(capture_path: str, symbols: list, out_path: str,
                limit: int | None = None) -> dict:
    model = MarketModel(symbols)
    messages = 0
    updates = 0

    with open(out_path, 'w') as out:
        # n is the ordinal over ALL messages read (tracked or not), so RTL
        # comparison can align on ordinal even for dropped/unknown messages.
        for n, payload in enumerate(read_messages(capture_path, limit=limit)):
            messages = n + 1
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

    return {"messages": messages, "updates": updates, "drops": model.drop_count}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Dump a golden order-book trace from an ITCH capture.")
    parser.add_argument("capture", help="Path to a BinaryFILE ITCH capture (.gz supported)")
    parser.add_argument("--symbols", required=True, help="Comma-separated list of symbols, e.g. AAPL,MSFT")
    parser.add_argument("--limit", type=int, default=None, help="Max number of messages to read")
    parser.add_argument("--out", required=True, help="Output .jsonl path")
    args = parser.parse_args(argv)

    symbols = [s.strip() for s in args.symbols.split(",") if s.strip()]
    summary = dump_trace(args.capture, symbols, args.out, limit=args.limit)

    print(
        f"messages={summary['messages']} updates={summary['updates']} drops={summary['drops']}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
