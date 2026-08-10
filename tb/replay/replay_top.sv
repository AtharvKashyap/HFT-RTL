// replay_top -- flat-port wrapper around tick_to_trade_top for the Verilator
// C++ replay harness (tb/replay/replay_main.cpp).
//
// Three things this wrapper exists to do:
//
//  1. Fix the SYMBOLS parameter at verilate time. SYMBOLS is an *unpacked*
//     array parameter, which `verilator -G` cannot set, so the list is pulled
//     in from a generated header (`replay_symbols.svh`, produced by
//     scripts/gen_symbols.py from the Makefile's SYMBOLS variable). The order
//     of that list defines book_idx, and MUST match the order passed to
//     `model/dump_trace.py --symbols` so that book_idx == symbol_idx.
//
//  2. Flatten `upd` (a book_update_t packed struct) into plain vector ports.
//     A 256-bit port is exposed to C++ as a VlWide<8> whose word j is
//     bits [32j+31 : 32j], and `logic [N_LEVELS-1:0][31:0]` places level j in
//     exactly those bits -- so C++ reads level j as `top->bid_price[j]`, with
//     level 0 = best. A struct port would instead arrive as one opaque blob.
//
//  3. Re-declare the strategy/risk scalar parameters so they are parameters of
//     the *top* module, which is the only place `verilator -G` can reach. The
//     defaults come from trade_pkg, so a build with no -G matches the golden
//     model's own defaults; tb/replay/Makefile hands the same values to the
//     verilate step that scripts/run_replay.sh hands to model/dump_trace.py.
//
// The phase-1 pass-through ports (upd*, msg_boundary, the status counters,
// end_of_session) come straight out of the itch_book_top instance inside
// tick_to_trade_top, so the book-update flow this harness has always compared
// is bit-identical to what it was when the DUT was itch_book_top directly.
module replay_top #(
  parameter int THRESH_LOG2       = trade_pkg::THRESH_LOG2_DEF,
  parameter int COOLDOWN_UPDATES  = trade_pkg::COOLDOWN_UPDATES_DEF,
  parameter int ORDER_SHARES      = trade_pkg::ORDER_SHARES_DEF,
  parameter int MAX_POSITION      = trade_pkg::MAX_POSITION_DEF,
  parameter int MIN_ORDER_SPACING = trade_pkg::MIN_ORDER_SPACING_DEF,
  parameter int COLLAR_SHIFT      = trade_pkg::COLLAR_SHIFT_DEF
) (
  input  logic        clk, rst_n,
  input  logic        in_valid,
  input  logic [7:0]  in_data,
  output logic        in_ready,

  output logic        upd_valid,
  output logic [book_pkg::BOOK_IDX_W-1:0]   upd_book_idx,
  output logic [book_pkg::N_LEVELS*32-1:0]  bid_price,
  output logic [book_pkg::N_LEVELS*32-1:0]  bid_shares,
  output logic [book_pkg::N_LEVELS*32-1:0]  ask_price,
  output logic [book_pkg::N_LEVELS*32-1:0]  ask_shares,

  output logic        msg_boundary,
  output logic [31:0] gap_count, malformed_count, unknown_count,
  output logic [31:0] drop_count, table_full_count,
  output logic [31:0] reduce_miss_count, evict_count,
  output logic        end_of_session,

  // OUCH order stream (byte-serial) plus the frame-start latency hook.
  output logic        ouch_valid,
  output logic [7:0]  ouch_data,
  output logic        ouch_last,
  output logic        frame_start,

  // Strategy / risk / encoder counters, compared against the golden model's
  // own summary line by scripts/run_replay.sh.
  output logic [31:0] intent_count, accept_count,
  output logic [31:0] sanity_reject_count, collar_reject_count,
  output logic [31:0] rate_reject_count, pos_reject_count,
  output logic [31:0] order_count, fifo_drop_count
);

  import book_pkg::*;

  // Generated: localparam logic [63:0] REPLAY_SYMBOLS [book_pkg::NUM_SYMBOLS]
  `include "replay_symbols.svh"

  book_update_t upd;

  tick_to_trade_top #(
    .SYMBOLS           (REPLAY_SYMBOLS),
    .THRESH_LOG2       (THRESH_LOG2),
    .COOLDOWN_UPDATES  (COOLDOWN_UPDATES),
    .ORDER_SHARES      (ORDER_SHARES),
    .MAX_POSITION      (MAX_POSITION),
    .MIN_ORDER_SPACING (MIN_ORDER_SPACING),
    .COLLAR_SHIFT      (COLLAR_SHIFT)
  ) u_dut (
    .clk                 (clk),
    .rst_n               (rst_n),
    .in_valid            (in_valid),
    .in_data             (in_data),
    .in_ready            (in_ready),
    .upd                 (upd),
    .upd_valid           (upd_valid),
    .msg_boundary        (msg_boundary),
    .gap_count           (gap_count),
    .malformed_count     (malformed_count),
    .unknown_count       (unknown_count),
    .drop_count          (drop_count),
    .table_full_count    (table_full_count),
    .reduce_miss_count   (reduce_miss_count),
    .evict_count         (evict_count),
    .end_of_session      (end_of_session),
    .ouch_valid          (ouch_valid),
    .ouch_data           (ouch_data),
    .ouch_last           (ouch_last),
    .frame_start         (frame_start),
    .intent_count        (intent_count),
    .accept_count        (accept_count),
    .sanity_reject_count (sanity_reject_count),
    .collar_reject_count (collar_reject_count),
    .rate_reject_count   (rate_reject_count),
    .pos_reject_count    (pos_reject_count),
    .order_count         (order_count),
    .fifo_drop_count     (fifo_drop_count)
  );

  assign upd_book_idx  = upd.book_idx;
  assign bid_price     = upd.bid_price;
  assign bid_shares    = upd.bid_shares;
  assign ask_price     = upd.ask_price;
  assign ask_shares    = upd.ask_shares;
  // upd.timestamp is deliberately NOT exposed: the RTL trace never emits a
  // timestamp field, so a port for it would be dead plumbing. `lat` (measured
  // in replay_main.cpp from msg_boundary to upd_valid, and separately from
  // msg_boundary to frame_start) is the only hardware-only field the traces
  // carry.

endmodule
