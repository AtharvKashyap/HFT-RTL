// Unit testbench for strategy_imbalance.
//
// Phase 1 -- directed cases whose share/price numbers mirror
// model/tests/test_strategy.py value-for-value, so the Python golden strategy
// and the RTL strategy are checked against identical vectors. The Python tests
// that disable the cooldown (cooldown_updates=0) are reproduced here against a
// DUT with the shipping default of 16 by counting out the cooldown explicitly
// with non-firing filler updates, which additionally pins the cooldown boundary
// from both sides (15 further updates -> still suppressed, 16 -> re-armed).
//
// Phase 2 -- 5,000 constrained-random updates over 2 symbols, two price levels
// per side, shares in 0..600, with each side occasionally empty (all-zero
// prices and shares, as price_book emits for a side with no levels) so the
// "level-0 price is 0 suppresses the intent" path is exercised. Every update is
// checked against a TB scoreboard that re-implements the Python model's
// bookkeeping literally, including its None/int `updates_since_fire` counter,
// so the scoreboard is an independent implementation rather than a copy of the
// RTL's remaining-cooldown register.
//
// Timing contract under test: an update presented with upd_valid on a rising
// edge is absorbed by that edge; if it produces an intent, `out` and a
// one-cycle out_valid pulse appear on the outputs immediately after it (i.e.
// during the following cycle). out_valid pulses only for updates that actually
// produce an intent -- an update that fires no edge, is suppressed by the
// cooldown, or is blocked by a zero level-0 price emits nothing, exactly as the
// Python model returns None. Inputs are therefore driven on the falling edge
// and outputs sampled on the next falling edge, which also lets send_upd() be
// called back-to-back to exercise one update per cycle with no idle gap.
//
// Timescale comes from the Makefile (--timescale 1ns/1ps).

module tb_strategy_imbalance;
  import book_pkg::*;
  import trade_pkg::*;

  localparam int THRESH_LOG2      = trade_pkg::THRESH_LOG2_DEF;      // 2
  localparam int COOLDOWN_UPDATES = trade_pkg::COOLDOWN_UPDATES_DEF; // 16
  localparam int ORDER_SHARES     = trade_pkg::ORDER_SHARES_DEF;     // 100

  // TB-side state encoding; deliberately independent of the DUT's.
  localparam int SB_NEUTRAL = 0;
  localparam int SB_LONG    = 1;
  localparam int SB_SHORT   = 2;

  logic          clk;
  logic          rst_n = 1'b0;
  book_update_t  upd;
  logic          upd_valid = 1'b0;
  gated_intent_t out;
  logic          out_valid;
  logic [31:0]   intent_count;

  strategy_imbalance dut (
    .clk          (clk),
    .rst_n        (rst_n),
    .upd          (upd),
    .upd_valid    (upd_valid),
    .out          (out),
    .out_valid    (out_valid),
    .intent_count (intent_count)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  // ------------------------------------------------------- reference model
  // A literal transcription of model/strategy.py: sb_usf[i] < 0 stands for
  // Python's None (no cooldown active for that symbol).
  int     sb_state [NUM_SYMBOLS];
  int     sb_usf   [NUM_SYMBOLS];
  int     sb_ic;

  // Expected outputs for the update currently in flight.
  bit          exp_valid;
  bit          exp_side;      // 1 = buy, 0 = sell
  int          exp_idx;
  logic [31:0] exp_price, exp_bid0, exp_ask0;

  int          upd_num;
  logic [63:0] ts;

  // Scratch vectors used to build one update.
  logic [N_LEVELS-1:0][31:0] t_bpx, t_bsh, t_apx, t_ash;

  // ------------------------------------------------------ functional coverage
  // Hand-rolled tallies rather than covergroups: Verilator does not implement
  // SystemVerilog functional coverage, so each update's outcome is classified
  // procedurally inside the reference model -- which already decides which of
  // these outcomes it is -- and the tallies are gated at the end of the random
  // phase. A bin the random stimulus never produced is behaviour this run did
  // not verify.
  typedef enum int {
    COV_FIRE_BUY,            // intent emitted, buy side
    COV_FIRE_SELL,           // intent emitted, sell side
    COV_SUPPRESS_COOLDOWN,   // real edge, blocked by an active cooldown
    COV_SUPPRESS_SAME_STATE, // already LONG/SHORT, stayed -> no edge, no fire
    COV_NEUTRAL_REARM,       // fired on re-entering a directional state from NEUTRAL
    COV_EMPTY_SIDE_SUPPRESS, // edge, not on cooldown, blocked by level-0 price 0
    COV_N
  } cov_outcome_e;

  int cov_bin [COV_N];
  bit cov_on = 1'b0;   // only the random phase counts toward the gate

  function automatic void cov_hit(cov_outcome_e o);
    if (cov_on) cov_bin[int'(o)]++;
  endfunction

  function automatic void cov_check();
    string names [COV_N] = '{"fire-buy", "fire-sell", "suppress-cooldown",
                             "suppress-same-state", "neutral-rearm",
                             "empty-side-suppress"};
    int holes;
    holes = 0;
    $display("  coverage (update outcome):");
    for (int o = 0; o < int'(COV_N); o++) begin
      $display("    %-22s %0d", names[o], cov_bin[o]);
      if (cov_bin[o] == 0) begin
        $display("    COVERAGE HOLE: %s never occurred", names[o]);
        holes++;
      end
    end
    if (holes != 0)
      $fatal(1, "random phase left %0d functional-coverage bin(s) empty", holes);
  endfunction

  // Advance the reference model by one update and latch what the DUT must show.
  function automatic void sb_step(int idx,
                                  logic [N_LEVELS-1:0][31:0] bpx,
                                  logic [N_LEVELS-1:0][31:0] bsh,
                                  logic [N_LEVELS-1:0][31:0] apx,
                                  logic [N_LEVELS-1:0][31:0] ash);
    longint mass_b, mass_a;
    int     old_state, new_state;
    bit     fire_buy, fire_sell, suppressed;

    mass_b = 0;
    mass_a = 0;
    for (int i = 0; i < N_LEVELS; i++) begin
      mass_b += longint'(bsh[i]) >> i;
      mass_a += longint'(ash[i]) >> i;
    end

    old_state = sb_state[idx];
    if (mass_b > (mass_a << THRESH_LOG2))      new_state = SB_LONG;
    else if (mass_a > (mass_b << THRESH_LOG2)) new_state = SB_SHORT;
    else                                       new_state = SB_NEUTRAL;

    fire_buy  = (new_state == SB_LONG)  && (old_state != SB_LONG);
    fire_sell = (new_state == SB_SHORT) && (old_state != SB_SHORT);

    sb_state[idx] = new_state;

    suppressed = (sb_usf[idx] >= 0) && (sb_usf[idx] < COOLDOWN_UPDATES);

    exp_valid = 1'b0;
    exp_side  = 1'b0;
    exp_price = '0;
    exp_idx   = idx;
    exp_bid0  = bpx[0];
    exp_ask0  = apx[0];

    if ((fire_buy || fire_sell) && !suppressed) begin
      if (fire_buy && apx[0] != 32'd0) begin
        exp_valid = 1'b1;
        exp_side  = 1'b1;
        exp_price = apx[0];
      end else if (fire_sell && bpx[0] != 32'd0) begin
        exp_valid = 1'b1;
        exp_side  = 1'b0;
        exp_price = bpx[0];
      end
    end

    if (exp_valid) begin
      sb_ic++;
      sb_usf[idx] = 0;
    end else if (sb_usf[idx] >= 0) begin
      sb_usf[idx]++;
      if (sb_usf[idx] >= COOLDOWN_UPDATES) sb_usf[idx] = -1;
    end

    // Coverage classification of this update.
    if (exp_valid) begin
      cov_hit(exp_side ? COV_FIRE_BUY : COV_FIRE_SELL);
      if (old_state == SB_NEUTRAL) cov_hit(COV_NEUTRAL_REARM);
    end else if (fire_buy || fire_sell) begin
      if (suppressed) cov_hit(COV_SUPPRESS_COOLDOWN);
      else            cov_hit(COV_EMPTY_SIDE_SUPPRESS);
    end else if (new_state != SB_NEUTRAL) begin
      cov_hit(COV_SUPPRESS_SAME_STATE);
    end
  endfunction

  // ---------------------------------------------------------------- checking
  task automatic check(string name);
    if (out_valid !== exp_valid)
      $fatal(1, "upd %0d (%s): out_valid=%0b, expected %0b",
             upd_num, name, out_valid, exp_valid);
    if (intent_count !== 32'(sb_ic))
      $fatal(1, "upd %0d (%s): intent_count=%0d, expected %0d",
             upd_num, name, intent_count, sb_ic);
    if (!exp_valid) return;

    if (out.intent.symbol_idx !== BOOK_IDX_W'(exp_idx))
      $fatal(1, "upd %0d (%s): symbol_idx=%0d, expected %0d",
             upd_num, name, out.intent.symbol_idx, exp_idx);
    if (out.intent.side !== exp_side)
      $fatal(1, "upd %0d (%s): side=%0b, expected %0b",
             upd_num, name, out.intent.side, exp_side);
    if (out.intent.shares !== 32'(ORDER_SHARES))
      $fatal(1, "upd %0d (%s): shares=%0d, expected %0d",
             upd_num, name, out.intent.shares, ORDER_SHARES);
    if (out.intent.price !== exp_price)
      $fatal(1, "upd %0d (%s): price=%0d, expected %0d",
             upd_num, name, out.intent.price, exp_price);
    if (out.bid0 !== exp_bid0)
      $fatal(1, "upd %0d (%s): bid0=%0d, expected %0d",
             upd_num, name, out.bid0, exp_bid0);
    if (out.ask0 !== exp_ask0)
      $fatal(1, "upd %0d (%s): ask0=%0d, expected %0d",
             upd_num, name, out.ask0, exp_ask0);
  endtask

  // Directed-phase assertions written against the DUT alone, so a scoreboard
  // that happened to share a bug with the RTL still cannot hide it.
  task automatic expect_buy(logic [31:0] px, string name);
    if (!out_valid) $fatal(1, "%s: expected a buy intent, got none", name);
    if (out.intent.side !== 1'b1) $fatal(1, "%s: expected side=buy", name);
    if (out.intent.price !== px)
      $fatal(1, "%s: buy price=%0d, expected %0d", name, out.intent.price, px);
  endtask

  task automatic expect_sell(logic [31:0] px, string name);
    if (!out_valid) $fatal(1, "%s: expected a sell intent, got none", name);
    if (out.intent.side !== 1'b0) $fatal(1, "%s: expected side=sell", name);
    if (out.intent.price !== px)
      $fatal(1, "%s: sell price=%0d, expected %0d", name, out.intent.price, px);
  endtask

  task automatic expect_none(string name);
    if (out_valid)
      $fatal(1, "%s: expected no intent, got side=%0b price=%0d",
             name, out.intent.side, out.intent.price);
  endtask

  task automatic expect_count(int n, string name);
    if (intent_count !== 32'(n))
      $fatal(1, "%s: intent_count=%0d, expected %0d", name, intent_count, n);
  endtask

  // --------------------------------------------------------------- stimulus
  // Drives one update and checks the result. Entered and left on a falling
  // edge, so consecutive calls issue one update per cycle back-to-back.
  task automatic send_upd(int idx,
                          logic [N_LEVELS-1:0][31:0] bpx,
                          logic [N_LEVELS-1:0][31:0] bsh,
                          logic [N_LEVELS-1:0][31:0] apx,
                          logic [N_LEVELS-1:0][31:0] ash,
                          string name);
    upd.book_idx   = BOOK_IDX_W'(idx);
    upd.bid_price  = bpx;
    upd.bid_shares = bsh;
    upd.ask_price  = apx;
    upd.ask_shares = ash;
    ts             = ts + 64'd1;
    upd.timestamp  = ts;
    upd_valid      = 1'b1;
    upd_num++;
    sb_step(idx, bpx, bsh, apx, ash);
    @(posedge clk);
    @(negedge clk);
    upd_valid = 1'b0;   // re-asserted immediately by a following send_upd call
    check(name);
  endtask

  // Two-level convenience wrapper for the directed cases.
  task automatic send2(int idx,
                       int bpx0, int bsh0, int bpx1, int bsh1,
                       int apx0, int ash0, int apx1, int ash1,
                       string name);
    t_bpx = '0; t_bsh = '0; t_apx = '0; t_ash = '0;
    t_bpx[0] = 32'(bpx0); t_bsh[0] = 32'(bsh0);
    t_bpx[1] = 32'(bpx1); t_bsh[1] = 32'(bsh1);
    t_apx[0] = 32'(apx0); t_ash[0] = 32'(ash0);
    t_apx[1] = 32'(apx1); t_ash[1] = 32'(ash1);
    send_upd(idx, t_bpx, t_bsh, t_apx, t_ash, name);
  endtask

  // The canonical vectors from model/tests/test_strategy.py.
  task automatic send_long(int idx, string name);   // B=500, A=124 -> LONG
    send2(idx, 1000, 500, 0, 0, 1010, 124, 0, 0, name);
  endtask

  task automatic send_neutral(int idx, string name); // B=100, A=100 -> NEUTRAL
    send2(idx, 1000, 100, 0, 0, 1010, 100, 0, 0, name);
  endtask

  task automatic send_short(int idx, string name);   // B=100, A=500 -> SHORT
    send2(idx, 1000, 100, 0, 0, 1010, 500, 0, 0, name);
  endtask

  task automatic idle(int n);
    upd_valid = 1'b0;
    repeat (n) begin
      @(negedge clk);
      if (out_valid !== 1'b0)
        $fatal(1, "out_valid asserted with no update in flight (upd %0d)", upd_num);
    end
  endtask

  task automatic do_reset();
    upd_valid = 1'b0;
    rst_n     = 1'b0;
    repeat (3) @(negedge clk);
    rst_n     = 1'b1;
    @(negedge clk);
    for (int s = 0; s < NUM_SYMBOLS; s++) begin
      sb_state[s] = SB_NEUTRAL;
      sb_usf[s]   = -1;
    end
    sb_ic = 0;
    if (out_valid !== 1'b0)       $fatal(1, "out_valid asserted after reset");
    if (intent_count !== 32'd0)   $fatal(1, "intent_count nonzero after reset");
  endtask

  // ------------------------------------------------------------- test body
  int r_idx, r_i;
  bit r_bid_empty, r_ask_empty;

  initial begin
    upd     = '0;
    ts      = 64'd0;
    upd_num = 0;

    // ---------------------------------------------------------- directed
    // test_fires_buy_on_exact_threshold_crossing:
    // B = 500, A = 124 -> A<<2 = 496 < 500 -> LONG, fires at ask0.
    do_reset();
    send_long(0, "exact threshold crossing");
    expect_buy(32'd1010, "exact threshold crossing");
    if (out.bid0 !== 32'd1000 || out.ask0 !== 32'd1010)
      $fatal(1, "threshold crossing: sideband (bid0=%0d, ask0=%0d), expected (1000,1010)",
             out.bid0, out.ask0);
    if (out.intent.symbol_idx !== BOOK_IDX_W'(0))
      $fatal(1, "threshold crossing: symbol_idx=%0d, expected 0", out.intent.symbol_idx);
    if (out.intent.shares !== 32'(ORDER_SHARES))
      $fatal(1, "threshold crossing: shares=%0d, expected %0d",
             out.intent.shares, ORDER_SHARES);
    expect_count(1, "exact threshold crossing");
    idle(2);

    // test_no_fire_at_boundary_equal: B = 496 == A<<2 -> not LONG (strict >).
    do_reset();
    send2(0, 1000, 496, 0, 0, 1010, 124, 0, 0, "boundary equal");
    expect_none("boundary equal");
    expect_count(0, "boundary equal");
    idle(2);

    // test_weights_halve_per_level: 100@L0 + 800@L1 -> 100 + 400 = 500.
    do_reset();
    send2(0, 1000, 100, 999, 800, 1010, 124, 0, 0, "level weights halve");
    expect_buy(32'd1010, "level weights halve");
    idle(2);

    // test_integer_right_shift_semantics_on_odd_shares:
    // bid L1 shares 3 -> 3>>1 = 1 (floor). B = 1, A = 5, 5 > 1<<2 = 4 -> SHORT.
    do_reset();
    send2(0, 1000, 0, 999, 3, 1010, 5, 0, 0, "floor shift on odd shares");
    expect_sell(32'd1000, "floor shift on odd shares");
    if (out.bid0 !== 32'd1000 || out.ask0 !== 32'd1010)
      $fatal(1, "floor shift: sideband (bid0=%0d, ask0=%0d), expected (1000,1010)",
             out.bid0, out.ask0);
    idle(2);

    // test_empty_ask_side_suppresses_buy_intent: A = 0 -> LONG, but ask0 = 0.
    do_reset();
    send2(0, 1000, 500, 0, 0, 0, 0, 0, 0, "empty ask suppresses buy");
    expect_none("empty ask suppresses buy");
    expect_count(0, "empty ask suppresses buy");
    // Mirror image: an empty bid side suppresses the sell intent.
    do_reset();
    send2(0, 0, 0, 0, 0, 1010, 500, 0, 0, "empty bid suppresses sell");
    expect_none("empty bid suppresses sell");
    expect_count(0, "empty bid suppresses sell");
    idle(2);

    // test_direct_long_to_short_flip_fires_sell. The DUT ships with a live
    // cooldown, so LONG is entered via the empty-ask path above: that sets the
    // state to LONG without firing, hence without arming the cooldown, leaving
    // a clean LONG -> SHORT flip to observe.
    do_reset();
    send2(0, 1000, 500, 0, 0, 0, 0, 0, 0, "flip: enter LONG unfired");
    expect_none("flip: enter LONG unfired");
    send_short(0, "flip: LONG -> SHORT");
    expect_sell(32'd1000, "flip: LONG -> SHORT");
    if (out.bid0 !== 32'd1000 || out.ask0 !== 32'd1010)
      $fatal(1, "flip: sideband (bid0=%0d, ask0=%0d), expected (1000,1010)",
             out.bid0, out.ask0);
    expect_count(1, "flip: LONG -> SHORT");
    idle(2);

    // test_staying_long_does_not_refire. Fire once, then hold LONG for well
    // past the cooldown window: no further intent may ever appear, so the
    // "staying never fires" rule is checked both inside and outside cooldown.
    do_reset();
    send_long(0, "stay-long: initial fire");
    expect_buy(32'd1010, "stay-long: initial fire");
    for (int n = 0; n < 24; n++)
      send2(0, 1000, 600, 0, 0, 1010, 124, 0, 0, "stay-long: still LONG");
    expect_count(1, "stay-long");
    idle(2);

    // test_state_tracks_during_cooldown_without_refiring_after_expiry.
    // Fire; NEUTRAL; a genuine NEUTRAL->LONG edge while suppressed; then hold
    // LONG past cooldown expiry. Nothing may fire again: the expiring cooldown
    // is not itself an edge.
    do_reset();
    send_long(0, "cooldown-tracks: initial fire");
    expect_buy(32'd1010, "cooldown-tracks: initial fire");
    send_neutral(0, "cooldown-tracks: neutral");
    send_long(0, "cooldown-tracks: suppressed LONG edge");
    expect_none("cooldown-tracks: suppressed LONG edge");
    for (int n = 0; n < 20; n++)
      send_long(0, "cooldown-tracks: still LONG past expiry");
    expect_count(1, "cooldown-tracks");
    idle(2);

    // Cooldown boundary, low side: 15 further updates after the fire leaves the
    // cooldown active, so the 16th update's genuine edge is still suppressed.
    do_reset();
    send_long(0, "cooldown-15: initial fire");
    expect_buy(32'd1010, "cooldown-15: initial fire");
    for (int n = 0; n < COOLDOWN_UPDATES - 1; n++)
      send_neutral(0, "cooldown-15: filler");
    send_long(0, "cooldown-15: edge still suppressed");
    expect_none("cooldown-15: edge still suppressed");
    expect_count(1, "cooldown-15");
    idle(2);

    // Cooldown boundary, high side: exactly COOLDOWN_UPDATES further updates
    // re-arm, so the next edge fires.
    do_reset();
    send_long(0, "cooldown-16: initial fire");
    expect_buy(32'd1010, "cooldown-16: initial fire");
    for (int n = 0; n < COOLDOWN_UPDATES; n++)
      send_neutral(0, "cooldown-16: filler");
    send_long(0, "cooldown-16: re-armed edge fires");
    expect_buy(32'd1010, "cooldown-16: re-armed edge fires");
    expect_count(2, "cooldown-16");
    idle(2);

    // test_cooldown_blocks_fires_for_symbol_but_not_another: per-symbol state
    // and cooldown are independent.
    do_reset();
    send_long(0, "two-sym: sym0 fires");
    expect_buy(32'd1010, "two-sym: sym0 fires");
    send_neutral(0, "two-sym: sym0 neutral");
    send_long(0, "two-sym: sym0 suppressed");
    expect_none("two-sym: sym0 suppressed");
    send_long(1, "two-sym: sym1 fires");
    expect_buy(32'd1010, "two-sym: sym1 fires");
    if (out.intent.symbol_idx !== BOOK_IDX_W'(1))
      $fatal(1, "two-sym: symbol_idx=%0d, expected 1", out.intent.symbol_idx);
    expect_count(2, "two-sym");
    idle(2);

    // Updates presented with upd_valid low must be ignored entirely: the state
    // machine advances on book-update ordinals, not clock cycles.
    do_reset();
    t_bpx = '0; t_bsh = '0; t_apx = '0; t_ash = '0;
    t_bpx[0] = 32'd1000; t_bsh[0] = 32'd500;
    t_apx[0] = 32'd1010; t_ash[0] = 32'd124;
    upd.book_idx   = BOOK_IDX_W'(0);
    upd.bid_price  = t_bpx;
    upd.bid_shares = t_bsh;
    upd.ask_price  = t_apx;
    upd.ask_shares = t_ash;
    idle(6);                       // same LONG vector held, upd_valid low
    expect_count(0, "idle with upd_valid low");
    send_long(0, "fires once upd_valid asserts");
    expect_buy(32'd1010, "fires once upd_valid asserts");
    idle(2);

    $display("  directed cases: ok (%0d updates)", upd_num);

    // ------------------------------------------------------------ random
    do_reset();
    cov_on = 1'b1;
    for (int n = 0; n < 5000; n++) begin
      r_idx       = $urandom_range(1, 0);
      r_bid_empty = ($urandom_range(7, 0) == 0);
      r_ask_empty = ($urandom_range(7, 0) == 0);

      t_bpx = '0; t_bsh = '0; t_apx = '0; t_ash = '0;
      if (!r_bid_empty) begin
        t_bpx[0] = 32'd1000; t_bsh[0] = 32'($urandom_range(600, 0));
        t_bpx[1] = 32'd999;  t_bsh[1] = 32'($urandom_range(600, 0));
      end
      if (!r_ask_empty) begin
        t_apx[0] = 32'd1010; t_ash[0] = 32'($urandom_range(600, 0));
        t_apx[1] = 32'd1011; t_ash[1] = 32'($urandom_range(600, 0));
      end
      send_upd(r_idx, t_bpx, t_bsh, t_apx, t_ash, "random");
    end
    idle(2);
    $display("  random phase: ok (5000 updates, intents=%0d)", intent_count);
    cov_check();
    cov_on = 1'b0;

    // Deeper books: all 8 levels populated, so every weight in the mass adder
    // tree (including the >>7 term) contributes.
    do_reset();
    for (int n = 0; n < 500; n++) begin
      r_idx = $urandom_range(1, 0);
      t_bpx = '0; t_bsh = '0; t_apx = '0; t_ash = '0;
      for (r_i = 0; r_i < N_LEVELS; r_i++) begin
        t_bpx[r_i] = 32'(1000 - r_i);
        t_bsh[r_i] = 32'($urandom_range(600, 0));
        t_apx[r_i] = 32'(1010 + r_i);
        t_ash[r_i] = 32'($urandom_range(600, 0));
      end
      send_upd(r_idx, t_bpx, t_bsh, t_apx, t_ash, "deep book");
    end
    idle(2);
    $display("  deep-book phase: ok (500 updates)");

    $display("PASS");
    $finish;
  end

  // Watchdog: never let a broken DUT hang the run. 5.5k updates at 10ns plus
  // the directed phase fits comfortably inside 1ms.
  initial begin
    #1000000;
    $fatal(1, "TIMEOUT");
  end

endmodule
