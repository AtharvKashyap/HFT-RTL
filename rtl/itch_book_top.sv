// itch_book_top -- top-level integration: byte-serial MoldUDP64 feed in,
// per-symbol top-8 order book snapshots out.
//
// Pipeline: mold_framer -> itch_decoder -> book_router -> 16x price_book
// (one per NUM_SYMBOLS, generated). A free-running 64-bit cycle counter
// feeds every price_book's timestamp_in, so upd.timestamp is a simple
// cycle count, monotonically increasing across the whole session.
//
// INTEGRATION REQUIREMENT (see rtl/book_router.sv): book_router runs a
// 2**TABLE_ADDR_W-cycle table-clear sweep after reset with no backpressure
// on its input -- feeding it decoded messages during that sweep would
// silently lose them. `in_ready` therefore stays low (and any in_valid byte
// offered while low is ignored, not buffered) until the router's `busy`
// first falls after reset; once that has happened `in_ready` stays high for
// the rest of the session; the byte-wide upstream and the router's own busy
// gating already protect it against outrunning the router on individual
// messages.
//
// Update path: book_router accepts one op at a time (`out_valid` is a
// one-cycle pulse), so `out_op.book_idx` is registered into `last_book_idx`
// on that same pulse; each price_book's `op_valid` is gated by
// `out_op.book_idx == i`, so exactly one book's internal state can change
// per op, and (one cycle later) at most one book's `upd_valid` can pulse.
// The registered `last_book_idx` from the cycle that launched the op is
// therefore the correct mux select the cycle the result appears, and `upd`/
// `upd_valid` are simply that selected book's outputs. An assertion checks
// the "at most one" invariant directly on the per-book upd_valid vector.
//
// `msg_boundary` is a 1-cycle combinational pulse on the framer's out_last
// (i.e. the last byte of an ITCH message leaving the framer), exposed for
// the replay harness to align against message boundaries.
// `evict_count`/`reduce_miss_count` are combinational sums across all 16
// books' per-book counters -- summing (rather than OR-reducing) preserves
// the total event count, which is what the replay harness reports.
module itch_book_top #(
  parameter logic [63:0] SYMBOLS [book_pkg::NUM_SYMBOLS] = '{default: '0}
) (
  input  logic        clk, rst_n,
  input  logic        in_valid,
  input  logic [7:0]  in_data,
  output logic        in_ready,
  output book_pkg::book_update_t upd,
  output logic        upd_valid,
  // status
  output logic [31:0] gap_count, malformed_count, unknown_count,
  output logic [31:0] drop_count, table_full_count,
  output logic        end_of_session,
  // extras for the replay harness (task 9)
  output logic        msg_boundary,
  output logic [31:0] reduce_miss_count,
  output logic [31:0] evict_count
);

  import book_pkg::*;

  // ------------------------------------------------------------- byte gate
  // Latches high the first time book_router's post-reset clear sweep
  // finishes (busy falling) and stays high for the rest of the session.
  logic router_busy;
  logic swept_q;

  always_ff @(posedge clk) begin
    if (!rst_n)      swept_q <= 1'b0;
    else if (!router_busy) swept_q <= 1'b1;
  end

  assign in_ready = swept_q;

  logic       gated_valid;
  assign gated_valid = in_valid && in_ready;

  // ------------------------------------------------------------- framer
  logic       fr_out_valid;
  logic [7:0] fr_out_data;
  logic       fr_out_last;
  logic       fr_in_ready;  // unused: mold_framer's in_ready is always 1

  mold_framer u_framer (
    .clk             (clk),
    .rst_n           (rst_n),
    .in_valid        (gated_valid),
    .in_data         (in_data),
    .in_ready        (fr_in_ready),
    .out_valid       (fr_out_valid),
    .out_data        (fr_out_data),
    .out_last        (fr_out_last),
    .gap_count       (gap_count),
    .malformed_count (malformed_count),
    .end_of_session  (end_of_session)
  );

  assign msg_boundary = fr_out_valid && fr_out_last;

  // ------------------------------------------------------------- decoder
  decoded_msg_t dec_msg;
  logic         dec_valid;

  itch_decoder u_decoder (
    .clk           (clk),
    .rst_n         (rst_n),
    .in_valid      (fr_out_valid),
    .in_data       (fr_out_data),
    .in_last       (fr_out_last),
    .out_msg       (dec_msg),
    .out_valid     (dec_valid),
    .unknown_count (unknown_count)
  );

  // -------------------------------------------------------------- router
  book_op_t out_op;
  logic     out_valid;
  logic [31:0] occupancy;  // unused at top level, must still be connected

  book_router #(.SYMBOLS(SYMBOLS)) u_router (
    .clk              (clk),
    .rst_n            (rst_n),
    .in_msg           (dec_msg),
    .in_valid         (dec_valid),
    .out_op           (out_op),
    .out_valid        (out_valid),
    .busy             (router_busy),
    .drop_count       (drop_count),
    .table_full_count (table_full_count),
    .occupancy        (occupancy)
  );

  // ----------------------------------------------------------- timestamp
  logic [63:0] timestamp_q;

  always_ff @(posedge clk) begin
    if (!rst_n) timestamp_q <= '0;
    else        timestamp_q <= timestamp_q + 64'd1;
  end

  // ------------------------------------------------------------- books
  book_update_t upd_arr           [NUM_SYMBOLS];
  logic         upd_valid_arr     [NUM_SYMBOLS];
  logic [31:0]  evict_arr         [NUM_SYMBOLS];
  logic [31:0]  reduce_miss_arr   [NUM_SYMBOLS];
  logic [31:0]  crossed_arr       [NUM_SYMBOLS];  // debug-only, not exposed

  generate
    for (genvar i = 0; i < NUM_SYMBOLS; i++) begin : g_book
      logic op_valid_i;
      assign op_valid_i = out_valid && (out_op.book_idx == BOOK_IDX_W'(i));

      price_book #(.MY_IDX(BOOK_IDX_W'(i))) u_book (
        .clk               (clk),
        .rst_n             (rst_n),
        .op                (out_op),
        .op_valid          (op_valid_i),
        .timestamp_in      (timestamp_q),
        .upd               (upd_arr[i]),
        .upd_valid         (upd_valid_arr[i]),
        .evict_count       (evict_arr[i]),
        .reduce_miss_count (reduce_miss_arr[i]),
        .crossed_count     (crossed_arr[i])
      );
    end
  endgenerate

  // --------------------------------------------------------------- mux
  // Registered the same cycle out_valid fires, valid the cycle op_valid_i's
  // result appears -- see header comment for why this is race-free.
  logic [BOOK_IDX_W-1:0] last_book_idx_q;

  always_ff @(posedge clk) begin
    if (!rst_n)        last_book_idx_q <= '0;
    else if (out_valid) last_book_idx_q <= out_op.book_idx;
  end

  assign upd       = upd_arr[last_book_idx_q];
  assign upd_valid = upd_valid_arr[last_book_idx_q];

  // ------------------------------------------------------- counter sums
  logic [31:0] evict_sum, reduce_miss_sum;

  always_comb begin
    evict_sum       = '0;
    reduce_miss_sum = '0;
    for (int i = 0; i < NUM_SYMBOLS; i++) begin
      evict_sum       += evict_arr[i];
      reduce_miss_sum += reduce_miss_arr[i];
    end
  end

  assign evict_count       = evict_sum;
  assign reduce_miss_count = reduce_miss_sum;

  // ------------------------------------------------------------- assertions
`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (rst_n) begin
      int live_cnt;
      live_cnt = 0;
      for (int i = 0; i < NUM_SYMBOLS; i++) if (upd_valid_arr[i]) live_cnt++;
      if (live_cnt > 1)
        $fatal(1, "itch_book_top: %0d books pulsed upd_valid in the same cycle",
               live_cnt);
    end
  end
`endif

endmodule
