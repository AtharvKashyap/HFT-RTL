"""Python golden weighted-imbalance strategy.

Implements the per-symbol weighted-imbalance state machine and buy/sell
intent generation per the verbatim "Strategy/risk semantics" contract in
the project's global context:

- Masses per update: B = sum(bid_shares[i] >> i), A = sum(ask_shares[i] >> i).
- Per-symbol state in {NEUTRAL, LONG, SHORT}: LONG iff B > (A << THRESH_LOG2);
  SHORT iff A > (B << THRESH_LOG2); else NEUTRAL. Strict >.
- Edge rule: fire buy on entering LONG from any non-LONG state; sell on
  entering SHORT from any non-SHORT state. Staying never fires. State
  updates even when firing is suppressed.
- Cooldown: after a fired intent for symbol s, suppress firing for s until
  COOLDOWN_UPDATES further updates of s observed. The state machine keeps
  running during cooldown.
- Intent: buy price=ask_price[0], sell price=bid_price[0], shares=
  ORDER_SHARES; no intent if the priced side's level-0 price is 0. Intent
  carries sideband bid0/ask0 (level-0 prices).
"""

NEUTRAL = "NEUTRAL"
LONG = "LONG"
SHORT = "SHORT"


class Strategy:
    """Per-symbol weighted-imbalance state machine and intent generator."""

    def __init__(self, num_symbols: int, thresh_log2: int = 2,
                 cooldown_updates: int = 16, order_shares: int = 100):
        self.num_symbols = num_symbols
        self.thresh_log2 = thresh_log2
        self.cooldown_updates = cooldown_updates
        self.order_shares = order_shares

        self.state = [NEUTRAL] * num_symbols
        # None -> no cooldown active for this symbol. Otherwise the number
        # of further updates of this symbol observed since it last fired.
        self.updates_since_fire = [None] * num_symbols

        self.intent_count = 0

    def on_update(self, ev: dict) -> dict | None:
        idx = ev["symbol_idx"]
        bid = ev["bid"]
        ask = ev["ask"]

        mass_b = sum(sh >> i for i, (_, sh) in enumerate(bid))
        mass_a = sum(sh >> i for i, (_, sh) in enumerate(ask))

        old_state = self.state[idx]
        if mass_b > (mass_a << self.thresh_log2):
            new_state = LONG
        elif mass_a > (mass_b << self.thresh_log2):
            new_state = SHORT
        else:
            new_state = NEUTRAL

        fire_buy = new_state == LONG and old_state != LONG
        fire_sell = new_state == SHORT and old_state != SHORT

        self.state[idx] = new_state

        suppressed = (self.updates_since_fire[idx] is not None and
                      self.updates_since_fire[idx] < self.cooldown_updates)

        intent = None
        if (fire_buy or fire_sell) and not suppressed:
            bid0_px, _ = bid[0]
            ask0_px, _ = ask[0]
            if fire_buy and ask0_px != 0:
                intent = {"symbol_idx": idx, "side": "B",
                          "shares": self.order_shares, "price": ask0_px,
                          "bid0": bid0_px, "ask0": ask0_px}
            elif fire_sell and bid0_px != 0:
                intent = {"symbol_idx": idx, "side": "S",
                          "shares": self.order_shares, "price": bid0_px,
                          "bid0": bid0_px, "ask0": ask0_px}

        if intent is not None:
            self.intent_count += 1
            self.updates_since_fire[idx] = 0
        elif self.updates_since_fire[idx] is not None:
            self.updates_since_fire[idx] += 1
            if self.updates_since_fire[idx] >= self.cooldown_updates:
                self.updates_since_fire[idx] = None

        return intent
