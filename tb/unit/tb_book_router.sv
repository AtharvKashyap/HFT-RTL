// Unit testbench for book_router.
//
// Phase 1 -- directed cases covering the symbol filter, every message kind, the
// resting-price lookup path, hash collisions resolved by linear probing and a
// deliberately over-filled probe window (table full).
//
// Phase 2 -- 5,000 constrained-random messages checked against a scoreboard
// built from associative arrays that mirrors model/book.py's
// MarketModel.on_message order-ID table exactly (same free/keep decisions, same
// drop accounting, same REPLACE reduce-then-add op pair).
//
// Phase 3 -- capacity: 120,000 messages that grow the table to ~45,000 live
// entries (the real capture's AAPL+MSFT peak is 42,190) and then churn on top of
// them, proving TABLE_ADDR_W is sized for the real feed and that accumulated
// deletion tombstones never turn a live entry into a lookup miss.
//
// All phases compare EVERY emitted op (op kind, book_idx, side, price, shares)
// against a FIFO of expected ops, and cross-check drop_count /
// table_full_count / occupancy.
//
// Timing contract under test: the DUT accepts a table-touching message presented
// with in_valid while !busy, then runs a multi-cycle probe FSM; a separate
// checker fails if one message ever keeps it busy for more than 19 cycles. Ops
// appear as registered one-cycle out_valid pulses, so REPLACE's REDUCE and ADD
// are necessarily on different cycles (a single out_valid cannot carry two ops).
// MSG_SYSTEM is the exception and is deliberately driven WHILE busy in one
// directed case: a 12-byte System Event leaves only 14 idle cycles behind it, so
// the DUT must absorb it without disturbing the message in flight.
//
// Inputs are driven and outputs sampled on the falling edge; timescale comes
// from the Makefile (--timescale 1ns/1ps).

module tb_book_router;
  import book_pkg::*;

  // 8-char space-padded ASCII, first character in the most significant byte --
  // the packing itch_decoder produces for decoded_msg_t.symbol.
  localparam logic [63:0] SYM_LIST [NUM_SYMBOLS] =
      '{0: "AAPL    ", 1: "MSFT    ", default: 64'd0};

  localparam logic [63:0] SYM_AAPL = "AAPL    ";
  localparam logic [63:0] SYM_MSFT = "MSFT    ";
  localparam logic [63:0] SYM_GOOG = "GOOG    ";   // untracked
  localparam logic [63:0] SYM_TSLA = "TSLA    ";   // untracked

  // Three independent hash chains for the collision / table-full cases. Their
  // folds are 0x1000 / 0x2000 / 0x3000 for any TABLE_ADDR_W >= 14, i.e. far
  // enough apart that the chains never overlap (checked at run time below).
  localparam logic [63:0] BASE_A = 64'h0000_0000_0000_1000;
  localparam logic [63:0] BASE_B = 64'h0000_0000_0000_2000;
  localparam logic [63:0] BASE_C = 64'h0000_0000_0000_3000;

  logic         clk;
  logic         rst_n = 1'b0;
  decoded_msg_t in_msg;
  logic         in_valid = 1'b0;
  book_op_t     out_op;
  logic         out_valid;
  logic         busy;
  logic [31:0]  drop_count;
  logic [31:0]  table_full_count;
  logic [31:0]  occupancy;

  book_router #(.SYMBOLS(SYM_LIST)) dut (
    .clk              (clk),
    .rst_n            (rst_n),
    .in_msg           (in_msg),
    .in_valid         (in_valid),
    .out_op           (out_op),
    .out_valid        (out_valid),
    .busy             (busy),
    .drop_count       (drop_count),
    .table_full_count (table_full_count),
    .occupancy        (occupancy)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  // Cycle counter, for error messages only.
  int cyc;
  always @(posedge clk) begin
    if (!rst_n) cyc <= 0;
    else        cyc <= cyc + 1;
  end

  // The byte-wide upstream guarantees >= 19 idle cycles between messages, so a
  // single message must never keep the DUT busy for longer than that. Enabled
  // once the post-reset table-clear sweep (legitimately 2**TABLE_ADDR_W cycles
  // of busy) has finished.
  localparam int MAX_BUSY_CYCLES = 19;
  bit watch_busy = 1'b0;
  int busy_run;

  always @(posedge clk) begin
    if (!rst_n) begin
      busy_run <= 0;
    end else if (busy) begin
      if (watch_busy && busy_run >= MAX_BUSY_CYCLES)
        $fatal(1, "cycle %0d: busy held for %0d cycles, contract allows %0d",
               cyc, busy_run + 1, MAX_BUSY_CYCLES);
      busy_run <= busy_run + 1;
    end else begin
      busy_run <= 0;
    end
  end

  // ------------------------------------------------------- scoreboard state
  // order_id -> {book_idx, side, price, remaining shares}, i.e. Python's
  // MarketModel.orders dict. Presence in sb_idx is the "entry exists" test.
  int     sb_idx  [longint unsigned];
  bit     sb_side [longint unsigned];
  longint sb_px   [longint unsigned];
  longint sb_sh   [longint unsigned];

  int ref_drop;
  int ref_full;
  int ops_seen;
  int msg_num;

  // Expected op FIFO.
  book_op_t exp_ops   [$];
  string    exp_names [$];

  function automatic void sb_put(longint unsigned id, int idx, bit sd,
                                 longint px, longint sh);
    sb_idx [id] = idx;
    sb_side[id] = sd;
    sb_px  [id] = px;
    sb_sh  [id] = sh;
  endfunction

  function automatic void sb_del(longint unsigned id);
    sb_idx.delete(id);
    sb_side.delete(id);
    sb_px.delete(id);
    sb_sh.delete(id);
  endfunction

  function automatic void exp_push(book_op_e o, int idx, bit sd,
                                   longint px, longint sh, string name);
    book_op_t e;
    e.op       = o;
    e.book_idx = BOOK_IDX_W'(idx);
    e.side     = sd;
    e.price    = 32'(px);
    e.shares   = 32'(sh);
    exp_ops.push_back(e);
    exp_names.push_back(name);
  endfunction

  function automatic int sym_lookup(logic [63:0] s);
    for (int i = 0; i < NUM_SYMBOLS; i++)
      if (s != 64'd0 && s == SYM_LIST[i]) return i;
    return -1;
  endfunction

  // Mirror of MarketModel.on_message, order-ID-table half only (the price-book
  // half is price_book's problem): produces the op stream and the drops.
  function automatic void model_msg(decoded_msg_t m, string name);
    int              idx;
    bit              sd;
    longint unsigned oid, nid;
    longint          rem;

    oid = m.order_id;
    nid = m.new_order_id;

    case (m.kind)
      MSG_ADD: begin
        idx = sym_lookup(m.symbol);
        if (idx < 0) begin
          ref_drop++;                       // untracked symbol: no table insert
        end else begin
          exp_push(OP_ADD, idx, m.side, longint'(m.price), longint'(m.shares), name);
          sb_put(oid, idx, m.side, longint'(m.price), longint'(m.shares));
        end
      end

      MSG_EXEC, MSG_CANCEL: begin
        if (!sb_idx.exists(oid)) begin
          ref_drop++;
        end else begin
          exp_push(OP_REDUCE, sb_idx[oid], sb_side[oid], sb_px[oid],
                   longint'(m.shares), name);
          rem = sb_sh[oid] - longint'(m.shares);
          if (rem <= 0) sb_del(oid);        // Python frees at remaining <= 0
          else          sb_sh[oid] = rem;
        end
      end

      MSG_DELETE: begin
        if (!sb_idx.exists(oid)) begin
          ref_drop++;
        end else begin
          exp_push(OP_REDUCE, sb_idx[oid], sb_side[oid], sb_px[oid], sb_sh[oid], name);
          sb_del(oid);
        end
      end

      MSG_REPLACE: begin
        if (!sb_idx.exists(oid)) begin
          ref_drop++;
        end else begin
          idx = sb_idx [oid];
          sd  = sb_side[oid];
          exp_push(OP_REDUCE, idx, sd, sb_px[oid], sb_sh[oid], name);
          sb_del(oid);
          // New order inherits book_idx AND side from the replaced entry.
          exp_push(OP_ADD, idx, sd, longint'(m.price), longint'(m.shares), name);
          sb_put(nid, idx, sd, longint'(m.price), longint'(m.shares));
        end
      end

      default: ;   // MSG_SYSTEM: no op, no counter
    endcase
  endfunction

  // ---------------------------------------------------------------- monitor
  // out_valid/out_op are registered, so they are stable across the whole cycle
  // that follows the edge that produced them; sample on the falling edge.
  book_op_t mon_e;
  string    mon_n;

  initial forever begin
    @(negedge clk);
    if (rst_n && out_valid) begin
      ops_seen++;
      if (exp_ops.size() == 0)
        $fatal(1, "cycle %0d: unexpected op (op=%0d idx=%0d side=%0b px=%0d sh=%0d)",
               cyc, out_op.op, out_op.book_idx, out_op.side, out_op.price,
               out_op.shares);
      mon_e = exp_ops.pop_front();
      mon_n = exp_names.pop_front();
      if (out_op.op !== mon_e.op)
        $fatal(1, "op %0d (%s): op=%0d, expected %0d", ops_seen, mon_n,
               out_op.op, mon_e.op);
      if (out_op.book_idx !== mon_e.book_idx)
        $fatal(1, "op %0d (%s): book_idx=%0d, expected %0d", ops_seen, mon_n,
               out_op.book_idx, mon_e.book_idx);
      if (out_op.side !== mon_e.side)
        $fatal(1, "op %0d (%s): side=%0b, expected %0b", ops_seen, mon_n,
               out_op.side, mon_e.side);
      if (out_op.price !== mon_e.price)
        $fatal(1, "op %0d (%s): price=%0d, expected %0d", ops_seen, mon_n,
               out_op.price, mon_e.price);
      if (out_op.shares !== mon_e.shares)
        $fatal(1, "op %0d (%s): shares=%0d, expected %0d", ops_seen, mon_n,
               out_op.shares, mon_e.shares);
    end
  end

  // --------------------------------------------------------------- stimulus
  function automatic decoded_msg_t mk(msg_kind_e k, logic [63:0] oid,
                                      logic [63:0] nid, logic sd,
                                      logic [31:0] sh, logic [31:0] px,
                                      logic [63:0] sym);
    decoded_msg_t m;
    m              = '0;
    m.kind         = k;
    m.order_id     = oid;
    m.new_order_id = nid;
    m.side         = sd;
    m.shares       = sh;
    m.price        = px;
    m.symbol       = sym;
    return m;
  endfunction

  // Presents one message, then waits until the FSM is idle again and the last
  // registered op has been sampled by the monitor. Honours the "never assert
  // in_valid while busy" contract, which is stricter than the >=19 idle cycle
  // guarantee the byte-wide upstream provides.
  task automatic send_raw(decoded_msg_t m, int gap = 2);
    while (busy) @(negedge clk);
    in_msg   = m;
    in_valid = 1'b1;
    @(posedge clk);
    @(negedge clk);
    in_valid = 1'b0;
    in_msg   = '0;
    while (busy) @(negedge clk);
    repeat (gap + 1) @(negedge clk);
  endtask

  // Models the message (pushing expected ops) and then sends it.
  task automatic send(decoded_msg_t m, string name, int gap = 2);
    msg_num++;
    model_msg(m, name);
    send_raw(m, gap);
  endtask

  task automatic check_counts(string name);
    if (drop_count !== 32'(ref_drop))
      $fatal(1, "%s: drop_count=%0d, expected %0d", name, drop_count, ref_drop);
    if (table_full_count !== 32'(ref_full))
      $fatal(1, "%s: table_full_count=%0d, expected %0d", name,
             table_full_count, ref_full);
    if (exp_ops.size() != 0)
      $fatal(1, "%s: %0d expected ops never emitted (next: %s)", name,
             exp_ops.size(), exp_names[0]);
  endtask

  task automatic check_occupancy(string name, int exp_occ);
    if (occupancy !== 32'(exp_occ))
      $fatal(1, "%s: occupancy=%0d, expected %0d", name, occupancy, exp_occ);
  endtask

  // Full reset of DUT and scoreboard. The DUT clears its table after reset, so
  // wait for busy to fall before returning.
  task automatic do_reset();
    watch_busy = 1'b0;
    in_valid   = 1'b0;
    in_msg     = '0;
    rst_n      = 1'b0;
    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk);
    while (busy) @(negedge clk);
    repeat (2) @(negedge clk);
    sb_idx.delete();
    sb_side.delete();
    sb_px.delete();
    sb_sh.delete();
    exp_ops.delete();
    exp_names.delete();
    ref_drop = 0;
    ref_full = 0;
    watch_busy = 1'b1;
    if (out_valid !== 1'b0)        $fatal(1, "out_valid asserted after reset");
    if (drop_count !== 32'd0)      $fatal(1, "drop_count nonzero after reset");
    if (table_full_count !== 32'd0)$fatal(1, "table_full_count nonzero after reset");
    if (occupancy !== 32'd0)       $fatal(1, "occupancy nonzero after reset");
  endtask

  // Mirror of the DUT's XOR-fold hash, used only to craft colliding order ids.
  function automatic logic [TABLE_ADDR_W-1:0] fold(logic [63:0] id);
    logic [TABLE_ADDR_W-1:0] h, chunk;
    h = '0;
    for (int i = 0; i < 64; i += TABLE_ADDR_W) begin
      chunk = '0;
      for (int b = 0; b < TABLE_ADDR_W; b++)
        if (i + b < 64) chunk[b] = id[i+b];
      h ^= chunk;
    end
    return h;
  endfunction

  // Distinct order ids that all fold to the same slot as `base`, for ANY
  // TABLE_ADDR_W (as long as 2*TABLE_ADDR_W <= 64, checked below). The XOR-fold
  // is linear over GF(2), and (c << TABLE_ADDR_W) ^ c folds to c ^ c = 0, so
  // XOR-ing it into `base` leaves the fold untouched while changing the id.
  // Injective in c for c < 2**TABLE_ADDR_W, so distinct c give distinct ids.
  function automatic logic [63:0] collider(logic [63:0] base, int c);
    return base ^ ((64'(c) << TABLE_ADDR_W) ^ 64'(c));
  endfunction

  // ------------------------------------------------------------- test body
  logic [63:0] ids  [16];
  int          occ;
  int          pick;
  int          r;
  longint unsigned live [$];
  longint unsigned oid, nid, next_id;
  decoded_msg_t    m;
  logic [31:0]     px, sh;
  int              tracked_adds;
  int              peak_live;

  initial begin
    in_msg   = '0;
    ops_seen = 0;
    msg_num  = 0;
    next_id  = 64'd1;

    // The collider() construction needs two disjoint fold chunks, and the three
    // bases must be far enough apart that their probe windows cannot overlap.
    if (2 * TABLE_ADDR_W > 64)
      $fatal(1, "collider() needs 2*TABLE_ADDR_W <= 64, got %0d", TABLE_ADDR_W);
    if (fold(BASE_A) == fold(BASE_B) || fold(BASE_B) == fold(BASE_C) ||
        fold(BASE_A) == fold(BASE_C))
      $fatal(1, "collision bases share a fold (%h %h %h)",
             fold(BASE_A), fold(BASE_B), fold(BASE_C));
    if (fold(BASE_B) - fold(BASE_A) < TABLE_ADDR_W'(MAX_PROBES + 2) ||
        fold(BASE_C) - fold(BASE_B) < TABLE_ADDR_W'(MAX_PROBES + 2))
      $fatal(1, "collision bases are too close together");

    // ---------------------------------------------------------- directed
    do_reset();
    occ = 0;

    // System event: no op, no counter, no table change.
    send(mk(MSG_SYSTEM, 64'd0, 64'd0, 1'b0, 32'd0, 32'd0, 64'd0), "system event");
    check_counts("system event");
    check_occupancy("system event", occ);

    // ADD on a tracked symbol -> OP_ADD with the filtered book_idx.
    send(mk(MSG_ADD, 64'd101, 64'd0, 1'b1, 32'd100, 32'd1000000, SYM_AAPL),
         "add AAPL bid");
    occ++;
    check_occupancy("add AAPL bid", occ);

    send(mk(MSG_ADD, 64'd102, 64'd0, 1'b0, 32'd200, 32'd1005000, SYM_MSFT),
         "add MSFT ask");
    occ++;
    check_counts("add tracked symbols");
    check_occupancy("add MSFT ask", occ);

    // ADD on an untracked symbol -> no op, drop_count++, and NO table insert,
    // so any later message for that id also drops.
    send(mk(MSG_ADD, 64'd103, 64'd0, 1'b1, 32'd50, 32'd999, SYM_GOOG),
         "add untracked GOOG");
    check_counts("add untracked GOOG");
    check_occupancy("add untracked GOOG", occ);

    send(mk(MSG_EXEC, 64'd103, 64'd0, 1'b0, 32'd10, 32'd0, 64'd0),
         "exec on untracked id");
    check_counts("exec on untracked id");

    // Unknown order id -> drop.
    send(mk(MSG_EXEC, 64'hDEAD_BEEF_0000_0001, 64'd0, 1'b0, 32'd10, 32'd0, 64'd0),
         "exec unknown id");
    check_counts("exec unknown id");

    // EXEC resolves the resting price and partially decrements; a second EXEC
    // on the same id still resolves, with the reduced remaining shares.
    send(mk(MSG_EXEC, 64'd101, 64'd0, 1'b0, 32'd30, 32'd0, 64'd0), "exec partial 1");
    send(mk(MSG_EXEC, 64'd101, 64'd0, 1'b0, 32'd20, 32'd0, 64'd0), "exec partial 2");
    check_counts("exec partial");
    check_occupancy("exec partial", occ);

    // CANCEL behaves exactly like EXEC.
    send(mk(MSG_CANCEL, 64'd101, 64'd0, 1'b0, 32'd10, 32'd0, 64'd0), "cancel partial");
    check_counts("cancel partial");
    check_occupancy("cancel partial", occ);

    // An EXEC that exactly zeroes the remainder emits OP_REDUCE with the exec
    // shares and frees the entry (Python frees at remaining <= 0).
    send(mk(MSG_EXEC, 64'd101, 64'd0, 1'b0, 32'd40, 32'd0, 64'd0), "exec exact zero");
    occ--;
    check_counts("exec exact zero");
    check_occupancy("exec exact zero", occ);
    send(mk(MSG_EXEC, 64'd101, 64'd0, 1'b0, 32'd1, 32'd0, 64'd0), "exec after zeroed");
    check_counts("exec after zeroed");

    // DELETE emits the remaining shares at the resting price and frees.
    send(mk(MSG_DELETE, 64'd102, 64'd0, 1'b0, 32'd0, 32'd0, 64'd0), "delete MSFT");
    occ--;
    check_counts("delete MSFT");
    check_occupancy("delete MSFT", occ);
    send(mk(MSG_EXEC, 64'd102, 64'd0, 1'b0, 32'd5, 32'd0, 64'd0), "exec after delete");
    check_counts("exec after delete");

    // An over-sized EXEC (more shares than resting) also frees the entry.
    send(mk(MSG_ADD, 64'd110, 64'd0, 1'b1, 32'd10, 32'd1010000, SYM_AAPL),
         "add for over-exec");
    occ++;
    send(mk(MSG_EXEC, 64'd110, 64'd0, 1'b0, 32'd99, 32'd0, 64'd0), "over-exec frees");
    occ--;
    check_counts("over-exec");
    check_occupancy("over-exec", occ);

    // REPLACE: REDUCE at the old price for the full remaining, then ADD at the
    // new price with the book_idx AND side inherited from the old entry.
    send(mk(MSG_ADD, 64'd120, 64'd0, 1'b0, 32'd300, 32'd1020000, SYM_MSFT),
         "add for replace");
    occ++;
    send(mk(MSG_EXEC, 64'd120, 64'd0, 1'b0, 32'd100, 32'd0, 64'd0), "partial before replace");
    // Deliberately dirty the DUT's "last ADD" side/book_idx registers with the
    // OPPOSITE side and a DIFFERENT symbol, so the REPLACE below can only
    // produce the right book_idx/side by genuinely inheriting them from the
    // entry it looked up -- reusing stale registers or the message's own side
    // field both give a visibly wrong op.
    send(mk(MSG_ADD, 64'd130, 64'd0, 1'b1, 32'd7, 32'd1015000, SYM_AAPL),
         "add to dirty side/idx registers");
    occ++;
    // Note: shares/price of a REPLACE come from the message; side/idx inherited.
    // Message side is 1 while the replaced entry (order 120, MSFT) is side 0.
    send(mk(MSG_REPLACE, 64'd120, 64'd121, 1'b1, 32'd400, 32'd1030000, 64'd0),
         "replace 120 -> 121");
    check_counts("replace");
    check_occupancy("replace", occ);   // one freed, one inserted
    // The new id is now the live one at the new price; the old id is gone.
    send(mk(MSG_EXEC, 64'd121, 64'd0, 1'b0, 32'd400, 32'd0, 64'd0), "exec replaced id");
    occ--;
    send(mk(MSG_EXEC, 64'd120, 64'd0, 1'b0, 32'd1, 32'd0, 64'd0), "exec stale id");
    send(mk(MSG_DELETE, 64'd130, 64'd0, 1'b0, 32'd0, 32'd0, 64'd0), "delete dirtying add");
    occ--;
    check_counts("post-replace");
    check_occupancy("post-replace", occ);

    // REPLACE of an unknown id -> drop, nothing inserted.
    send(mk(MSG_REPLACE, 64'd199, 64'd198, 1'b1, 32'd10, 32'd1000, 64'd0),
         "replace unknown id");
    check_counts("replace unknown id");
    check_occupancy("replace unknown id", occ);

    // Hash collisions: two ids that fold to the same slot must both be
    // insertable and both resolvable through linear probing.
    ids[0] = collider(BASE_A, 1);
    ids[1] = collider(BASE_A, 2);
    if (fold(ids[0]) !== fold(ids[1]))
      $fatal(1, "crafted ids do not collide: %h vs %h", fold(ids[0]), fold(ids[1]));
    if (ids[0] === ids[1]) $fatal(1, "crafted colliding ids are identical");
    send(mk(MSG_ADD, ids[0], 64'd0, 1'b1, 32'd11, 32'd1040000, SYM_AAPL), "collide add 0");
    occ++;
    send(mk(MSG_ADD, ids[1], 64'd0, 1'b0, 32'd22, 32'd1050000, SYM_MSFT), "collide add 1");
    occ++;
    check_occupancy("collide adds", occ);
    // Resolve each one: the price/side/idx proves the right entry was found.
    send(mk(MSG_DELETE, ids[1], 64'd0, 1'b0, 32'd0, 32'd0, 64'd0), "collide delete 1");
    occ--;
    send(mk(MSG_DELETE, ids[0], 64'd0, 1'b0, 32'd0, 32'd0, 64'd0), "collide delete 0");
    occ--;
    check_counts("hash collisions");
    check_occupancy("hash collisions", occ);

    // A REPLACE whose lookup AND insert both have to probe: the replaced id
    // sits at the second slot of its chain, and the new id folds to the same
    // chain (so the insert probes past the surviving entry and the tombstone
    // the freed old entry leaves behind).
    ids[2] = collider(BASE_B, 1);
    ids[3] = collider(BASE_B, 2);
    ids[4] = collider(BASE_B, 3);
    if (fold(ids[2]) !== fold(ids[3]) || fold(ids[3]) !== fold(ids[4]))
      $fatal(1, "probing-replace ids do not collide");
    send(mk(MSG_ADD, ids[2], 64'd0, 1'b1, 32'd33, 32'd1080000, SYM_AAPL),
         "probing replace: add first");
    occ++;
    send(mk(MSG_ADD, ids[3], 64'd0, 1'b0, 32'd44, 32'd1090000, SYM_MSFT),
         "probing replace: add second");
    occ++;
    send(mk(MSG_REPLACE, ids[3], ids[4], 1'b1, 32'd55, 32'd1100000, 64'd0),
         "probing replace");
    check_occupancy("probing replace", occ);
    send(mk(MSG_EXEC, ids[4], 64'd0, 1'b0, 32'd55, 32'd0, 64'd0),
         "probing replace: exec new id");
    occ--;
    send(mk(MSG_DELETE, ids[2], 64'd0, 1'b0, 32'd0, 32'd0, 64'd0),
         "probing replace: delete first");
    occ--;
    check_counts("probing replace");
    check_occupancy("probing replace done", occ);

    // A SYSTEM message arriving WHILE the DUT is busy must be absorbed without
    // disturbing the message in flight and without tripping the DUT's
    // in_valid-while-busy assertion. This is not hypothetical: the framer leaves
    // only msg_len+2 = 14 idle cycles after a 12-byte 'S' System Event, which a
    // worst-case REPLACE (16 busy cycles) can still be occupying.
    send(mk(MSG_ADD, 64'd140, 64'd0, 1'b0, 32'd60, 32'd1110000, SYM_MSFT),
         "system-during-busy: setup add");
    occ++;
    m = mk(MSG_REPLACE, 64'd140, 64'd141, 1'b1, 32'd70, 32'd1120000, 64'd0);
    msg_num++;
    model_msg(m, "system-during-busy: replace");
    while (busy) @(negedge clk);
    in_msg   = m;
    in_valid = 1'b1;
    @(posedge clk);
    @(negedge clk);
    if (!busy) $fatal(1, "DUT not busy after accepting a REPLACE");
    // Hold a SYSTEM message on the input for the whole busy window.
    in_msg = mk(MSG_SYSTEM, 64'd0, 64'd0, 1'b0, 32'd0, 32'd0, 64'd0);
    while (busy) begin
      in_valid = 1'b1;
      @(posedge clk);
      @(negedge clk);
    end
    in_valid = 1'b0;
    in_msg   = '0;
    repeat (3) @(negedge clk);
    check_counts("system during busy");     // both REPLACE ops emitted intact
    check_occupancy("system during busy", occ);
    // The replaced order is live at its new id, so the FSM was not corrupted.
    send(mk(MSG_EXEC, 64'd141, 64'd0, 1'b0, 32'd70, 32'd0, 64'd0),
         "system-during-busy: exec new id");
    occ--;
    check_counts("system during busy done");
    check_occupancy("system during busy done", occ);

    // Fill the whole probe window with colliding ids, then one more: the extra
    // ADD is dropped and counted as table-full (not as a drop).
    for (int i = 0; i < MAX_PROBES; i++) begin
      ids[i] = collider(BASE_C, i + 1);
      if (fold(ids[i]) !== fold(BASE_C))
        $fatal(1, "table-full id %0d does not collide", i);
      send(mk(MSG_ADD, ids[i], 64'd0, 1'b1, 32'(10 + i), 32'd1060000, SYM_AAPL),
           $sformatf("fill probe window %0d", i));
      occ++;
    end
    check_counts("probe window filled");
    check_occupancy("probe window filled", occ);

    // One more colliding id: no op, table_full_count++, no insert.
    ids[8] = collider(BASE_C, MAX_PROBES + 1);
    msg_num++;
    send_raw(mk(MSG_ADD, ids[8], 64'd0, 1'b1, 32'd77, 32'd1070000, SYM_AAPL));
    ref_full++;
    check_counts("table full");
    check_occupancy("table full", occ);
    if (table_full_count !== 32'd1)
      $fatal(1, "expected table_full_count 1, got %0d", table_full_count);
    // Since it was never inserted, a later message for it drops.
    send(mk(MSG_EXEC, ids[8], 64'd0, 1'b0, 32'd1, 32'd0, 64'd0), "exec after table full");
    check_counts("exec after table full");

    // The entries that did fit are all still resolvable.
    for (int i = 0; i < MAX_PROBES; i++) begin
      send(mk(MSG_DELETE, ids[i], 64'd0, 1'b0, 32'd0, 32'd0, 64'd0),
           $sformatf("drain probe window %0d", i));
      occ--;
    end
    check_counts("probe window drained");
    check_occupancy("probe window drained", occ);
    if (occ != 0) $fatal(1, "directed phase leaked %0d entries", occ);

    $display("  directed cases: ok (%0d messages, %0d ops, drop=%0d, full=%0d)",
             msg_num, ops_seen, drop_count, table_full_count);

    // ------------------------------------------------------------ random
    do_reset();
    live.delete();
    tracked_adds = 0;

    for (int n = 0; n < 5000; n++) begin
      r = $urandom_range(99, 0);

      if (live.size() < 8 || r < 40) begin
        // ADD. Order ids are globally unique (real feeds never reuse a live
        // id), 15% of them on an untracked symbol.
        oid = {32'($urandom()), 32'(next_id)};
        next_id++;
        px  = 32'((90 + $urandom_range(20, 0)) * 10000);
        sh  = 32'(1 + $urandom_range(499, 0));
        if ($urandom_range(99, 0) < 15) begin
          m = mk(MSG_ADD, oid, 64'd0, 1'($urandom_range(1, 0)), sh, px,
                 ($urandom_range(1, 0) == 0) ? SYM_GOOG : SYM_TSLA);
          send(m, "random add untracked", $urandom_range(3, 0));
        end else begin
          m = mk(MSG_ADD, oid, 64'd0, 1'($urandom_range(1, 0)), sh, px,
                 ($urandom_range(1, 0) == 0) ? SYM_AAPL : SYM_MSFT);
          send(m, "random add tracked", $urandom_range(3, 0));
          live.push_back(oid);
          tracked_adds++;
        end
      end else if (r < 47) begin
        // Message for an id that was never inserted -> drop.
        oid = {32'h5EED_0000, 32'($urandom())} | 64'h8000_0000_0000_0000;
        if (sb_idx.exists(oid)) continue;
        case ($urandom_range(3, 0))
          0: m = mk(MSG_EXEC,    oid, 64'd0, 1'b0, 32'd10, 32'd0, 64'd0);
          1: m = mk(MSG_CANCEL,  oid, 64'd0, 1'b0, 32'd10, 32'd0, 64'd0);
          2: m = mk(MSG_DELETE,  oid, 64'd0, 1'b0, 32'd0,  32'd0, 64'd0);
          default: m = mk(MSG_REPLACE, oid, {32'hBAD0_0000, 32'($urandom())},
                          1'b0, 32'd10, 32'd1000000, 64'd0);
        endcase
        send(m, "random unknown id", $urandom_range(3, 0));
      end else if (r < 50) begin
        send(mk(MSG_SYSTEM, 64'd0, 64'd0, 1'b0, 32'd0, 32'd0, 64'd0),
             "random system", $urandom_range(3, 0));
      end else begin
        // Message against a live id.
        pick = $urandom_range(live.size() - 1, 0);
        oid  = live[pick];
        case ($urandom_range(9, 0))
          0, 1, 2, 3: begin   // EXEC: exact / over / partial share counts
            case ($urandom_range(3, 0))
              0:       sh = 32'(sb_sh[oid]);                        // exact zero
              1:       sh = 32'(sb_sh[oid] + $urandom_range(50, 1)); // over
              default: sh = 32'(1 + $urandom_range(int'(sb_sh[oid]), 0));
            endcase
            send(mk(MSG_EXEC, oid, 64'd0, 1'b0, sh, 32'd0, 64'd0),
                 "random exec", $urandom_range(3, 0));
            if (!sb_idx.exists(oid)) live.delete(pick);
          end
          4, 5: begin         // CANCEL
            sh = 32'(1 + $urandom_range(int'(sb_sh[oid]), 0));
            send(mk(MSG_CANCEL, oid, 64'd0, 1'b0, sh, 32'd0, 64'd0),
                 "random cancel", $urandom_range(3, 0));
            if (!sb_idx.exists(oid)) live.delete(pick);
          end
          6, 7: begin         // DELETE
            send(mk(MSG_DELETE, oid, 64'd0, 1'b0, 32'd0, 32'd0, 64'd0),
                 "random delete", $urandom_range(3, 0));
            live.delete(pick);
          end
          default: begin      // REPLACE
            nid = {32'($urandom()), 32'(next_id)};
            next_id++;
            px  = 32'((90 + $urandom_range(20, 0)) * 10000);
            sh  = 32'(1 + $urandom_range(499, 0));
            send(mk(MSG_REPLACE, oid, nid, 1'($urandom_range(1, 0)), sh, px, 64'd0),
                 "random replace", $urandom_range(3, 0));
            live.delete(pick);
            live.push_back(nid);
          end
        endcase
      end
    end

    repeat (4) @(negedge clk);
    check_counts("random phase");
    // 5,000 messages over a 65,536-entry table never exhaust an 8-deep probe
    // window, so every insert must have succeeded and occupancy must equal the
    // scoreboard's live-entry count.
    if (table_full_count !== 32'd0)
      $fatal(1, "random phase hit table_full_count=%0d", table_full_count);
    check_occupancy("random phase", sb_idx.num());
    if (live.size() != sb_idx.num())
      $fatal(1, "live queue (%0d) out of step with scoreboard (%0d)",
             live.size(), sb_idx.num());
    if (tracked_adds < 100)
      $fatal(1, "random phase only issued %0d tracked adds", tracked_adds);

    $display("  random phase: ok (%0d messages, %0d ops total, drop=%0d, occupancy=%0d)",
             msg_num, ops_seen, drop_count, occupancy);

    // ------------------------------------------------------------ capacity
    // TABLE_ADDR_W is sized for the real capture, whose AAPL+MSFT order flow
    // peaks at 42,190 simultaneously live orders. This phase reproduces that
    // pressure -- grow to ~45,000 live entries, then churn 75,000 more messages
    // so tombstones accumulate on top of them -- and requires that NOTHING
    // degrades: no table-full ADD drops, no lookup ever mistaking a tombstoned
    // probe chain for a miss (drop_count must still match the scoreboard, which
    // knows nothing about probe geometry), and occupancy exactly equal to the
    // live-entry count. Deliberately runs on top of the random phase's leftover
    // state rather than resetting, to avoid a second 2**TABLE_ADDR_W clear sweep.
    peak_live = 0;
    for (int n = 0; n < 45000; n++) begin
      oid = {32'($urandom()), 32'(next_id)};
      next_id++;
      send(mk(MSG_ADD, oid, 64'd0, 1'($urandom_range(1, 0)),
              32'(1 + $urandom_range(499, 0)),
              32'((90 + $urandom_range(20, 0)) * 10000),
              ($urandom_range(1, 0) == 0) ? SYM_AAPL : SYM_MSFT),
           "capacity add", 0);
      live.push_back(oid);
      if (live.size() > peak_live) peak_live = live.size();
    end
    check_counts("capacity fill");
    check_occupancy("capacity fill", sb_idx.num());

    for (int n = 0; n < 75000; n++) begin
      if ($urandom_range(1, 0) == 0) begin
        oid = {32'($urandom()), 32'(next_id)};
        next_id++;
        send(mk(MSG_ADD, oid, 64'd0, 1'($urandom_range(1, 0)),
                32'(1 + $urandom_range(499, 0)),
                32'((90 + $urandom_range(20, 0)) * 10000),
                ($urandom_range(1, 0) == 0) ? SYM_AAPL : SYM_MSFT),
             "capacity churn add", 0);
        live.push_back(oid);
        if (live.size() > peak_live) peak_live = live.size();
      end else begin
        pick = $urandom_range(live.size() - 1, 0);
        oid  = live[pick];
        send(mk(MSG_DELETE, oid, 64'd0, 1'b0, 32'd0, 32'd0, 64'd0),
             "capacity churn delete", 0);
        // Unordered removal: order in `live` is irrelevant and this keeps the
        // churn loop O(1) per message instead of O(live.size()).
        live[pick] = live[live.size()-1];
        void'(live.pop_back());
      end
    end

    repeat (4) @(negedge clk);
    check_counts("capacity phase");
    if (table_full_count !== 32'd0)
      $fatal(1, "capacity phase hit table_full_count=%0d (peak live %0d in %0d slots)",
             table_full_count, peak_live, 1 << TABLE_ADDR_W);
    check_occupancy("capacity phase", sb_idx.num());
    if (live.size() != sb_idx.num())
      $fatal(1, "live queue (%0d) out of step with scoreboard (%0d)",
             live.size(), sb_idx.num());
    $display("  capacity phase: ok (120000 messages, peak live %0d of %0d slots, drop=%0d, occupancy=%0d)",
             peak_live, 1 << TABLE_ADDR_W, drop_count, occupancy);

    $display("PASS");
    $finish;
  end

  // Watchdog. The table-clear sweep after each reset costs 2^TABLE_ADDR_W
  // cycles, and there are two resets, so allow generously.
  initial begin
    #100000000;
    $fatal(1, "TIMEOUT");
  end

endmodule
