// Unit testbench for price_book.
//
// Phase 1 -- directed cases whose prices/shares mirror model/tests/test_book.py
// value-for-value, so the Python golden model and the RTL book are checked
// against identical vectors.
//
// Phase 2 -- 10,000 constrained-random ops (price in {90..110}*10000 to force
// collisions, shares in 1..500, random op/side) issued one per cycle and
// checked op-by-op against a behavioural reference model built from an
// associative array that is re-sorted from scratch after every op (slow, but
// obviously correct). The first divergence is a $fatal that prints the op
// number.
//
// Timing contract under test: an op presented with op_valid on a rising edge is
// absorbed by that edge; the resulting snapshot and a one-cycle upd_valid pulse
// appear on the outputs immediately after it (i.e. during the following cycle).
// Every input is therefore driven on the falling edge and every output sampled
// on the next falling edge, which also lets do_op() be called back-to-back to
// exercise one op per cycle with no idle gap.
//
// Timescale comes from the Makefile (--timescale 1ns/1ps).

module tb_price_book;
  import book_pkg::*;

  localparam logic [BOOK_IDX_W-1:0] MY_IDX = 'd3;

  logic         clk;
  logic         rst_n = 1'b0;
  book_op_t     op;
  logic         op_valid = 1'b0;
  logic [63:0]  timestamp_in = 64'd0;
  book_update_t upd;
  logic         upd_valid;
  logic [31:0]  evict_count;
  logic [31:0]  reduce_miss_count;
  logic [31:0]  crossed_count;

  price_book #(.MY_IDX(MY_IDX)) dut (
    .clk               (clk),
    .rst_n             (rst_n),
    .op                (op),
    .op_valid          (op_valid),
    .timestamp_in      (timestamp_in),
    .upd               (upd),
    .upd_valid         (upd_valid),
    .evict_count       (evict_count),
    .reduce_miss_count (reduce_miss_count),
    .crossed_count     (crossed_count)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  // ------------------------------------------------------- reference model
  // Retained levels only: price -> shares, keyed by ck(side, price) so a single
  // associative array holds both sides. Levels pushed out of the top 8 are
  // deleted here exactly as the RTL discards them, so the reference cannot
  // "remember" a truncated level.
  longint ref_sh [int];
  int     ref_evict;
  int     ref_miss;

  // Expected sorted snapshot, [side][level]; side index 1 = bid, 0 = ask.
  logic [31:0] exp_px  [2][N_LEVELS];
  logic [31:0] exp_shr [2][N_LEVELS];

  // Bookkeeping for the current op.
  int          op_num;
  bit          exp_changed;
  logic [63:0] exp_ts;
  logic [63:0] ts;

  function automatic int ck(bit side, int price);
    return price * 2 + int'(side);
  endfunction

  function automatic int ref_count(bit side);
    int k, n;
    n = 0;
    if (ref_sh.first(k) != 0) begin
      do begin
        if ((k % 2) == int'(side)) n++;
      end while (ref_sh.next(k) != 0);
    end
    return n;
  endfunction

  // Worst retained price on a side: lowest for bids, highest for asks.
  // Only called when the side is non-empty.
  function automatic int ref_worst(bit side);
    int k, w;
    bit have;
    have = 1'b0;
    w    = 0;
    if (ref_sh.first(k) != 0) begin
      do begin
        if ((k % 2) == int'(side)) begin
          int p;
          p = k / 2;
          if (!have)                       begin w = p; have = 1'b1; end
          else if (side ? (p < w) : (p > w)) w = p;
        end
      end while (ref_sh.next(k) != 0);
    end
    if (!have) $fatal(1, "ref_worst on empty side");
    return w;
  endfunction

  function automatic bit ref_add(bit side, int price, int shares);
    int n, worst;
    if (ref_sh.exists(ck(side, price))) begin
      ref_sh[ck(side, price)] += 64'(shares);
      return 1'b1;
    end
    n = ref_count(side);
    if (n >= N_LEVELS) begin
      worst = ref_worst(side);
      if (side ? (price < worst) : (price > worst)) begin
        ref_evict++;
        return 1'b0;   // worse than a full book's worst -> drop the add
      end
    end
    ref_sh[ck(side, price)] = 64'(shares);
    if (n + 1 > N_LEVELS) begin
      worst = ref_worst(side);
      ref_sh.delete(ck(side, worst));
      ref_evict++;
    end
    return 1'b1;
  endfunction

  function automatic bit ref_reduce(bit side, int price, int shares);
    longint v;
    if (!ref_sh.exists(ck(side, price))) begin
      ref_miss++;
      return 1'b0;
    end
    v = ref_sh[ck(side, price)] - 64'(shares);
    if (v <= 0) ref_sh.delete(ck(side, price));
    else        ref_sh[ck(side, price)] = v;
    return 1'b1;
  endfunction

  // Rebuild the expected sorted, zero-padded snapshot for both sides.
  function automatic void ref_snap();
    for (int s = 0; s < 2; s++) begin
      int keys[$];
      int k, i, j, best, tmp;
      bit side;
      side = (s == 1);
      keys = {};
      if (ref_sh.first(k) != 0) begin
        do begin
          if ((k % 2) == s) keys.push_back(k / 2);
        end while (ref_sh.next(k) != 0);
      end
      // Selection sort: bids descending, asks ascending.
      for (i = 0; i < keys.size(); i++) begin
        best = i;
        for (j = i + 1; j < keys.size(); j++)
          if (side ? (keys[j] > keys[best]) : (keys[j] < keys[best])) best = j;
        tmp = keys[i]; keys[i] = keys[best]; keys[best] = tmp;
      end
      if (keys.size() > N_LEVELS)
        $fatal(1, "reference model holds %0d levels on side %0d", keys.size(), s);
      for (i = 0; i < N_LEVELS; i++) begin
        if (i < keys.size()) begin
          exp_px [s][i] = 32'(keys[i]);
          exp_shr[s][i] = 32'(ref_sh[ck(side, keys[i])]);
        end else begin
          exp_px [s][i] = '0;
          exp_shr[s][i] = '0;
        end
      end
    end
  endfunction

  // ---------------------------------------------------------------- checking
  task automatic check(string name);
    if (upd_valid !== exp_changed)
      $fatal(1, "op %0d (%s): upd_valid=%0b, expected %0b",
             op_num, name, upd_valid, exp_changed);
    if (!exp_changed) return;

    ref_snap();

    if (upd.book_idx !== MY_IDX)
      $fatal(1, "op %0d (%s): upd.book_idx=%0d, expected %0d",
             op_num, name, upd.book_idx, MY_IDX);
    if (upd.timestamp !== exp_ts)
      $fatal(1, "op %0d (%s): upd.timestamp=%0d, expected %0d",
             op_num, name, upd.timestamp, exp_ts);

    for (int i = 0; i < N_LEVELS; i++) begin
      if (upd.bid_price[i] !== exp_px[1][i] || upd.bid_shares[i] !== exp_shr[1][i])
        $fatal(1, "op %0d (%s): bid[%0d]=(%0d,%0d), expected (%0d,%0d)",
               op_num, name, i, upd.bid_price[i], upd.bid_shares[i],
               exp_px[1][i], exp_shr[1][i]);
      if (upd.ask_price[i] !== exp_px[0][i] || upd.ask_shares[i] !== exp_shr[0][i])
        $fatal(1, "op %0d (%s): ask[%0d]=(%0d,%0d), expected (%0d,%0d)",
               op_num, name, i, upd.ask_price[i], upd.ask_shares[i],
               exp_px[0][i], exp_shr[0][i]);
    end
  endtask

  task automatic check_counts(string name);
    if (evict_count !== 32'(ref_evict))
      $fatal(1, "%s: evict_count=%0d, expected %0d", name, evict_count, ref_evict);
    if (reduce_miss_count !== 32'(ref_miss))
      $fatal(1, "%s: reduce_miss_count=%0d, expected %0d",
             name, reduce_miss_count, ref_miss);
  endtask

  // --------------------------------------------------------------- stimulus
  // Drives one op and checks the resulting snapshot. Entered and left on a
  // falling edge, so consecutive calls issue one op per cycle back-to-back.
  task automatic do_op(book_op_e o, bit side, int px, int sh, string name);
    op.op       = o;
    op.book_idx = MY_IDX;
    op.side     = side;
    op.price    = 32'(px);
    op.shares   = 32'(sh);
    op_valid    = 1'b1;
    ts          = ts + 64'd1;
    timestamp_in = ts;
    exp_ts       = ts;
    op_num++;
    exp_changed = (o == OP_ADD) ? ref_add(side, px, sh) : ref_reduce(side, px, sh);
    @(posedge clk);
    @(negedge clk);
    op_valid = 1'b0;   // re-asserted immediately by a following do_op call
    check(name);
  endtask

  task automatic idle(int n);
    op_valid = 1'b0;
    repeat (n) @(negedge clk);
  endtask

  // Full reset of DUT and reference model.
  task automatic do_reset();
    op_valid = 1'b0;
    rst_n    = 1'b0;
    repeat (3) @(negedge clk);
    rst_n    = 1'b1;
    @(negedge clk);
    ref_sh.delete();
    ref_evict = 0;
    ref_miss  = 0;
    if (upd_valid !== 1'b0)         $fatal(1, "upd_valid asserted after reset");
    if (evict_count !== 32'd0)      $fatal(1, "evict_count nonzero after reset");
    if (reduce_miss_count !== 32'd0)$fatal(1, "reduce_miss_count nonzero after reset");
    if (crossed_count !== 32'd0)    $fatal(1, "crossed_count nonzero after reset");
  endtask

  // ------------------------------------------------------------- test body
  int    r_op, r_side, r_px, r_sh;
  string nm;

  initial begin
    op     = '0;
    ts     = 64'd0;
    op_num = 0;

    // ---------------------------------------------------------- directed
    // test_add_creates_level
    do_reset();
    do_op(OP_ADD, 1'b1, 100, 10, "add creates level");
    idle(1);
    check_counts("add creates level");

    // test_same_price_add_aggregates
    do_reset();
    do_op(OP_ADD, 1'b1, 100, 10, "aggregate a");
    do_op(OP_ADD, 1'b1, 100,  5, "aggregate b");   // back-to-back, no gap
    idle(1);
    if (upd.bid_price[0] !== 32'd100 || upd.bid_shares[0] !== 32'd15)
      $fatal(1, "aggregate: bid[0]=(%0d,%0d), expected (100,15)",
             upd.bid_price[0], upd.bid_shares[0]);

    // test_bids_sort_descending -- insert at top, then middle
    do_reset();
    do_op(OP_ADD, 1'b1, 100, 10, "bid desc a");
    do_op(OP_ADD, 1'b1, 300,  5, "bid desc b");
    do_op(OP_ADD, 1'b1, 200,  7, "bid desc c");
    idle(1);

    // test_asks_sort_ascending
    do_reset();
    do_op(OP_ADD, 1'b0, 300,  5, "ask asc a");
    do_op(OP_ADD, 1'b0, 100, 10, "ask asc b");
    do_op(OP_ADD, 1'b0, 200,  7, "ask asc c");
    idle(1);

    // test_ninth_level_evicts_worst
    do_reset();
    for (int i = 0; i < 8; i++)
      do_op(OP_ADD, 1'b1, 100 + i, 1, $sformatf("fill bid %0d", i));
    check_counts("book full, no evictions yet");
    do_op(OP_ADD, 1'b1, 150, 1, "9th level evicts worst");
    idle(1);
    check_counts("9th level evicts worst");
    if (evict_count !== 32'd1) $fatal(1, "expected evict_count 1, got %0d", evict_count);
    for (int i = 0; i < N_LEVELS; i++)
      if (upd.bid_price[i] === 32'd100)
        $fatal(1, "evicted price 100 still present at level %0d", i);

    // test_add_worse_than_full_book_worst_is_dropped
    do_reset();
    for (int i = 0; i < 8; i++)
      do_op(OP_ADD, 1'b1, 200 + i, 1, $sformatf("fill bid2 %0d", i));
    do_op(OP_ADD, 1'b1, 50, 1, "add worse than full worst");  // no upd expected
    idle(1);
    check_counts("add worse than full worst");
    if (evict_count !== 32'd1) $fatal(1, "expected evict_count 1, got %0d", evict_count);

    // Same on the ask side (worse = higher price).
    do_reset();
    for (int i = 0; i < 8; i++)
      do_op(OP_ADD, 1'b0, 200 + i, 1, $sformatf("fill ask %0d", i));
    do_op(OP_ADD, 1'b0, 999, 1, "ask worse than full worst");
    do_op(OP_ADD, 1'b0, 150, 1, "ask better than full worst evicts");
    idle(1);
    check_counts("ask full-book cases");
    if (evict_count !== 32'd2) $fatal(1, "expected evict_count 2, got %0d", evict_count);

    // test_reduce_to_zero_removes_level_and_shifts
    do_reset();
    do_op(OP_ADD, 1'b1, 300,  5, "reduce-shift add a");
    do_op(OP_ADD, 1'b1, 200,  7, "reduce-shift add b");
    do_op(OP_ADD, 1'b1, 100, 10, "reduce-shift add c");
    do_op(OP_REDUCE, 1'b1, 300, 5, "reduce to zero shifts up");
    idle(1);
    if (upd.bid_price[0] !== 32'd200 || upd.bid_shares[0] !== 32'd7 ||
        upd.bid_price[1] !== 32'd100 || upd.bid_shares[1] !== 32'd10 ||
        upd.bid_price[2] !== 32'd0   || upd.bid_shares[2] !== 32'd0)
      $fatal(1, "reduce-to-zero shift wrong: (%0d,%0d) (%0d,%0d) (%0d,%0d)",
             upd.bid_price[0], upd.bid_shares[0], upd.bid_price[1],
             upd.bid_shares[1], upd.bid_price[2], upd.bid_shares[2]);

    // Partial reduce leaves the level in place.
    do_op(OP_REDUCE, 1'b1, 200, 3, "partial reduce");
    idle(1);
    if (upd.bid_price[0] !== 32'd200 || upd.bid_shares[0] !== 32'd4)
      $fatal(1, "partial reduce: bid[0]=(%0d,%0d), expected (200,4)",
             upd.bid_price[0], upd.bid_shares[0]);

    // Over-reduce (reduce shares > level shares) still removes exactly one
    // level and clamps at zero -- Python's `<= 0 -> pop`.
    do_op(OP_REDUCE, 1'b1, 200, 999, "over-reduce clamps");
    idle(1);
    if (upd.bid_price[0] !== 32'd100 || upd.bid_shares[0] !== 32'd10)
      $fatal(1, "over-reduce: bid[0]=(%0d,%0d), expected (100,10)",
             upd.bid_price[0], upd.bid_shares[0]);

    // test_reduce_at_unknown_price_counted_as_miss
    do_reset();
    do_op(OP_ADD, 1'b1, 100, 10, "miss setup add");
    do_op(OP_REDUCE, 1'b1, 999, 1, "reduce miss");   // no upd expected
    idle(1);
    check_counts("reduce miss");
    if (reduce_miss_count !== 32'd1)
      $fatal(1, "expected reduce_miss_count 1, got %0d", reduce_miss_count);
    // Reduce on a completely empty side is also a miss.
    do_op(OP_REDUCE, 1'b0, 100, 1, "reduce miss empty side");
    idle(1);
    check_counts("reduce miss empty side");

    // Ops on both sides interleaved, one per cycle with no idle gaps.
    do_reset();
    do_op(OP_ADD, 1'b1, 1804000, 100, "both a");
    do_op(OP_ADD, 1'b0, 1806000, 200, "both b");
    do_op(OP_ADD, 1'b1, 1805000,  50, "both c");
    do_op(OP_ADD, 1'b0, 1805500,  75, "both d");
    do_op(OP_REDUCE, 1'b1, 1805000, 50, "both e");
    do_op(OP_REDUCE, 1'b0, 1806000, 10, "both f");
    do_op(OP_ADD, 1'b1, 1805000,  10, "both g");
    idle(2);
    check_counts("both sides");
    if (crossed_count !== 32'd0)
      $fatal(1, "uncrossed book reported crossed_count %0d", crossed_count);

    // Crossing is counted, never fatal.
    do_op(OP_ADD, 1'b0, 1000, 5, "cross the book");
    idle(1);
    if (crossed_count === 32'd0)
      $fatal(1, "crossed book did not increment crossed_count");

    $display("  directed cases: ok (%0d ops)", op_num);

    // ------------------------------------------------------------ random
    do_reset();
    for (int n = 0; n < 10000; n++) begin
      r_op   = $urandom_range(1, 0);       // 0 = ADD, 1 = REDUCE
      r_side = $urandom_range(1, 0);
      r_px   = (90 + $urandom_range(20, 0)) * 10000;
      r_sh   = 1 + $urandom_range(499, 0);
      nm     = "random";
      do_op(r_op == 0 ? OP_ADD : OP_REDUCE, r_side[0], r_px, r_sh, nm);
    end
    idle(2);
    check_counts("random phase");
    $display("  random phase: ok (10000 ops, evict=%0d, reduce_miss=%0d, crossed=%0d)",
             evict_count, reduce_miss_count, crossed_count);

    $display("PASS");
    $finish;
  end

  // Watchdog: never let a broken DUT hang the run. 10k ops at 10ns plus the
  // directed phase fits comfortably inside 1ms.
  initial begin
    #1000000;
    $fatal(1, "TIMEOUT");
  end

endmodule
