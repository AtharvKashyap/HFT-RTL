"""Tests for the Python golden weighted-imbalance strategy (model/strategy.py).

Per the verbatim "Strategy/risk semantics" contract in global-context.md:
- Masses per update: B = sum(bid_shares[i] >> i), A = sum(ask_shares[i] >> i).
- LONG iff B > (A << THRESH_LOG2); SHORT iff A > (B << THRESH_LOG2); else NEUTRAL.
- Fire buy on entering LONG from any non-LONG state; sell on entering SHORT
  from any non-SHORT state. Staying never fires. State updates even when
  firing is suppressed.
- Cooldown: after a fired intent for symbol s, suppress firing for s until
  COOLDOWN_UPDATES further updates of s observed.
- No intent if the priced side's level-0 price is 0.
"""

from model.strategy import Strategy


def _ev(idx, bid, ask):
    pad = lambda lv: (lv + [(0, 0)] * 8)[:8]
    return {"symbol_idx": idx, "bid": pad(bid), "ask": pad(ask)}


def test_fires_buy_on_exact_threshold_crossing():
    s = Strategy(2)
    # B = 500, A = 124: A<<2 = 496 < 500 -> LONG, fires
    ev = _ev(0, [(1000, 500)], [(1010, 124)])
    it = s.on_update(ev)
    assert it == {"symbol_idx": 0, "side": "B", "shares": 100,
                  "price": 1010, "bid0": 1000, "ask0": 1010}


def test_no_fire_at_boundary_equal():
    s = Strategy(2)
    # B = 496 == A<<2 -> not LONG (strict >)
    assert s.on_update(_ev(0, [(1000, 496)], [(1010, 124)])) is None


def test_weights_halve_per_level():
    s = Strategy(2)
    # bid: 100 @L0 + 800 @L1 -> mass 100 + 400 = 500; ask 124 -> fires
    it = s.on_update(_ev(0, [(1000, 100), (999, 800)], [(1010, 124)]))
    assert it is not None and it["side"] == "B"


def test_staying_long_does_not_refire():
    # cooldown disabled so this isolates the edge rule from cooldown suppression.
    s = Strategy(2, cooldown_updates=0)
    it1 = s.on_update(_ev(0, [(1000, 500)], [(1010, 124)]))
    assert it1 is not None and it1["side"] == "B"
    # still LONG (B=600 > A<<2=496) -> no edge -> no fire
    it2 = s.on_update(_ev(0, [(1000, 600)], [(1010, 124)]))
    assert it2 is None


def test_refire_after_passing_through_neutral():
    s = Strategy(2, cooldown_updates=0)
    it1 = s.on_update(_ev(0, [(1000, 500)], [(1010, 124)]))
    assert it1 is not None and it1["side"] == "B"
    # NEUTRAL: B=100, A=100 -> 100 > 400 false both ways
    it2 = s.on_update(_ev(0, [(1000, 100)], [(1010, 100)]))
    assert it2 is None
    # LONG again, entering from NEUTRAL -> fires
    it3 = s.on_update(_ev(0, [(1000, 500)], [(1010, 124)]))
    assert it3 is not None and it3["side"] == "B"


def test_direct_long_to_short_flip_fires_sell():
    s = Strategy(2, cooldown_updates=0)
    it1 = s.on_update(_ev(0, [(1000, 500)], [(1010, 124)]))
    assert it1 is not None and it1["side"] == "B"
    # SHORT: B=100, A=500 -> A(500) > B<<2(400) -> SHORT, direct flip from LONG
    it2 = s.on_update(_ev(0, [(1000, 100)], [(1010, 500)]))
    assert it2 == {"symbol_idx": 0, "side": "S", "shares": 100,
                   "price": 1000, "bid0": 1000, "ask0": 1010}


def test_cooldown_blocks_fires_for_symbol_but_not_another():
    s = Strategy(2)  # default cooldown_updates=16
    # symbol 0: LONG fires
    it1 = s.on_update(_ev(0, [(1000, 500)], [(1010, 124)]))
    assert it1 is not None
    # symbol 0: NEUTRAL (no edge anyway)
    it2 = s.on_update(_ev(0, [(1000, 100)], [(1010, 100)]))
    assert it2 is None
    # symbol 0: LONG again, a real edge (NEUTRAL->LONG) but within cooldown -> suppressed
    it3 = s.on_update(_ev(0, [(1000, 500)], [(1010, 124)]))
    assert it3 is None
    # symbol 1: unaffected by symbol 0's cooldown -> fires normally
    it4 = s.on_update(_ev(1, [(1000, 500)], [(1010, 124)]))
    assert it4 is not None and it4["symbol_idx"] == 1 and it4["side"] == "B"


def test_state_tracks_during_cooldown_without_refiring_after_expiry():
    # LONG entered while suppressed by cooldown must not fire later just
    # because the cooldown window expires -- only a fresh edge fires.
    s = Strategy(2, cooldown_updates=2)
    it1 = s.on_update(_ev(0, [(1000, 500)], [(1010, 124)]))
    assert it1 is not None  # fires, cooldown counter starts (0 further updates observed)
    it2 = s.on_update(_ev(0, [(1000, 100)], [(1010, 100)]))  # NEUTRAL; 1st further update
    assert it2 is None
    it3 = s.on_update(_ev(0, [(1000, 500)], [(1010, 124)]))  # LONG edge; 2nd further update
    assert it3 is None  # still within cooldown (COOLDOWN_UPDATES=2) -> suppressed
    it4 = s.on_update(_ev(0, [(1000, 500)], [(1010, 124)]))  # cooldown now expired
    assert it4 is None  # but state is already LONG (no edge) -> no fire


def test_empty_ask_side_suppresses_buy_intent():
    s = Strategy(2, cooldown_updates=0)
    # A=0 -> B(500) > A<<2(0) -> LONG, but ask0 price is 0 -> intent suppressed
    it = s.on_update(_ev(0, [(1000, 500)], [(0, 0)]))
    assert it is None


def test_integer_right_shift_semantics_on_odd_shares():
    s = Strategy(2)
    # bid level1 shares=3 -> weight 3>>1 = 1 (floor, not 1.5/ceil-2).
    # B = 0 (L0) + 1 (L1) = 1; A = 5 -> SHORT iff A > B<<2 i.e. 5 > 4 -> True.
    # If the shift were not a true floor (e.g. rounded up to 2), B<<2 = 8 and
    # 5 > 8 would be False, so this discriminates the exact semantics.
    it = s.on_update(_ev(0, [(1000, 0), (999, 3)], [(1010, 5)]))
    assert it == {"symbol_idx": 0, "side": "S", "shares": 100,
                  "price": 1000, "bid0": 1000, "ask0": 1010}


def test_intent_count_increments_only_on_fired_intents():
    s = Strategy(2, cooldown_updates=0)
    assert s.intent_count == 0
    s.on_update(_ev(0, [(1000, 500)], [(1010, 124)]))  # fires (LONG)
    assert s.intent_count == 1
    s.on_update(_ev(0, [(1000, 600)], [(1010, 124)]))  # staying LONG, no fire
    assert s.intent_count == 1
    s.on_update(_ev(0, [(1000, 100)], [(1010, 500)]))  # SHORT flip, fires
    assert s.intent_count == 2
