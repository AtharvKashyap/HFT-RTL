// strategy_imbalance -- per-symbol weighted-imbalance strategy.
//
// Implements the project's "Strategy semantics" contract verbatim, bit-matching
// model/strategy.py's Strategy:
//
//   * Masses per update: B = sum(bid_shares[i] >> i), A = sum(ask_shares[i] >> i)
//     over the 8 levels, i.e. each level down the book counts half as much as
//     the one above it. The shift is a true floor, not a rounded divide.
//   * Per-symbol state in {NEUTRAL, LONG, SHORT}: LONG iff B > (A << THRESH_LOG2),
//     SHORT iff A > (B << THRESH_LOG2), else NEUTRAL. Strictly greater, so the
//     exact boundary (B == A << THRESH_LOG2) is NEUTRAL.
//   * Edge rule: fire buy on entering LONG from any non-LONG state, sell on
//     entering SHORT from any non-SHORT state. Staying in a state never fires.
//     The state is updated even when the firing is suppressed, so a suppressed
//     edge is consumed rather than deferred -- an expiring cooldown does not by
//     itself produce an order.
//   * Cooldown: after an intent is actually emitted for symbol s, firing for s
//     is suppressed until COOLDOWN_UPDATES further updates of s have been
//     observed. Per-symbol; other symbols are unaffected. The state machine
//     keeps running throughout.
//   * Intent: buy takes ask_price[0], sell takes bid_price[0], shares =
//     ORDER_SHARES. No intent if the priced side's level-0 price is 0 (an empty
//     side), and an intent blocked that way does not arm the cooldown, exactly
//     as the Python model only stamps its counter when it returns an intent.
//   * The intent carries the level-0 prices of the triggering update as a
//     sideband for the downstream risk gate's sanity and collar checks.
//
// State advances on book-update ordinals, never clock cycles: an update is
// consumed only on a rising edge with upd_valid high. Throughput is one update
// per cycle -- masses, the next state and the firing decision are all
// combinational, and `out`/`out_valid`/`intent_count` are registered from them
// on the same edge that absorbs the update, so an intent is visible during the
// following cycle. out_valid is a one-cycle pulse that appears only for updates
// which actually emit an intent; updates with no edge, a suppressed edge or a
// zero level-0 price emit nothing, matching the Python model returning None.
module strategy_imbalance #(
  parameter int THRESH_LOG2      = trade_pkg::THRESH_LOG2_DEF,
  parameter int COOLDOWN_UPDATES = trade_pkg::COOLDOWN_UPDATES_DEF,
  parameter int ORDER_SHARES     = trade_pkg::ORDER_SHARES_DEF
) (
  input  logic clk, rst_n,
  input  book_pkg::book_update_t upd,
  input  logic                   upd_valid,
  output trade_pkg::gated_intent_t out,
  output logic                     out_valid,   // 1-cycle pulse, cycle after upd_valid
  output logic [31:0]              intent_count
);

  import book_pkg::*;

  // 8 levels of 32-bit shares sum to strictly less than 2^35, so 35 bits hold
  // any mass exactly and the sum can never wrap (the Python model uses
  // unbounded ints, and a wrap here would be a divergence).
  localparam int MASS_W = 32 + $clog2(N_LEVELS);
  // The threshold comparison shifts a mass left by THRESH_LOG2 before
  // comparing, so it is done in a wide enough space to keep that exact too.
  localparam int CMP_W  = MASS_W + THRESH_LOG2;
  // Remaining-cooldown counter. $clog2 would be 0 for COOLDOWN_UPDATES <= 1,
  // which is not a legal signal width, hence the floor of 1 bit.
  localparam int CD_W   = (COOLDOWN_UPDATES < 2) ? 1 : $clog2(COOLDOWN_UPDATES + 1);

  typedef enum logic [1:0] {ST_NEUTRAL, ST_LONG, ST_SHORT} state_e;

  // ------------------------------------------------------------------ state
  // Per-symbol register files, addressed by the update's book index.
  state_e          state_q [NUM_SYMBOLS];
  logic [CD_W-1:0] cool_q  [NUM_SYMBOLS];

  logic [BOOK_IDX_W-1:0] idx;
  assign idx = upd.book_idx;

  // -------------------------------------------------------------- mass trees
  // Combinational adder trees over the level weights. `>> i` with a constant
  // loop index is a wire re-index, not a barrel shifter.
  logic [MASS_W-1:0] mass_b, mass_a;

  always_comb begin
    mass_b = '0;
    mass_a = '0;
    for (int i = 0; i < N_LEVELS; i++) begin
      mass_b = mass_b + MASS_W'(upd.bid_shares[i] >> i);
      mass_a = mass_a + MASS_W'(upd.ask_shares[i] >> i);
    end
  end

  // ------------------------------------------------------- decision datapath
  state_e cur_state, nxt_state;
  logic   fire_buy, fire_sell, suppressed;
  logic   do_buy, do_sell, intent_fired;

  assign cur_state = state_q[idx];

  always_comb begin
    if (CMP_W'(mass_b) > (CMP_W'(mass_a) << THRESH_LOG2))      nxt_state = ST_LONG;
    else if (CMP_W'(mass_a) > (CMP_W'(mass_b) << THRESH_LOG2)) nxt_state = ST_SHORT;
    else                                                       nxt_state = ST_NEUTRAL;
  end

  // Mutually exclusive: nxt_state cannot be both LONG and SHORT.
  assign fire_buy   = (nxt_state == ST_LONG)  && (cur_state != ST_LONG);
  assign fire_sell  = (nxt_state == ST_SHORT) && (cur_state != ST_SHORT);
  assign suppressed = (cool_q[idx] != '0);

  assign do_buy       = fire_buy  && !suppressed && (upd.ask_price[0] != 32'd0);
  assign do_sell      = fire_sell && !suppressed && (upd.bid_price[0] != 32'd0);
  assign intent_fired = do_buy || do_sell;

  // -------------------------------------------------------------- registers
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int s = 0; s < NUM_SYMBOLS; s++) begin
        state_q[s] <= ST_NEUTRAL;
        cool_q[s]  <= '0;
      end
      out          <= '0;
      out_valid    <= 1'b0;
      intent_count <= '0;
    end else begin
      out_valid <= 1'b0;

      if (upd_valid) begin
        // The state advances on every update, fired or not.
        state_q[idx] <= nxt_state;

        // Remaining-cooldown form of the model's `updates_since_fire`: the
        // model's "None" (re-armed) is this counter at zero, and its
        // "counter < COOLDOWN_UPDATES" (suppressed) is this counter non-zero.
        if (intent_fired)          cool_q[idx] <= CD_W'(COOLDOWN_UPDATES);
        else if (cool_q[idx] != '0) cool_q[idx] <= cool_q[idx] - CD_W'(1);

        out_valid <= intent_fired;
        if (intent_fired) begin
          out.intent.symbol_idx <= idx;
          out.intent.side       <= do_buy;
          out.intent.shares     <= 32'(ORDER_SHARES);
          out.intent.price      <= do_buy ? upd.ask_price[0] : upd.bid_price[0];
          out.bid0              <= upd.bid_price[0];
          out.ask0              <= upd.ask_price[0];
          intent_count          <= intent_count + 32'd1;
        end
      end
    end
  end

  // ------------------------------------------------------------- assertions
`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (rst_n) begin
      // Both sides can never fire on the same update.
      if (do_buy && do_sell)
        $fatal(1, "strategy_imbalance: buy and sell fired on the same update");
      // The priced side's level-0 price is checked before firing, so a
      // zero-priced order can never leave this module.
      if (upd_valid && intent_fired &&
          (do_buy ? upd.ask_price[0] : upd.bid_price[0]) == 32'd0)
        $fatal(1, "strategy_imbalance: emitted an intent at price 0");
      // The cooldown counter is loaded with COOLDOWN_UPDATES and only ever
      // decrements, so it can never exceed its load value.
      if (cool_q[idx] > CD_W'(COOLDOWN_UPDATES))
        $fatal(1, "strategy_imbalance: cooldown counter %0d out of range for symbol %0d",
               cool_q[idx], idx);
    end
  end
`endif

endmodule
