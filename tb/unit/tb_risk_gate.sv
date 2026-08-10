// Unit testbench for risk_gate.
//
// Phase 1 -- directed cases whose numbers mirror model/tests/test_risk.py
// value-for-value, so the Python golden risk gate and the RTL gate are
// checked against identical vectors: crossed-book sanity reject, the collar
// boundary at mid=8008/band=1001 (1002 offset rejects, 1001 offset passes,
// strict >), rate resetting only on accept, position saturating at 10x100
// buys before the 11th rejects, sells offsetting buys, per-symbol position
// independence, and the check-order tie-break (a crossed book with a stale
// rate counter still hits sanity first, and a reject changes neither the
// position nor the rate counter). Every directed case checks all five
// counters (accept, sanity, collar, rate, position), not just the one under
// test, so a check firing on the wrong path cannot hide behind a case that
// only inspects its own counter.
//
// Phase 2 -- 3,000 random intents, sidebands and prices with interleaved
// random book updates (the rate time base) driving a scoreboard that is an
// independent re-implementation of model/risk.py's bookkeeping (not a copy
// of the RTL's counters), including deliberate coincidences of an update and
// an intent on the same cycle to exercise the "increment before compare"
// rule documented in rtl/risk_gate.sv.
//
// Timing contract under test: upd_valid is the book's update pulse (the rate
// time base) and is a separate input from in_valid. in_valid presented on a
// rising edge is judged that edge (against pos/rate state already updated by
// any upd_valid on the SAME edge -- the rate counter increments before the
// comparison when both coincide); out and a one-cycle out_valid pulse appear
// on the outputs immediately after (i.e. during the following cycle), and
// only for accepted intents. All five counters update on the same edge that
// judges in_valid, so they too become visible one cycle later, in step with
// out_valid.
//
// Timescale comes from the Makefile (--timescale 1ns/1ps).

module tb_risk_gate;
  import book_pkg::*;
  import trade_pkg::*;

  localparam int MAX_POSITION      = trade_pkg::MAX_POSITION_DEF;      // 1000
  localparam int MIN_ORDER_SPACING = trade_pkg::MIN_ORDER_SPACING_DEF; // 10
  localparam int COLLAR_SHIFT      = trade_pkg::COLLAR_SHIFT_DEF;      // 3

  logic          clk;
  logic          rst_n = 1'b0;
  logic          upd_valid = 1'b0;
  gated_intent_t in;
  logic          in_valid = 1'b0;
  order_intent_t out;
  logic          out_valid;
  logic [31:0]   accept_count, sanity_reject_count, collar_reject_count,
                 rate_reject_count, pos_reject_count;

  risk_gate #(
    .MAX_POSITION      (MAX_POSITION),
    .MIN_ORDER_SPACING (MIN_ORDER_SPACING),
    .COLLAR_SHIFT      (COLLAR_SHIFT)
  ) dut (
    .clk                  (clk),
    .rst_n                (rst_n),
    .upd_valid            (upd_valid),
    .in                   (in),
    .in_valid             (in_valid),
    .out                  (out),
    .out_valid            (out_valid),
    .accept_count         (accept_count),
    .sanity_reject_count  (sanity_reject_count),
    .collar_reject_count  (collar_reject_count),
    .rate_reject_count    (rate_reject_count),
    .pos_reject_count     (pos_reject_count)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  // ------------------------------------------------------- reference model
  // A literal transcription of model/risk.py's RiskGate. sb_rate mirrors
  // updates_since_accept: incremented by every on_update(), reset to 0 only
  // on accept. Checks run sanity -> collar -> rate -> position, and exactly
  // one counter increments per outcome.
  int sb_pos    [NUM_SYMBOLS];
  int sb_rate;
  int sb_accept, sb_sanity, sb_collar, sb_rate_rej, sb_pos_rej;

  task automatic sb_reset();
    for (int s = 0; s < NUM_SYMBOLS; s++) sb_pos[s] = 0;
    sb_rate     = 0;
    sb_accept   = 0;
    sb_sanity   = 0;
    sb_collar   = 0;
    sb_rate_rej = 0;
    sb_pos_rej  = 0;
  endtask

  // model/risk.py's on_update(): increments the rate counter unconditionally.
  task automatic sb_on_update();
    sb_rate++;
  endtask

  // model/risk.py's on_intent(): returns 1 on accept, updates exactly one
  // counter (and, on accept, sb_pos/sb_rate) as a side effect.
  function automatic bit sb_on_intent(int idx, bit side, int shares,
                                       int price, int bid0, int ask0);
    int mid, band, diff, delta, newp, absp;
    if (!(bid0 != 0 && ask0 != 0 && bid0 < ask0)) begin
      sb_sanity++;
      return 1'b0;
    end
    mid  = (bid0 + ask0) >> 1;
    band = mid >> COLLAR_SHIFT;
    diff = price - mid;
    if (diff < 0) diff = -diff;
    if (diff > band) begin
      sb_collar++;
      return 1'b0;
    end
    if (sb_rate < MIN_ORDER_SPACING) begin
      sb_rate_rej++;
      return 1'b0;
    end
    delta = side ? shares : -shares;
    newp  = sb_pos[idx] + delta;
    absp  = newp < 0 ? -newp : newp;
    if (absp > MAX_POSITION) begin
      sb_pos_rej++;
      return 1'b0;
    end
    sb_pos[idx] = newp;
    sb_rate     = 0;
    sb_accept++;
    return 1'b1;
  endfunction

  // ------------------------------------------------------ functional coverage
  typedef enum int {COV_ACCEPT, COV_SANITY, COV_COLLAR, COV_RATE, COV_POS, COV_N} cov_e;
  int cov_bin [COV_N];
  bit cov_on = 1'b0;

  function automatic void cov_check();
    string names [COV_N] = '{"accept", "sanity-reject", "collar-reject",
                             "rate-reject", "pos-reject"};
    int holes;
    holes = 0;
    $display("  coverage (outcome):");
    for (int o = 0; o < int'(COV_N); o++) begin
      $display("    %-14s %0d", names[o], cov_bin[o]);
      if (cov_bin[o] == 0) begin
        $display("    COVERAGE HOLE: %s never occurred", names[o]);
        holes++;
      end
    end
    if (holes != 0)
      $fatal(1, "random phase left %0d functional-coverage bin(s) empty", holes);
  endfunction

  // ---------------------------------------------------------------- driving
  int op_num;

  // Drives one cycle: upd_p pulses upd_valid, and when in_p is set also
  // drives an intent on `in`/in_valid. When both pulse on the same cycle the
  // scoreboard applies sb_on_update() before sb_on_intent(), exactly
  // replicating the RTL's "increment before compare" coincidence rule (see
  // rtl/risk_gate.sv). Entered and left on a falling edge so calls issue back
  // to back with no idle gap.
  task automatic step(bit upd_p, bit in_p, int idx, bit side, int shares,
                      int price, int bid0, int ask0, string name);
    bit exp_accept;
    int exp_idx, exp_shares, exp_price;
    bit exp_side;

    upd_valid = upd_p;
    in_valid  = in_p;
    if (in_p) begin
      in.intent.symbol_idx = BOOK_IDX_W'(idx);
      in.intent.side       = side;
      in.intent.shares     = 32'(shares);
      in.intent.price      = 32'(price);
      in.bid0              = 32'(bid0);
      in.ask0              = 32'(ask0);
    end

    if (upd_p) sb_on_update();
    if (in_p) begin
      exp_accept = sb_on_intent(idx, side, shares, price, bid0, ask0);
      exp_idx    = idx;
      exp_side   = side;
      exp_shares = shares;
      exp_price  = price;
      if (cov_on) begin
        if (exp_accept)               cov_bin[int'(COV_ACCEPT)]++;
        else if (sb_sanity_last())    cov_bin[int'(COV_SANITY)]++;
      end
    end
    op_num++;

    @(posedge clk);
    @(negedge clk);
    upd_valid = 1'b0;
    in_valid  = 1'b0;

    if (in_p) begin
      if (out_valid !== exp_accept)
        $fatal(1, "op %0d (%s): out_valid=%0b, expected %0b",
               op_num, name, out_valid, exp_accept);
      if (exp_accept) begin
        if (out.symbol_idx !== BOOK_IDX_W'(exp_idx))
          $fatal(1, "op %0d (%s): out.symbol_idx=%0d, expected %0d",
                 op_num, name, out.symbol_idx, exp_idx);
        if (out.side !== exp_side)
          $fatal(1, "op %0d (%s): out.side=%0b, expected %0b",
                 op_num, name, out.side, exp_side);
        if (out.shares !== 32'(exp_shares))
          $fatal(1, "op %0d (%s): out.shares=%0d, expected %0d",
                 op_num, name, out.shares, exp_shares);
        if (out.price !== 32'(exp_price))
          $fatal(1, "op %0d (%s): out.price=%0d, expected %0d",
                 op_num, name, out.price, exp_price);
      end
    end else begin
      if (out_valid !== 1'b0)
        $fatal(1, "op %0d (%s): out_valid asserted with no intent presented",
               op_num, name);
    end
    check_counters(name);
  endtask

  // sb_on_intent already advanced the counters; this just distinguishes
  // "the most recent intent's reject was sanity" for coverage classification
  // without re-deriving the check order.
  int last_sanity, last_collar, last_rate_rej, last_pos_rej;
  function automatic bit sb_sanity_last();
    return (sb_sanity != last_sanity);
  endfunction

  task automatic cov_classify();
    if (cov_on) begin
      if (sb_collar   != last_collar)   cov_bin[int'(COV_COLLAR)]++;
      if (sb_rate_rej != last_rate_rej) cov_bin[int'(COV_RATE)]++;
      if (sb_pos_rej  != last_pos_rej)  cov_bin[int'(COV_POS)]++;
    end
    last_sanity   = sb_sanity;
    last_collar   = sb_collar;
    last_rate_rej = sb_rate_rej;
    last_pos_rej  = sb_pos_rej;
  endtask

  task automatic check_counters(string name);
    if (accept_count !== 32'(sb_accept))
      $fatal(1, "op %0d (%s): accept_count=%0d, expected %0d",
             op_num, name, accept_count, sb_accept);
    if (sanity_reject_count !== 32'(sb_sanity))
      $fatal(1, "op %0d (%s): sanity_reject_count=%0d, expected %0d",
             op_num, name, sanity_reject_count, sb_sanity);
    if (collar_reject_count !== 32'(sb_collar))
      $fatal(1, "op %0d (%s): collar_reject_count=%0d, expected %0d",
             op_num, name, collar_reject_count, sb_collar);
    if (rate_reject_count !== 32'(sb_rate_rej))
      $fatal(1, "op %0d (%s): rate_reject_count=%0d, expected %0d",
             op_num, name, rate_reject_count, sb_rate_rej);
    if (pos_reject_count !== 32'(sb_pos_rej))
      $fatal(1, "op %0d (%s): pos_reject_count=%0d, expected %0d",
             op_num, name, pos_reject_count, sb_pos_rej);
    cov_classify();
  endtask

  // Convenience: send MIN_ORDER_SPACING (default 10) update-only cycles,
  // mirroring the Python tests' _warm(g) helper.
  task automatic warm(int n, string name);
    repeat (n) step(1'b1, 1'b0, 0, 1'b0, 0, 0, 0, 0, name);
  endtask

  task automatic do_reset();
    upd_valid = 1'b0;
    in_valid  = 1'b0;
    rst_n     = 1'b0;
    repeat (3) @(negedge clk);
    rst_n     = 1'b1;
    @(negedge clk);
    sb_reset();
    last_sanity   = 0;
    last_collar   = 0;
    last_rate_rej = 0;
    last_pos_rej  = 0;
    if (out_valid !== 1'b0)        $fatal(1, "out_valid asserted after reset");
    if (accept_count !== 32'd0)    $fatal(1, "accept_count nonzero after reset");
    if (sanity_reject_count !== 32'd0) $fatal(1, "sanity_reject_count nonzero after reset");
    if (collar_reject_count !== 32'd0) $fatal(1, "collar_reject_count nonzero after reset");
    if (rate_reject_count !== 32'd0)   $fatal(1, "rate_reject_count nonzero after reset");
    if (pos_reject_count !== 32'd0)    $fatal(1, "pos_reject_count nonzero after reset");
  endtask

  // ------------------------------------------------------------- test body
  int r_idx, r_side, r_shares, r_price, r_bid0, r_ask0, r_scenario;
  bit r_upd_p;

  initial begin
    op_num = 0;
    in     = '0;

    // ------------------------------------------------------------- directed
    // test_sanity_rejects_crossed_book
    do_reset();
    warm(10, "sanity: warm");
    step(1'b0, 1'b1, 0, 1'b1, 100, 1010, 1010, 1000, "sanity: crossed book");

    // test_sanity_rejects_zero_bid0
    do_reset();
    warm(10, "sanity0: warm");
    step(1'b0, 1'b1, 0, 1'b1, 100, 1010, 0, 1010, "sanity: bid0=0");

    // test_sanity_rejects_zero_ask0
    do_reset();
    warm(10, "sanity1: warm");
    step(1'b0, 1'b1, 0, 1'b1, 100, 1010, 1000, 0, "sanity: ask0=0");

    // test_collar_boundary: mid=(8000+8016)>>1=8008, band=8008>>3=1001.
    // |9010-8008|=1002 > 1001 -> reject; |9009-8008|=1001 == band -> accept.
    do_reset();
    warm(10, "collar: warm");
    step(1'b0, 1'b1, 0, 1'b1, 100, 9010, 8000, 8016, "collar: 1002 offset rejects");
    warm(10, "collar: warm2");
    step(1'b0, 1'b1, 0, 1'b1, 100, 9009, 8000, 8016, "collar: 1001 offset passes (strict >)");

    // test_rate_resets_only_on_accept
    do_reset();
    warm(10, "rate: warm");
    step(1'b0, 1'b1, 0, 1'b1, 100, 1010, 1000, 1010, "rate: first intent accepts");
    step(1'b0, 1'b1, 0, 1'b1, 100, 1010, 1000, 1010, "rate: immediate repeat rejects on rate");

    // test_position_accumulates_and_rejects_at_limit: 10x100 buys -> pos=1000,
    // then an 11th rejects and pos/rate stay unchanged by the reject.
    do_reset();
    for (int n = 0; n < 10; n++) begin
      warm(10, "pos: warm");
      step(1'b0, 1'b1, 0, 1'b1, 100, 1010, 1000, 1010, "pos: accumulate buy");
    end
    if (sb_pos[0] !== 1000) $fatal(1, "pos: expected sb_pos[0]=1000, got %0d", sb_pos[0]);
    warm(10, "pos: warm limit");
    step(1'b0, 1'b1, 0, 1'b1, 100, 1010, 1000, 1010, "pos: 11th buy rejects at limit");
    if (sb_pos[0] !== 1000)
      $fatal(1, "pos: reject changed position, sb_pos[0]=%0d", sb_pos[0]);

    // test_sell_offsets_buys
    do_reset();
    warm(10, "sell: warm buy");
    step(1'b0, 1'b1, 0, 1'b1, 500, 1010, 1000, 1010, "sell: buy 500");
    if (sb_pos[0] !== 500) $fatal(1, "sell: expected pos=500, got %0d", sb_pos[0]);
    warm(10, "sell: warm sell");
    step(1'b0, 1'b1, 0, 1'b0, 200, 1010, 1000, 1010, "sell: sell 200");
    if (sb_pos[0] !== 300) $fatal(1, "sell: expected pos=300, got %0d", sb_pos[0]);

    // test_position_limit_is_per_symbol_independent
    do_reset();
    for (int n = 0; n < 10; n++) begin
      warm(10, "persym: warm");
      step(1'b0, 1'b1, 0, 1'b1, 100, 1010, 1000, 1010, "persym: sym0 buy");
    end
    if (sb_pos[0] !== 1000) $fatal(1, "persym: sym0 not at limit");
    warm(10, "persym: warm sym1");
    step(1'b0, 1'b1, 1, 1'b1, 100, 1010, 1000, 1010, "persym: sym1 buy still accepts");
    if (sb_pos[1] !== 100) $fatal(1, "persym: expected sym1 pos=100, got %0d", sb_pos[1]);
    if (sb_pos[0] !== 1000) $fatal(1, "persym: sym0 pos disturbed, got %0d", sb_pos[0]);

    // test_check_order_crossed_book_with_stale_rate_counter_hits_sanity: no
    // warmup at all (rate counter is 0, which alone would reject on a rate
    // check), but the book is crossed -- sanity must fire first.
    do_reset();
    step(1'b0, 1'b1, 0, 1'b1, 100, 1010, 1010, 1000, "order: crossed book with no warmup");
    if (sb_rate_rej !== 0) $fatal(1, "order: rate_reject_count should be 0, got %0d", sb_rate_rej);

    // test_reject_changes_neither_position_nor_rate_counter
    do_reset();
    warm(10, "noeffect: warm");
    step(1'b0, 1'b1, 0, 1'b1, 100, 1010, 1010, 1000, "noeffect: crossed book rejects");
    if (sb_pos[0] !== 0) $fatal(1, "noeffect: pos changed by reject, got %0d", sb_pos[0]);
    // The rate counter must be unaffected by the reject: still enough
    // updates accrued from the earlier warmup to accept now.
    step(1'b0, 1'b1, 0, 1'b1, 100, 1010, 1000, 1010, "noeffect: rate untouched, now accepts");

    // Directed coincidence case: an update and an intent on the same cycle.
    // The rate counter increments before the comparison, so an intent that
    // would otherwise be one update short of MIN_ORDER_SPACING passes when
    // the coincident update supplies the last increment.
    do_reset();
    warm(MIN_ORDER_SPACING - 1, "coincide: warm one short");
    step(1'b1, 1'b1, 0, 1'b1, 100, 1010, 1000, 1010,
         "coincide: coincident update supplies the last increment, accepts");

    $display("  directed cases: ok (%0d ops)", op_num);

    // -------------------------------------------------------------- random
    do_reset();
    cov_on = 1'b0;
    // A short warmup so the random phase doesn't spend its first several
    // intents entirely on rate rejects.
    warm(MIN_ORDER_SPACING, "random: initial warm");
    cov_on = 1'b1;
    for (int n = 0; n < 3000; n++) begin
      r_idx      = $urandom_range(NUM_SYMBOLS - 1, 0);
      r_side     = $urandom_range(1, 0);
      r_shares   = $urandom_range(400, 1);
      r_scenario = $urandom_range(99, 0);
      r_upd_p    = ($urandom_range(9, 0) < 3);

      if (r_scenario < 15) begin
        // Sanity-breaking book.
        case ($urandom_range(2, 0))
          0: begin r_bid0 = 0;    r_ask0 = 1010; end
          1: begin r_bid0 = 1000; r_ask0 = 0;    end
          default: begin r_bid0 = 1010; r_ask0 = 1000; end
        endcase
        r_price = 1005;
      end else begin
        r_bid0 = 32'($urandom_range(9000, 100));
        r_ask0 = r_bid0 + 32'($urandom_range(40, 2));
        if (r_scenario < 30) begin
          // Collar-breaking price: well outside the band on either side.
          r_price = ((r_bid0 + r_ask0) >> 1) + (($urandom_range(1, 0) == 0) ? 5000 : -5000);
          if (r_price < 0) r_price = 0;
        end else begin
          // In-band price: offset small enough to always stay under the
          // band even at the smallest spreads used above.
          r_price = ((r_bid0 + r_ask0) >> 1) + ($urandom_range(6, 0) - 3);
        end
      end

      // A handful of standalone update-only cycles ahead of the intent, to
      // vary how much of the rate counter's threshold is already banked
      // before this intent (and to occasionally clear it entirely).
      repeat ($urandom_range(2, 0)) step(1'b1, 1'b0, 0, 1'b0, 0, 0, 0, 0, "random: filler update");

      step(r_upd_p, 1'b1, r_idx, r_side[0], r_shares, r_price, r_bid0, r_ask0, "random: intent");
    end
    cov_on = 1'b0;
    $display("  random phase: ok (3000 intents, accept=%0d sanity=%0d collar=%0d rate=%0d pos=%0d)",
              sb_accept, sb_sanity, sb_collar, sb_rate_rej, sb_pos_rej);
    cov_check();

    $display("PASS");
    $finish;
  end

  // Watchdog: never let a broken DUT hang the run.
  initial begin
    #2000000;
    $fatal(1, "TIMEOUT");
  end

endmodule
