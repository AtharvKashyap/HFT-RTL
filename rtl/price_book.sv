// price_book -- single-cycle top-8 price-level book for one symbol.
//
// Implements the project's "Book semantics" contract verbatim, bit-matching
// model/book.py's PriceBook:
//
//   * Per side up to N_LEVELS (price, shares) levels; bids sorted descending,
//     asks ascending; index 0 = best; invalid levels read as all-zeros.
//   * ADD  : price already present -> aggregate shares. Otherwise sorted
//            insert. A 9th level pushes the (new) worst level out permanently
//            and counts an evict. An add that is worse than a full book's
//            worst level is dropped and counts an evict.
//   * REDUCE: price present -> shares -= ; result <= 0 removes the level and
//            shifts the levels below it up. Price absent -> drop and count a
//            reduce_miss.
//   * A full both-side snapshot is emitted only for ops that changed the book;
//            dropped ops emit nothing.
//
// Throughput: one op accepted every cycle. The next state is computed purely
// combinationally (parallel per-level comparators, a priority insert network
// and a shift-down / shift-up / in-place add-sub datapath) and registered on
// the same edge that absorbs the op. `upd` is registered from that same next
// state, so `upd`/`upd_valid` are visible during the following cycle.
//
// Reduce shares may legitimately exceed the level's resting shares (the RTL
// sees per-order reduces against an aggregated level). `shares <= op.shares`
// removes the level, which is exactly Python's `level[1] -= shares; if <= 0:
// pop` for the value ranges in play -- no underflow is ever registered.
module price_book #(parameter logic [book_pkg::BOOK_IDX_W-1:0] MY_IDX = '0) (
  input  logic                   clk, rst_n,
  input  book_pkg::book_op_t     op,
  input  logic                   op_valid,      // one op per cycle accepted
  input  logic [63:0]            timestamp_in,
  output book_pkg::book_update_t upd,
  output logic                   upd_valid,     // 1-cycle pulse when book changed
  output logic [31:0]            evict_count,
  output logic [31:0]            reduce_miss_count,
  output logic [31:0]            crossed_count  // debug: bid[0] >= ask[0] seen
);

  import book_pkg::*;

  localparam int N  = N_LEVELS;
  localparam int IW = $clog2(N);

  // ------------------------------------------------------------------ state
  logic [N-1:0][31:0] bid_price_q, bid_shares_q;
  logic [N-1:0][31:0] ask_price_q, ask_shares_q;
  logic [N-1:0]       bid_vld_q,   ask_vld_q;

  // The op touches exactly one side, so a single update datapath is shared:
  // mux the addressed side in, demux the result back out.
  logic [N-1:0][31:0] cur_price, cur_shares;
  logic [N-1:0]       cur_vld;

  always_comb begin
    if (op.side) begin
      cur_price  = bid_price_q;
      cur_shares = bid_shares_q;
      cur_vld    = bid_vld_q;
    end else begin
      cur_price  = ask_price_q;
      cur_shares = ask_shares_q;
      cur_vld    = ask_vld_q;
    end
  end

  // -------------------------------------------------------- compare network
  logic [N-1:0] match;   // valid level at exactly op.price
  logic [N-1:0] better;  // op.price strictly better than this level's price
  logic [N-1:0] cand;    // legal sorted-insert position
  logic         full;

  always_comb begin
    for (int i = 0; i < N; i++) begin
      match[i]  = cur_vld[i] && (cur_price[i] == op.price);
      better[i] = op.side ? (op.price > cur_price[i]) : (op.price < cur_price[i]);
      // The first free slot is also a legal insert position (vld is contiguous
      // from index 0, so it marks the end of the list -> append).
      cand[i]   = !cur_vld[i] || better[i];
    end
  end

  assign full = cur_vld[N-1];

  // Priority encoders: lowest set index wins (reverse loop, last write sticks).
  logic [IW-1:0] match_idx, ins_idx;
  logic          match_any, cand_any;

  always_comb begin
    match_idx = '0;
    match_any = 1'b0;
    ins_idx   = '0;
    cand_any  = 1'b0;
    for (int i = N - 1; i >= 0; i--) begin
      if (match[i]) begin
        match_idx = IW'(i);
        match_any = 1'b1;
      end
      if (cand[i]) begin
        ins_idx  = IW'(i);
        cand_any = 1'b1;
      end
    end
  end

  // ------------------------------------------------------------- next state
  logic [N-1:0][31:0] nxt_price, nxt_shares;
  logic [N-1:0]       nxt_vld;
  logic               changed, do_evict, do_miss;

  always_comb begin
    nxt_price  = cur_price;
    nxt_shares = cur_shares;
    nxt_vld    = cur_vld;
    changed    = 1'b0;
    do_evict   = 1'b0;
    do_miss    = 1'b0;

    if (op_valid) begin
      if (op.op == OP_ADD) begin
        if (match_any) begin
          // Existing price level: aggregate. Unlike Python's unbounded int this
          // wraps at 2^32; a wrapped-small total would then let the next reduce
          // delete the level early. Unreachable at real ITCH share volumes, and
          // guarding it would itself diverge from model/book.py.
          nxt_shares[match_idx] = cur_shares[match_idx] + op.shares;
          changed               = 1'b1;
        end else if (!cand_any) begin
          // Full book and op.price is worse than every level -> drop + evict.
          // (cand_any can only be 0 when the book is full.)
          do_evict = 1'b1;
        end else begin
          // Sorted insert at ins_idx: shift levels at and below it down one.
          for (int i = 0; i < N; i++) begin
            if (i == int'(ins_idx)) begin
              nxt_price[i]  = op.price;
              nxt_shares[i] = op.shares;
              nxt_vld[i]    = 1'b1;
            end else if (i > int'(ins_idx)) begin
              nxt_price[i]  = cur_price[i-1];
              nxt_shares[i] = cur_shares[i-1];
              nxt_vld[i]    = cur_vld[i-1];
            end
          end
          changed  = 1'b1;
          // Inserting into a full book pushes the old worst level off the end
          // and discards it permanently.
          do_evict = full;
        end
      end else begin  // OP_REDUCE
        if (!match_any) begin
          do_miss = 1'b1;
        end else if (cur_shares[match_idx] <= op.shares) begin
          // Level exhausted: remove it, shift everything below it up.
          for (int i = 0; i < N; i++) begin
            if (i >= int'(match_idx)) begin
              if (i == N - 1) begin
                nxt_price[i]  = '0;
                nxt_shares[i] = '0;
                nxt_vld[i]    = 1'b0;
              end else begin
                nxt_price[i]  = cur_price[i+1];
                nxt_shares[i] = cur_shares[i+1];
                nxt_vld[i]    = cur_vld[i+1];
              end
            end
          end
          changed = 1'b1;
        end else begin
          nxt_shares[match_idx] = cur_shares[match_idx] - op.shares;
          changed               = 1'b1;
        end
      end
    end
  end

  // Demux the shared datapath result back onto both sides.
  logic [N-1:0][31:0] nb_price, nb_shares, na_price, na_shares;
  logic [N-1:0]       nb_vld,   na_vld;

  always_comb begin
    nb_price  = bid_price_q;
    nb_shares = bid_shares_q;
    nb_vld    = bid_vld_q;
    na_price  = ask_price_q;
    na_shares = ask_shares_q;
    na_vld    = ask_vld_q;
    if (op.side) begin
      nb_price  = nxt_price;
      nb_shares = nxt_shares;
      nb_vld    = nxt_vld;
    end else begin
      na_price  = nxt_price;
      na_shares = nxt_shares;
      na_vld    = nxt_vld;
    end
  end

  // Real feeds cross momentarily around opens/halts, so a crossed book is
  // counted rather than asserted.
  logic crossed_nxt;
  assign crossed_nxt = nb_vld[0] && na_vld[0] && (nb_price[0] >= na_price[0]);

  // -------------------------------------------------------------- registers
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      bid_price_q       <= '0;
      bid_shares_q      <= '0;
      bid_vld_q         <= '0;
      ask_price_q       <= '0;
      ask_shares_q      <= '0;
      ask_vld_q         <= '0;
      upd               <= '0;
      upd_valid         <= 1'b0;
      evict_count       <= '0;
      reduce_miss_count <= '0;
      crossed_count     <= '0;
    end else begin
      bid_price_q  <= nb_price;
      bid_shares_q <= nb_shares;
      bid_vld_q    <= nb_vld;
      ask_price_q  <= na_price;
      ask_shares_q <= na_shares;
      ask_vld_q    <= na_vld;

      upd_valid <= changed;
      if (changed) begin
        upd.book_idx   <= MY_IDX;
        upd.bid_price  <= nb_price;
        upd.bid_shares <= nb_shares;
        upd.ask_price  <= na_price;
        upd.ask_shares <= na_shares;
        upd.timestamp  <= timestamp_in;
      end

      if (do_evict) evict_count       <= evict_count       + 32'd1;
      if (do_miss)  reduce_miss_count <= reduce_miss_count + 32'd1;
      if (changed && crossed_nxt) crossed_count <= crossed_count + 32'd1;
    end
  end

  // ------------------------------------------------------------- assertions
`ifndef SYNTHESIS
  // Checked on the state about to be registered, so every state the book ever
  // holds is covered. Strict inequality also proves "no duplicate prices".
  always_ff @(posedge clk) begin
    if (rst_n) begin
      for (int i = 0; i < N - 1; i++) begin
        if (nb_vld[i+1] && !nb_vld[i])
          $fatal(1, "price_book: bid vld not contiguous at level %0d", i);
        if (na_vld[i+1] && !na_vld[i])
          $fatal(1, "price_book: ask vld not contiguous at level %0d", i);
        if (nb_vld[i] && nb_vld[i+1] && !(nb_price[i] > nb_price[i+1]))
          $fatal(1, "price_book: bids not strictly descending at level %0d (%0d, %0d)",
                 i, nb_price[i], nb_price[i+1]);
        if (na_vld[i] && na_vld[i+1] && !(na_price[i] < na_price[i+1]))
          $fatal(1, "price_book: asks not strictly ascending at level %0d (%0d, %0d)",
                 i, na_price[i], na_price[i+1]);
      end
      for (int i = 0; i < N; i++) begin
        if (!nb_vld[i] && (nb_price[i] != '0 || nb_shares[i] != '0))
          $fatal(1, "price_book: invalid bid level %0d is not zeroed", i);
        if (!na_vld[i] && (na_price[i] != '0 || na_shares[i] != '0))
          $fatal(1, "price_book: invalid ask level %0d is not zeroed", i);
        // A valid level with zero shares is deliberately NOT an error: ITCH can
        // carry a zero-share add, itch_decoder passes it through unfiltered, and
        // model/book.py's PriceBook inserts [price, 0] and reports changed. The
        // RTL produces the identical state, and per the global "errors are never
        // fatal" rule it must keep running. A subsequent reduce at that price
        // removes the level (Python's `<= 0 -> pop`).
      end
    end
  end
`endif

endmodule
