// replay_top -- flat-port wrapper around itch_book_top for the Verilator C++
// replay harness (tb/replay/replay_main.cpp).
//
// Two things this wrapper exists to do:
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
module replay_top (
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
  output logic [63:0] upd_timestamp,

  output logic        msg_boundary,
  output logic [31:0] gap_count, malformed_count, unknown_count,
  output logic [31:0] drop_count, table_full_count,
  output logic [31:0] reduce_miss_count, evict_count,
  output logic        end_of_session
);

  import book_pkg::*;

  // Generated: localparam logic [63:0] REPLAY_SYMBOLS [book_pkg::NUM_SYMBOLS]
  `include "replay_symbols.svh"

  book_update_t upd;

  itch_book_top #(.SYMBOLS(REPLAY_SYMBOLS)) u_dut (
    .clk               (clk),
    .rst_n             (rst_n),
    .in_valid          (in_valid),
    .in_data           (in_data),
    .in_ready          (in_ready),
    .upd               (upd),
    .upd_valid         (upd_valid),
    .gap_count         (gap_count),
    .malformed_count   (malformed_count),
    .unknown_count     (unknown_count),
    .drop_count        (drop_count),
    .table_full_count  (table_full_count),
    .end_of_session    (end_of_session),
    .msg_boundary      (msg_boundary),
    .reduce_miss_count (reduce_miss_count),
    .evict_count       (evict_count)
  );

  assign upd_book_idx  = upd.book_idx;
  assign bid_price     = upd.bid_price;
  assign bid_shares    = upd.bid_shares;
  assign ask_price     = upd.ask_price;
  assign ask_shares    = upd.ask_shares;
  assign upd_timestamp = upd.timestamp;

endmodule
