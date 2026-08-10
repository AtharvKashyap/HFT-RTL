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
from model.ouch import OuchEncoder
from model.risk import RiskGate
from model.strategy import Strategy


def dump_trace(capture_path: str, symbols: list, out_path: str,
                limit: int | None = None, wrap_out: str | None = None,
                msgs_per_packet: int = 16, orders_out: str | None = None,
                thresh_log2: int = 2, cooldown_updates: int = 16,
                order_shares: int = 100, max_position: int = 1000,
                min_order_spacing: int = 10, collar_shift: int = 3) -> dict:
    model = MarketModel(symbols)
    messages = 0
    updates = 0

    strategy = None
    risk = None
    ouch = None
    if orders_out is not None:
        strategy = Strategy(len(symbols), thresh_log2=thresh_log2,
                            cooldown_updates=cooldown_updates,
                            order_shares=order_shares)
        risk = RiskGate(len(symbols), max_position=max_position,
                        min_order_spacing=min_order_spacing,
                        collar_shift=collar_shift)
        ouch = OuchEncoder(symbols)

    wrap_file = open(wrap_out, 'wb') if wrap_out else None
    writer = MoldWriter(wrap_file, msgs_per_packet=msgs_per_packet) if wrap_file else None
    orders_file = open(orders_out, 'w') if orders_out else None

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

                    if orders_file is not None:
                        # Hard contract: risk.on_update() for an event fires
                        # BEFORE strategy.on_update()/risk.on_intent() for
                        # that same event (mirrors the 1-cycle RTL pipeline).
                        risk.on_update()
                        intent = strategy.on_update(ev)
                        if intent is not None and risk.on_intent(intent):
                            raw = ouch.encode(intent["symbol_idx"], intent["side"],
                                              intent["shares"], intent["price"])
                            token = raw[3:17].decode("ascii")
                            order_line = {
                                "n": n,
                                "token": token,
                                "side": intent["side"],
                                "symbol_idx": intent["symbol_idx"],
                                "shares": intent["shares"],
                                "price": intent["price"],
                                "raw": raw.hex(),
                            }
                            orders_file.write(json.dumps(order_line) + "\n")
    finally:
        if writer is not None:
            writer.close()
        if wrap_file is not None:
            wrap_file.close()
        if orders_file is not None:
            orders_file.close()

    summary = {"messages": messages, "updates": updates, "drops": model.drop_count}
    if writer is not None:
        summary["wrapped_messages"] = writer.messages
        summary["wrapped_packets"] = writer.packets
    if orders_out is not None:
        summary["intents"] = strategy.intent_count
        summary["accepts"] = risk.accept_count
        summary["sanity_rejects"] = risk.sanity_reject_count
        summary["collar_rejects"] = risk.collar_reject_count
        summary["rate_rejects"] = risk.rate_reject_count
        summary["pos_rejects"] = risk.pos_reject_count
        summary["orders"] = ouch.order_count
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
    parser.add_argument("--orders-out", default=None,
                        help="Also run strategy/risk/ouch on the trace and write one "
                             "JSONL order line per accepted, encoded order")
    parser.add_argument("--thresh-log2", type=int, default=2,
                        help="Strategy imbalance threshold shift (default 2)")
    parser.add_argument("--cooldown", type=int, default=16,
                        help="Strategy cooldown in updates (default 16)")
    parser.add_argument("--order-shares", type=int, default=100,
                        help="Shares per strategy order (default 100)")
    parser.add_argument("--max-position", type=int, default=1000,
                        help="Risk gate max absolute position (default 1000)")
    parser.add_argument("--min-spacing", type=int, default=10,
                        help="Risk gate min order spacing in updates (default 10)")
    parser.add_argument("--collar-shift", type=int, default=3,
                        help="Risk gate price collar shift (default 3)")
    args = parser.parse_args(argv)

    symbols = [s.strip() for s in args.symbols.split(",") if s.strip()]
    summary = dump_trace(args.capture, symbols, args.out, limit=args.limit,
                         wrap_out=args.wrap_out,
                         msgs_per_packet=args.msgs_per_packet,
                         orders_out=args.orders_out,
                         thresh_log2=args.thresh_log2,
                         cooldown_updates=args.cooldown,
                         order_shares=args.order_shares,
                         max_position=args.max_position,
                         min_order_spacing=args.min_spacing,
                         collar_shift=args.collar_shift)

    extra = ""
    if "wrapped_messages" in summary:
        extra = (f" wrapped_messages={summary['wrapped_messages']}"
                 f" wrapped_packets={summary['wrapped_packets']}")
    if "orders" in summary:
        extra += (
            f" intents={summary['intents']} accepts={summary['accepts']} "
            f"rejects=sanity:{summary['sanity_rejects']}/collar:{summary['collar_rejects']}"
            f"/rate:{summary['rate_rejects']}/pos:{summary['pos_rejects']} "
            f"orders={summary['orders']}"
        )
    print(
        f"messages={summary['messages']} updates={summary['updates']} "
        f"drops={summary['drops']}{extra}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
