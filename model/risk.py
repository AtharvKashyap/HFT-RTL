"""Python golden pre-trade risk gate.

Implements the per-symbol pre-trade risk checks. Consumes intents from the
strategy (model/strategy.py), each carrying bid0/ask0 sideband. Checks run
in a fixed order that is a hard contract (an RTL risk_gate module mirrors
this exactly), and exactly one reject counter increments per rejection --
the counter for the FIRST failing check:

1. sanity: reject unless bid0 != 0 and ask0 != 0 and bid0 < ask0.
2. collar: mid = (bid0+ask0)>>1; reject if |price-mid| > (mid>>collar_shift).
3. rate: reject if fewer than min_order_spacing book updates (any symbol)
   have been observed since the last ACCEPTED order. The updates counter
   increments on every on_update() and resets to 0 on accept.
4. position: signed pos[symbol] += (+shares if buy else -shares), applied
   only on accept; reject if the post-trade |pos| would exceed
   max_position.
"""


class RiskGate:
    """Per-symbol pre-trade risk gate."""

    def __init__(self, num_symbols: int, max_position: int = 1000,
                 min_order_spacing: int = 10, collar_shift: int = 3):
        self.num_symbols = num_symbols
        self.max_position = max_position
        self.min_order_spacing = min_order_spacing
        self.collar_shift = collar_shift

        self.pos = [0] * num_symbols
        self.updates_since_accept = 0

        self.accept_count = 0
        self.sanity_reject_count = 0
        self.collar_reject_count = 0
        self.rate_reject_count = 0
        self.pos_reject_count = 0

    def on_update(self):
        self.updates_since_accept += 1

    def on_intent(self, intent: dict) -> bool:
        idx = intent["symbol_idx"]
        side = intent["side"]
        shares = intent["shares"]
        price = intent["price"]
        bid0 = intent["bid0"]
        ask0 = intent["ask0"]

        if not (bid0 != 0 and ask0 != 0 and bid0 < ask0):
            self.sanity_reject_count += 1
            return False

        mid = (bid0 + ask0) >> 1
        band = mid >> self.collar_shift
        if abs(price - mid) > band:
            self.collar_reject_count += 1
            return False

        if self.updates_since_accept < self.min_order_spacing:
            self.rate_reject_count += 1
            return False

        delta = shares if side == "B" else -shares
        new_pos = self.pos[idx] + delta
        if abs(new_pos) > self.max_position:
            self.pos_reject_count += 1
            return False

        self.pos[idx] = new_pos
        self.updates_since_accept = 0
        self.accept_count += 1
        return True
