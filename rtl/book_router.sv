// book_router -- symbol filter + hashed resting-order table.
//
// Sits between itch_decoder (decoded_msg_t) and the per-symbol price_book
// instances (book_op_t), and owns the state that turns per-order ITCH messages
// into per-price-level book operations. It is the RTL twin of
// model/book.py's MarketModel.on_message order-ID table (`MarketModel.orders`),
// and matches it decision for decision:
//
//   * ADD    : symbol not in SYMBOLS -> drop_count++, no op, NO table insert
//              (so every later message for that order id also drops, exactly
//              like Python never putting it in `orders`). Tracked symbol ->
//              insert {order_id, book_idx, side, price, shares} and emit OP_ADD.
//   * EXEC   : lookup; reduce at the STORED resting price by the message's
//     CANCEL   shares; stored shares -= message shares; entry freed when the
//              remainder is <= 0 (including an exec that exactly zeroes it --
//              the OP_REDUCE still carries the message's shares).
//   * DELETE : lookup; OP_REDUCE for the full stored remaining shares; free.
//   * REPLACE: lookup; OP_REDUCE at the old price for the full stored remaining
//              and free the old entry, then insert new_order_id inheriting the
//              old entry's book_idx AND side with the message's price/shares and
//              emit OP_ADD. The two ops are emitted on different cycles.
//   * SYSTEM : nothing at all, not even a counter.
//   * Any lookup that misses (never-used slot reached, or MAX_PROBES exhausted
//     without an id match) -> drop_count++, no op.
//
// Table: (1<<TABLE_ADDR_W) entries in a single synchronous-read memory (one
// BRAM-shaped array, one read port with write-first bypass). The address is an
// XOR-fold of the 64-bit order id down to TABLE_ADDR_W bits; collisions are
// resolved by linear probing, one probe per cycle, at most MAX_PROBES probes.
// An ADD whose entire probe window is occupied is dropped and counted in
// table_full_count (not drop_count) -- a capacity event, not a feed error.
// Errors are never fatal: everything is count-and-continue.
//
// Duplicate live order ids: a probe that finds a slot already holding the same
// order id overwrites it in place (matching Python's `orders[id] = ...`), and
// because that slot is necessarily reached before any free slot when the table
// has no holes, a re-added id updates its entry rather than growing occupancy.
// Real feeds never reuse a live id, so this is a robustness path only.
//
// Timing: one table-touching message at a time. The FSM raises `busy` from the
// cycle after a message is accepted until it is done. The worst case is 16 busy
// cycles (a REPLACE probing MAX_PROBES for the lookup and again for the insert),
// and the byte-wide upstream leaves msg_len+2 idle cycles after a message, i.e.
// >= 19 for every message kind that reaches the table (the shortest is the
// 19-byte 'D' Delete). An assertion catches any violation in simulation.
//
// MSG_SYSTEM is the one exception and is accepted UNCONDITIONALLY, even while
// busy: a 12-byte 'S' System Event leaves only 14 idle cycles behind it, which a
// worst-case REPLACE can still be occupying. That is safe precisely because
// SYSTEM touches nothing -- no table access, no op, no counter, no latched
// state -- so it needs no FSM cycle and cannot disturb a message in flight. The
// busy assertion is therefore scoped to non-SYSTEM messages.
//
// After reset the table is cleared by a sweep that writes every entry once, so
// `busy` stays high for 1<<TABLE_ADDR_W cycles before the first message can be
// accepted. INTEGRATION REQUIREMENT: this interface has no backpressure, so the
// top level must hold the byte feed into itch_decoder (or its reset) until
// `busy` falls after reset -- otherwise the first messages of the session are
// silently lost.
//
// out_op/out_valid are registered: out_valid is a one-cycle pulse and out_op is
// stable for that whole cycle, which is exactly the one-op-per-cycle interface
// price_book accepts.
module book_router #(
  parameter logic [63:0] SYMBOLS [book_pkg::NUM_SYMBOLS] = '{default: '0}
) (
  input  logic                    clk, rst_n,
  input  book_pkg::decoded_msg_t  in_msg,
  input  logic                    in_valid,
  output book_pkg::book_op_t      out_op,
  output logic                    out_valid,
  output logic                    busy,          // processing a lookup/replace
  output logic [31:0]             drop_count,    // untracked symbol / unknown order id
  output logic [31:0]             table_full_count,
  output logic [31:0]             occupancy
);

  import book_pkg::*;

  localparam int AW    = TABLE_ADDR_W;
  localparam int DEPTH = 1 << AW;
  localparam int PW    = $clog2(MAX_PROBES + 1);

  // `tomb` is the deletion tombstone: freeing an entry in an open-addressed
  // table must not break the probe chain of a later colliding id, so a freed
  // slot is marked "was used" rather than "empty". A lookup probes THROUGH
  // tombstones and only misses on a never-used slot (or after MAX_PROBES); an
  // insert treats a tombstone as reusable. Without this, deleting the first of
  // two colliding orders would orphan the second -- a silent divergence from
  // model/book.py, which has no notion of probe geometry. Tombstones are only
  // reclaimed by reset; at ITCH load factors the probe window never fills.
  typedef struct packed {
    logic                  vld;
    logic                  tomb;
    logic [63:0]           order_id;
    logic [BOOK_IDX_W-1:0] book_idx;
    logic                  side;
    logic [31:0]           price;
    logic [31:0]           shares;
  } entry_t;

  // ------------------------------------------------------------ symbol filter
  // Parallel compare against the configured symbols. An all-zero SYMBOLS slot
  // means "unused", and non-ADD messages carry symbol == 0, so zero never hits.
  logic                  sym_hit;
  logic [BOOK_IDX_W-1:0] sym_idx;

  always_comb begin
    sym_hit = 1'b0;
    sym_idx = '0;
    // Reverse loop so the lowest matching index wins.
    for (int i = NUM_SYMBOLS - 1; i >= 0; i--) begin
      if ((in_msg.symbol != 64'd0) && (in_msg.symbol == SYMBOLS[i])) begin
        sym_hit = 1'b1;
        sym_idx = BOOK_IDX_W'(i);
      end
    end
  end

  // -------------------------------------------------------------------- hash
  // XOR-fold the order id down to AW bits (AW-bit chunks, zero-padded if AW
  // does not divide 64). Purely combinational.
  function automatic logic [AW-1:0] hash_fold(logic [63:0] id);
    logic [AW-1:0] h, chunk;
    h = '0;
    for (int i = 0; i < 64; i += AW) begin
      chunk = '0;
      for (int b = 0; b < AW; b++)
        if (i + b < 64) chunk[b] = id[i+b];
      h ^= chunk;
    end
    return h;
  endfunction

  // ------------------------------------------------------------------ memory
  // Synchronous read, one port, with a write-first bypass so a slot written on
  // one edge reads back updated even if the very next probe targets it (the
  // REPLACE path frees the old entry in the same cycle it launches the probe
  // for the new id).
  entry_t        mem [DEPTH];
  logic [AW-1:0] rd_addr;
  entry_t        rd_raw_q, rd_byp_q;
  logic          rd_byp_sel_q;
  entry_t        rd_data;

  logic          wr_en;
  logic [AW-1:0] wr_addr;
  entry_t        wr_data;

  always_ff @(posedge clk) begin
    if (wr_en) mem[wr_addr] <= wr_data;
    rd_raw_q     <= mem[rd_addr];
    rd_byp_q     <= wr_data;
    rd_byp_sel_q <= wr_en && (wr_addr == rd_addr);
  end

  assign rd_data = rd_byp_sel_q ? rd_byp_q : rd_raw_q;

  // --------------------------------------------------------------------- FSM
  //   S_CLEAR : post-reset sweep, one entry invalidated per cycle.
  //   S_IDLE  : accept a message; classify; launch the first probe.
  //   S_LOOK  : probing for an id match (EXEC / CANCEL / DELETE / REPLACE).
  //   S_INS   : probing for a free (or same-id) slot to insert into.
  typedef enum logic [1:0] {S_CLEAR, S_IDLE, S_LOOK, S_INS} state_e;

  state_e        state_q,  state_d;
  logic [AW-1:0] addr_q,   addr_d;    // address whose contents are in rd_data
  logic [PW-1:0] probe_q,  probe_d;   // probe index of that address
  msg_kind_e     kind_q,   kind_d;
  logic [63:0]   oid_q,    oid_d;     // id being looked up
  logic [63:0]   ins_id_q, ins_id_d;  // id being inserted
  logic [31:0]   shares_q, shares_d;  // message shares
  logic [31:0]   price_q,  price_d;   // message price
  logic [BOOK_IDX_W-1:0] idx_q, idx_d;
  logic          side_q,   side_d;

  book_op_t out_op_d;
  logic     out_valid_d;
  logic     drop_inc, full_inc, occ_inc, occ_dec;

  logic id_match, slot_free, slot_never_used, last_probe;

  assign id_match        = rd_data.vld && (rd_data.order_id == oid_q);
  assign slot_free       = !rd_data.vld;                     // empty or tombstone
  assign slot_never_used = !rd_data.vld && !rd_data.tomb;    // end of probe chain
  assign last_probe      = (probe_q == PW'(MAX_PROBES - 1));

  always_comb begin
    // Defaults: hold state, no memory write, no op, no counter change.
    state_d     = state_q;
    addr_d      = addr_q;
    probe_d     = probe_q;
    kind_d      = kind_q;
    oid_d       = oid_q;
    ins_id_d    = ins_id_q;
    shares_d    = shares_q;
    price_d     = price_q;
    idx_d       = idx_q;
    side_d      = side_q;

    rd_addr     = addr_q;
    wr_en       = 1'b0;
    wr_addr     = addr_q;
    wr_data     = '0;

    out_op_d    = '0;
    out_valid_d = 1'b0;
    drop_inc    = 1'b0;
    full_inc    = 1'b0;
    occ_inc     = 1'b0;
    occ_dec     = 1'b0;

    unique case (state_q)
      // ------------------------------------------------------------- clear
      S_CLEAR: begin
        wr_en   = 1'b1;
        wr_addr = addr_q;
        wr_data = '0;
        if (&addr_q) begin
          state_d = S_IDLE;
          addr_d  = '0;
        end else begin
          addr_d = addr_q + AW'(1);
        end
      end

      // -------------------------------------------------------------- idle
      S_IDLE: begin
        // MSG_SYSTEM is deliberately not even latched: it does nothing, in any
        // state, which is what makes accepting it while busy safe.
        if (in_valid && (in_msg.kind != MSG_SYSTEM)) begin
          kind_d   = in_msg.kind;
          oid_d    = in_msg.order_id;
          shares_d = in_msg.shares;
          price_d  = in_msg.price;
          probe_d  = '0;

          unique case (in_msg.kind)
            MSG_ADD: begin
              if (!sym_hit) begin
                drop_inc = 1'b1;              // untracked symbol: never tracked
              end else begin
                ins_id_d = in_msg.order_id;
                idx_d    = sym_idx;
                side_d   = in_msg.side;
                rd_addr  = hash_fold(in_msg.order_id);
                addr_d   = hash_fold(in_msg.order_id);
                state_d  = S_INS;
              end
            end
            MSG_EXEC, MSG_CANCEL, MSG_DELETE, MSG_REPLACE: begin
              ins_id_d = in_msg.new_order_id;  // used by REPLACE only
              rd_addr  = hash_fold(in_msg.order_id);
              addr_d   = hash_fold(in_msg.order_id);
              state_d  = S_LOOK;
            end
            default: ;                         // filtered out above
          endcase
        end
      end

      // ------------------------------------------------------------ lookup
      S_LOOK: begin
        if (id_match) begin
          // Every op reduces at the STORED resting price on the STORED side of
          // the STORED book -- never anything from the message.
          out_valid_d       = 1'b1;
          out_op_d.op       = OP_REDUCE;
          out_op_d.book_idx = rd_data.book_idx;
          out_op_d.side     = rd_data.side;
          out_op_d.price    = rd_data.price;

          wr_en   = 1'b1;
          wr_addr = addr_q;
          state_d = S_IDLE;

          if (kind_q == MSG_EXEC || kind_q == MSG_CANCEL) begin
            out_op_d.shares = shares_q;
            if (rd_data.shares <= shares_q) begin
              wr_data      = '0;               // remaining <= 0 -> free
              wr_data.tomb = 1'b1;
              occ_dec      = 1'b1;
            end else begin
              wr_data        = rd_data;
              wr_data.shares = rd_data.shares - shares_q;
            end
          end else begin
            // DELETE and REPLACE both retire the whole remaining quantity.
            out_op_d.shares = rd_data.shares;
            wr_data         = '0;
            wr_data.tomb    = 1'b1;
            occ_dec         = 1'b1;
            if (kind_q == MSG_REPLACE) begin
              // Insert new_order_id next, inheriting book_idx and side.
              idx_d   = rd_data.book_idx;
              side_d  = rd_data.side;
              rd_addr = hash_fold(ins_id_q);
              addr_d  = hash_fold(ins_id_q);
              probe_d = '0;
              state_d = S_INS;
            end
          end
        end else if (slot_never_used || last_probe) begin
          drop_inc = 1'b1;                     // unknown order id
          state_d  = S_IDLE;
        end else begin
          rd_addr = addr_q + AW'(1);
          addr_d  = addr_q + AW'(1);
          probe_d = probe_q + PW'(1);
        end
      end

      // ------------------------------------------------------------ insert
      S_INS: begin
        if (slot_free || (rd_data.vld && (rd_data.order_id == ins_id_q))) begin
          wr_en             = 1'b1;
          wr_addr           = addr_q;
          wr_data.vld       = 1'b1;
          wr_data.order_id  = ins_id_q;
          wr_data.book_idx  = idx_q;
          wr_data.side      = side_q;
          wr_data.price     = price_q;
          wr_data.shares    = shares_q;
          occ_inc           = slot_free;       // overwrite does not grow the table

          out_valid_d       = 1'b1;
          out_op_d.op       = OP_ADD;
          out_op_d.book_idx = idx_q;
          out_op_d.side     = side_q;
          out_op_d.price    = price_q;
          out_op_d.shares   = shares_q;

          state_d = S_IDLE;
        end else if (last_probe) begin
          full_inc = 1'b1;                     // probe window full -> drop
          state_d  = S_IDLE;
        end else begin
          rd_addr = addr_q + AW'(1);
          addr_d  = addr_q + AW'(1);
          probe_d = probe_q + PW'(1);
        end
      end

      default: state_d = S_IDLE;
    endcase
  end

  // -------------------------------------------------------------- registers
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state_q          <= S_CLEAR;
      addr_q           <= '0;
      probe_q          <= '0;
      kind_q           <= MSG_SYSTEM;
      oid_q            <= '0;
      ins_id_q         <= '0;
      shares_q         <= '0;
      price_q          <= '0;
      idx_q            <= '0;
      side_q           <= 1'b0;
      out_op           <= '0;
      out_valid        <= 1'b0;
      drop_count       <= '0;
      table_full_count <= '0;
      occupancy        <= '0;
    end else begin
      state_q   <= state_d;
      addr_q    <= addr_d;
      probe_q   <= probe_d;
      kind_q    <= kind_d;
      oid_q     <= oid_d;
      ins_id_q  <= ins_id_d;
      shares_q  <= shares_d;
      price_q   <= price_d;
      idx_q     <= idx_d;
      side_q    <= side_d;

      out_valid <= out_valid_d;
      if (out_valid_d) out_op <= out_op_d;

      if (drop_inc) drop_count       <= drop_count       + 32'd1;
      if (full_inc) table_full_count <= table_full_count + 32'd1;
      if (occ_inc)  occupancy        <= occupancy        + 32'd1;
      if (occ_dec)  occupancy        <= occupancy        - 32'd1;
    end
  end

  assign busy = (state_q != S_IDLE);

  // ------------------------------------------------------------- assertions
`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (rst_n) begin
      // The byte-wide upstream leaves >= 19 idle cycles after every message that
      // reaches the table, which is more than the worst-case FSM run, so such a
      // message arriving while busy means the contract was broken (or the byte
      // feed was not gated until the post-reset clear sweep finished). SYSTEM
      // messages are exempt: their gap is only 14 cycles and they are accepted
      // unconditionally because they touch nothing.
      if (in_valid && busy && (in_msg.kind != MSG_SYSTEM))
        $fatal(1, "book_router: in_valid asserted while busy (state %0d, kind %0d)",
               state_q, in_msg.kind);
      if (occ_inc && occ_dec)
        $fatal(1, "book_router: occupancy incremented and decremented at once");
      if (occ_dec && occupancy == 32'd0)
        $fatal(1, "book_router: occupancy underflow");
    end
  end
`endif

endmodule
