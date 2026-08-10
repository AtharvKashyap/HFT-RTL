"""Tests for the Python golden pre-trade risk gate (model/risk.py).

Per the verbatim risk-gate semantics contract:
- sanity: reject unless bid0 != 0 and ask0 != 0 and bid0 < ask0.
- collar: mid = (bid0+ask0)>>1; reject if |price-mid| > (mid>>collar_shift).
- rate: reject if fewer than min_order_spacing book updates (any symbol)
  since the last ACCEPTED order; the updates counter increments on every
  on_update(), resets to 0 on accept.
- position: signed pos[symbol] += (+shares if buy else -shares) applied
  only on accept; reject if the post-trade |pos| would exceed max_position.
- Check order is a hard contract: sanity -> collar -> rate -> position.
  Exactly one counter increments per rejection (the first failing check).
"""

from model.risk import RiskGate


def _intent(idx=0, side="B", shares=100, price=1010, bid0=1000, ask0=1010):
    return {"symbol_idx": idx, "side": side, "shares": shares,
            "price": price, "bid0": bid0, "ask0": ask0}


def _warm(g, n=10):
    for _ in range(n):
        g.on_update()


def test_sanity_rejects_crossed_book():
    g = RiskGate(2)
    _warm(g)
    assert not g.on_intent(_intent(bid0=1010, ask0=1000))
    assert g.sanity_reject_count == 1 and g.accept_count == 0


def test_sanity_rejects_zero_bid0():
    g = RiskGate(2)
    _warm(g)
    assert not g.on_intent(_intent(bid0=0, ask0=1010))
    assert g.sanity_reject_count == 1


def test_sanity_rejects_zero_ask0():
    g = RiskGate(2)
    _warm(g)
    assert not g.on_intent(_intent(bid0=1000, ask0=0))
    assert g.sanity_reject_count == 1


def test_collar_boundary():
    g = RiskGate(2)
    _warm(g)
    # mid=(8000+8016)>>1=8008, band=8008>>3=1001 -> |9010-8008|=1002>1001 -> reject
    assert not g.on_intent(_intent(price=9010, bid0=8000, ask0=8016))
    assert g.collar_reject_count == 1
    _warm(g)
    assert g.on_intent(_intent(price=9009, bid0=8000, ask0=8016))  # 1001 == band -> pass (strict >)


def test_rate_resets_only_on_accept():
    g = RiskGate(2)
    _warm(g)
    assert g.on_intent(_intent())            # accept, counter resets
    assert not g.on_intent(_intent())        # 0 updates since accept -> rate reject
    assert g.rate_reject_count == 1


def test_position_accumulates_and_rejects_at_limit():
    g = RiskGate(2, max_position=1000)
    for _ in range(10):
        _warm(g)
        assert g.on_intent(_intent(side="B", shares=100))
    assert g.pos[0] == 1000
    _warm(g)
    assert not g.on_intent(_intent(side="B", shares=100))
    assert g.pos_reject_count == 1
    assert g.pos[0] == 1000  # reject does not change position


def test_sell_offsets_buys():
    g = RiskGate(2, max_position=1000)
    _warm(g)
    assert g.on_intent(_intent(side="B", shares=500))
    assert g.pos[0] == 500
    _warm(g)
    assert g.on_intent(_intent(side="S", shares=200))
    assert g.pos[0] == 300


def test_position_limit_is_per_symbol_independent():
    g = RiskGate(2, max_position=1000)
    for _ in range(10):
        _warm(g)
        assert g.on_intent(_intent(idx=0, side="B", shares=100))
    assert g.pos[0] == 1000
    # symbol 1's position is untouched, so it can still accept
    _warm(g)
    assert g.on_intent(_intent(idx=1, side="B", shares=100))
    assert g.pos[1] == 100
    assert g.pos[0] == 1000


def test_check_order_crossed_book_with_stale_rate_counter_hits_sanity():
    # No warmup at all (rate counter is at 0, which alone would reject on
    # a rate check), but the book is crossed -- sanity must fire first.
    g = RiskGate(2)
    assert not g.on_intent(_intent(bid0=1010, ask0=1000))
    assert g.sanity_reject_count == 1
    assert g.rate_reject_count == 0


def test_reject_changes_neither_position_nor_rate_counter():
    g = RiskGate(2)
    _warm(g)
    assert not g.on_intent(_intent(bid0=1010, ask0=1000))  # sanity reject
    assert g.pos[0] == 0
    # rate counter must be unaffected by the reject: still enough updates
    # accrued from the earlier warmup to accept now.
    assert g.on_intent(_intent())
