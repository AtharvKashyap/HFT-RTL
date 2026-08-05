"""Tests for the Python golden order book (model/book.py)."""

from model.itch import DecodedMsg
from model.book import PriceBook, MarketModel


def _add(oid, sym, side, sh, px):
    return DecodedMsg(kind="ADD", order_id=oid, new_order_id=0,
                       side=side, shares=sh, price=px, symbol=sym.ljust(8))


def _exec(oid, sh):
    return DecodedMsg(kind="EXEC", order_id=oid, new_order_id=0,
                       side="", shares=sh, price=0, symbol="")


def _cancel(oid, sh):
    return DecodedMsg(kind="CANCEL", order_id=oid, new_order_id=0,
                       side="", shares=sh, price=0, symbol="")


def _delete(oid):
    return DecodedMsg(kind="DELETE", order_id=oid, new_order_id=0,
                       side="", shares=0, price=0, symbol="")


def _replace(oid, new_oid, sh, px):
    return DecodedMsg(kind="REPLACE", order_id=oid, new_order_id=new_oid,
                       side="", shares=sh, price=px, symbol="")


# ---------------------------------------------------------------------------
# PriceBook unit tests
# ---------------------------------------------------------------------------

def test_add_creates_level():
    b = PriceBook()
    changed = b.add("B", 100, 10)
    assert changed is True
    snap = b.snapshot()
    assert snap["bid"][0] == (100, 10)
    assert snap["bid"][1] == (0, 0)


def test_same_price_add_aggregates():
    b = PriceBook()
    b.add("B", 100, 10)
    b.add("B", 100, 5)
    snap = b.snapshot()
    assert snap["bid"][0] == (100, 15)


def test_bids_sort_descending():
    b = PriceBook()
    b.add("B", 100, 10)
    b.add("B", 300, 5)
    b.add("B", 200, 7)
    snap = b.snapshot()
    assert snap["bid"][:3] == [(300, 5), (200, 7), (100, 10)]


def test_asks_sort_ascending():
    b = PriceBook()
    b.add("S", 300, 5)
    b.add("S", 100, 10)
    b.add("S", 200, 7)
    snap = b.snapshot()
    assert snap["ask"][:3] == [(100, 10), (200, 7), (300, 5)]


def test_ninth_level_evicts_worst():
    b = PriceBook()
    for i in range(8):
        b.add("B", 100 + i, 1)  # prices 100..107, best is 107
    assert b.evict_count == 0
    # add a 9th, better than the current worst (100) -> evicts 100
    b.add("B", 150, 1)
    snap = b.snapshot()
    prices = [p for p, s in snap["bid"]]
    assert 100 not in prices
    assert 150 in prices
    assert b.evict_count == 1


def test_add_worse_than_full_book_worst_is_dropped():
    b = PriceBook()
    for i in range(8):
        b.add("B", 200 + i, 1)  # prices 200..207
    before = b.snapshot()
    changed = b.add("B", 50, 1)  # worse than worst (200)
    assert changed is False
    after = b.snapshot()
    assert before == after
    assert b.evict_count == 1


def test_reduce_to_zero_removes_level_and_shifts():
    b = PriceBook()
    b.add("B", 300, 5)
    b.add("B", 200, 7)
    b.add("B", 100, 10)
    changed = b.reduce("B", 300, 5)
    assert changed is True
    snap = b.snapshot()
    assert snap["bid"][0] == (200, 7)
    assert snap["bid"][1] == (100, 10)
    assert snap["bid"][2] == (0, 0)


def test_reduce_at_unknown_price_counted_as_miss():
    b = PriceBook()
    b.add("B", 100, 10)
    changed = b.reduce("B", 999, 1)
    assert changed is False
    assert b.reduce_miss_count == 1


# ---------------------------------------------------------------------------
# MarketModel integration tests
# ---------------------------------------------------------------------------

def test_exec_reduces_at_resting_price():
    m = MarketModel(["AAPL"])
    m.on_message(_add(1, "AAPL", "B", 100, 1805000))
    ev = m.on_message(_exec(1, 40))
    assert ev[0]["bid"][0] == (1805000, 60)


def test_delete_removes_remaining_shares():
    m = MarketModel(["AAPL"])
    m.on_message(_add(1, "AAPL", "B", 100, 1805000))
    ev = m.on_message(_delete(1))
    assert ev[0]["bid"][0] == (0, 0)
    # order id no longer resolvable
    ev2 = m.on_message(_delete(1))
    assert ev2 == []
    assert m.drop_count == 1


def test_replace_moves_shares_to_new_price_same_symbol():
    m = MarketModel(["AAPL"])
    m.on_message(_add(1, "AAPL", "B", 100, 1805000))
    ev = m.on_message(_replace(1, 2, 50, 1806000))
    # reduce (old) then add (new) -> up to 2 events
    assert len(ev) == 2
    assert ev[0]["bid"][0] == (0, 0)  # old level fully removed
    assert ev[1]["bid"][0] == (1806000, 50)
    # old order_id no longer resolvable
    ev2 = m.on_message(_delete(1))
    assert ev2 == []
    assert m.drop_count == 1
    # new order_id resolvable
    ev3 = m.on_message(_delete(2))
    assert ev3[0]["bid"][0] == (0, 0)


def test_partial_cancel_leaves_remainder_in_table_and_book():
    m = MarketModel(["AAPL"])
    m.on_message(_add(1, "AAPL", "B", 100, 1805000))
    ev = m.on_message(_cancel(1, 30))
    assert ev[0]["bid"][0] == (1805000, 70)
    # remainder still resolvable via table
    ev2 = m.on_message(_delete(1))
    assert ev2[0]["bid"][0] == (0, 0)


def test_untracked_symbol_add_produces_no_update_and_delete_is_drop():
    m = MarketModel(["AAPL"])
    ev = m.on_message(_add(1, "MSFT", "B", 100, 1805000))
    assert ev == []
    assert m.drop_count == 1  # untracked-symbol ADD counted as a drop
    ev2 = m.on_message(_delete(1))
    assert ev2 == []
    assert m.drop_count == 2  # unknown order_id DELETE also counted
