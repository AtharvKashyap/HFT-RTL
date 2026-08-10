// tick_to_trade_top -- full tick-to-trade pipeline: byte-serial MoldUDP64 feed
// in, OUCH 4.2 Enter Order wire frames out.
//
// Pure wiring, no new logic: itch_book_top -> strategy_imbalance -> risk_gate
// -> ouch_encoder. All phase-1 ports (upd, upd_valid, msg_boundary, the
// status counters, end_of_session) are simple pass-throughs from
// itch_book_top, exposed for the replay regression harness.
//
// risk_gate.upd_valid is wired to the BOOK's upd_valid (its rate-counter time
// base), which is a SEPARATE input from risk_gate.in_valid (the strategy's
// gated intent, one cycle behind the triggering update) -- risk_gate itself
// handles the coincidence when both land on the same cycle; this module does
// nothing special for it beyond the wiring.
//
// SYMBOLS is threaded through to both itch_book_top (for the router's symbol
// filter) and ouch_encoder (for the frame's stock field), so a lookup in
// either place agrees with the other.
module tick_to_trade_top #(
  parameter logic [63:0] SYMBOLS [book_pkg::NUM_SYMBOLS] = '{default: '0},
  parameter int THRESH_LOG2       = trade_pkg::THRESH_LOG2_DEF,
  parameter int COOLDOWN_UPDATES  = trade_pkg::COOLDOWN_UPDATES_DEF,
  parameter int ORDER_SHARES      = trade_pkg::ORDER_SHARES_DEF,
  parameter int MAX_POSITION      = trade_pkg::MAX_POSITION_DEF,
  parameter int MIN_ORDER_SPACING = trade_pkg::MIN_ORDER_SPACING_DEF,
  parameter int COLLAR_SHIFT      = trade_pkg::COLLAR_SHIFT_DEF
) (
  input  logic clk, rst_n,
  input  logic in_valid, input logic [7:0] in_data, output logic in_ready,
  // phase-1 pass-through (replay regression):
  output book_pkg::book_update_t upd, output logic upd_valid,
  output logic msg_boundary,
  output logic [31:0] gap_count, malformed_count, unknown_count,
                      drop_count, table_full_count, reduce_miss_count, evict_count,
  output logic end_of_session,
  // new:
  output logic ouch_valid, output logic [7:0] ouch_data, output logic ouch_last,
  output logic frame_start,
  output logic [31:0] intent_count, accept_count, sanity_reject_count,
                      collar_reject_count, rate_reject_count, pos_reject_count,
                      order_count, fifo_drop_count
);

  itch_book_top #(.SYMBOLS(SYMBOLS)) u_book (
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

  trade_pkg::gated_intent_t strat_out;
  logic                     strat_out_valid;

  strategy_imbalance #(
    .THRESH_LOG2      (THRESH_LOG2),
    .COOLDOWN_UPDATES (COOLDOWN_UPDATES),
    .ORDER_SHARES     (ORDER_SHARES)
  ) u_strategy (
    .clk          (clk),
    .rst_n        (rst_n),
    .upd          (upd),
    .upd_valid    (upd_valid),
    .out          (strat_out),
    .out_valid    (strat_out_valid),
    .intent_count (intent_count)
  );

  trade_pkg::order_intent_t risk_out;
  logic                     risk_out_valid;

  risk_gate #(
    .MAX_POSITION      (MAX_POSITION),
    .MIN_ORDER_SPACING (MIN_ORDER_SPACING),
    .COLLAR_SHIFT      (COLLAR_SHIFT)
  ) u_risk (
    .clk                  (clk),
    .rst_n                (rst_n),
    .upd_valid            (upd_valid),
    .in                   (strat_out),
    .in_valid             (strat_out_valid),
    .out                  (risk_out),
    .out_valid            (risk_out_valid),
    .accept_count         (accept_count),
    .sanity_reject_count  (sanity_reject_count),
    .collar_reject_count  (collar_reject_count),
    .rate_reject_count    (rate_reject_count),
    .pos_reject_count     (pos_reject_count)
  );

  ouch_encoder #(.SYMBOLS(SYMBOLS)) u_ouch (
    .clk             (clk),
    .rst_n           (rst_n),
    .in              (risk_out),
    .in_valid        (risk_out_valid),
    .out_valid       (ouch_valid),
    .out_data        (ouch_data),
    .out_last        (ouch_last),
    .frame_start     (frame_start),
    .order_count     (order_count),
    .fifo_drop_count (fifo_drop_count)
  );

endmodule
