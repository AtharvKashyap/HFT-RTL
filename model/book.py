"""Python golden order book model.

Implements the top-8 price-level order book (PriceBook) and the multi-symbol
order-ID-tracking wrapper (MarketModel) per the verbatim "Book semantics"
contract in the project's global context:

- Per side: up to `n_levels` (price, shares) levels; bids sorted descending,
  asks ascending; index 0 = best.
- ADD(side, price, shares): existing level -> shares += ; else insert sorted;
  overflow beyond n_levels -> drop worst; worse than a full book's worst ->
  drop the incoming add, count `evict`.
- REDUCE(side, price, shares): find level, shares -= ; <=0 -> remove level
  (shift up); not found -> drop, count `reduce_miss`.
- Emit a full both-side snapshot (zero-padded) after every op that changed
  anything.
"""

from model.itch import DecodedMsg


class PriceBook:
    """Top-N price-level book for a single symbol."""

    def __init__(self, n_levels: int = 8):
        self.n_levels = n_levels
        self.bid = []  # list of [price, shares], sorted descending
        self.ask = []  # list of [price, shares], sorted ascending
        self.evict_count = 0
        self.reduce_miss_count = 0

    def _side_list(self, side: str) -> list:
        return self.bid if side == "B" else self.ask

    def add(self, side: str, price: int, shares: int) -> bool:
        levels = self._side_list(side)
        descending = side == "B"

        for level in levels:
            if level[0] == price:
                level[1] += shares
                return True

        # Book is full and the new price is worse than (or equal to, but
        # equal is handled above) the current worst level -> drop.
        if len(levels) >= self.n_levels:
            worst = levels[-1][0]
            is_worse = (price < worst) if descending else (price > worst)
            if is_worse:
                self.evict_count += 1
                return False

        # Insert in sorted order.
        idx = 0
        while idx < len(levels):
            if descending:
                if price > levels[idx][0]:
                    break
            else:
                if price < levels[idx][0]:
                    break
            idx += 1
        levels.insert(idx, [price, shares])

        if len(levels) > self.n_levels:
            levels.pop()  # drop the new worst level
            self.evict_count += 1

        return True

    def reduce(self, side: str, price: int, shares: int) -> bool:
        levels = self._side_list(side)
        for i, level in enumerate(levels):
            if level[0] == price:
                level[1] -= shares
                if level[1] <= 0:
                    levels.pop(i)
                return True
        self.reduce_miss_count += 1
        return False

    def snapshot(self) -> dict:
        def padded(levels):
            out = [(p, s) for p, s in levels]
            out += [(0, 0)] * (self.n_levels - len(out))
            return out

        return {"bid": padded(self.bid), "ask": padded(self.ask)}


class MarketModel:
    """Owns per-symbol PriceBooks and the resting-order-ID table."""

    def __init__(self, symbols: list, n_levels: int = 8):
        self.n_levels = n_levels
        # DecodedMsg.symbol keeps its 8-char space padding (see model/itch.py);
        # normalize configured symbols the same way so lookups match.
        self.books = {sym.ljust(8): PriceBook(n_levels) for sym in symbols}
        self.symbol_to_idx = {sym.ljust(8): i for i, sym in enumerate(symbols)}
        # order_id -> [symbol, side, price, shares]
        self.orders = {}
        self.drop_count = 0

    def _snapshot_event(self, symbol: str) -> dict:
        snap = self.books[symbol].snapshot()
        return {
            "symbol_idx": self.symbol_to_idx[symbol],
            "bid": snap["bid"],
            "ask": snap["ask"],
        }

    def on_message(self, msg: DecodedMsg) -> list:
        events = []

        if msg.kind == "ADD":
            symbol = msg.symbol
            if symbol not in self.books:
                self.drop_count += 1
                return events
            book = self.books[symbol]
            changed = book.add(msg.side, msg.price, msg.shares)
            self.orders[msg.order_id] = [symbol, msg.side, msg.price, msg.shares]
            if changed:
                events.append(self._snapshot_event(symbol))
            return events

        if msg.kind in ("EXEC", "CANCEL"):
            entry = self.orders.get(msg.order_id)
            if entry is None:
                self.drop_count += 1
                return events
            symbol, side, price, shares = entry
            book = self.books[symbol]
            changed = book.reduce(side, price, msg.shares)
            entry[3] -= msg.shares
            if entry[3] <= 0:
                del self.orders[msg.order_id]
            if changed:
                events.append(self._snapshot_event(symbol))
            return events

        if msg.kind == "DELETE":
            entry = self.orders.pop(msg.order_id, None)
            if entry is None:
                self.drop_count += 1
                return events
            symbol, side, price, shares = entry
            book = self.books[symbol]
            changed = book.reduce(side, price, shares)
            if changed:
                events.append(self._snapshot_event(symbol))
            return events

        if msg.kind == "REPLACE":
            entry = self.orders.pop(msg.order_id, None)
            if entry is None:
                self.drop_count += 1
                return events
            symbol, side, price, shares = entry
            book = self.books[symbol]

            changed = book.reduce(side, price, shares)
            if changed:
                events.append(self._snapshot_event(symbol))

            added = book.add(side, msg.price, msg.shares)
            self.orders[msg.new_order_id] = [symbol, side, msg.price, msg.shares]
            if added:
                events.append(self._snapshot_event(symbol))

            return events

        # SYSTEM or unknown kinds: no-op.
        return events
