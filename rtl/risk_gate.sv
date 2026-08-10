// risk_gate -- per-symbol pre-trade risk gate.
//
// Implements the project's "Risk semantics" contract verbatim, bit-matching
// model/risk.py's RiskGate. Checks run in a fixed order that is a hard
// contract, and exactly one reject counter increments per rejection -- the
// counter for the FIRST failing check:
//
//   1. sanity: reject unless bid0 != 0 && ask0 != 0 && bid0 < ask0 (the
//      sideband on the gated intent, i.e. the triggering update's level-0
//      prices).
//   2. collar: mid = (bid0+ask0)>>1; reject if |price-mid| > (mid>>COLLAR_SHIFT)
//      (strict >, so the exact boundary passes).
//   3. rate: reject if fewer than MIN_ORDER_SPACING book updates (ANY symbol)
//      have been observed since the last ACCEPTED order. The counter
//      increments on every upd_valid and resets to 0 on accept.
//   4. position: signed pos[symbol] += (+shares if buy else -shares), applied
//      only on accept; reject if the post-trade |pos| would exceed
//      MAX_POSITION.
//
// Coincidence rule (upd_valid and in_valid on the same cycle): upd_valid is
// the book's update pulse -- the rate time base -- and is a separate input
// from in_valid, which presents an intent one cycle after the upstream
// strategy's triggering update.
//
// The golden model (model/dump_trace.py) processes ONE event at a time: for
// event k it calls on_update() and only then feeds the strategy's intent for
// that same event k through on_intent(). So the intent triggered by update k
// is judged against a count that already includes update k -- and the RTL
// gets exactly that for free from the strategy's 1-cycle intent register: by
// the time the intent arrives, update k's own upd_valid pulse has already
// been counted on the previous edge. Equivalence is by construction, with no
// fold-in needed.
//
// What a coincident upd_valid on the intent's cycle represents is therefore a
// DIFFERENT, LATER event (k+1) -- one the model has not reached yet when it
// judges k's intent. It must NOT be folded into the comparison:
//   * `rate_eff = rate_q` -- the intent is judged against the PRE-coincident
//     count, matching the model's ordering.
//   * on accept, `rate_q <= upd_valid ? RATE_ONE : '0` -- the model resets
//     updates_since_accept to 0 for event k and then counts event k+1 on the
//     next iteration, so the coincident update survives the reset as a count
//     of 1 rather than being discarded.
// Both off-by-ones point in opposite directions, so the old "increment before
// compare" fold was wrong on both sides at once.
module risk_gate #(
  parameter int MAX_POSITION      = trade_pkg::MAX_POSITION_DEF,
  parameter int MIN_ORDER_SPACING = trade_pkg::MIN_ORDER_SPACING_DEF,
  parameter int COLLAR_SHIFT      = trade_pkg::COLLAR_SHIFT_DEF
) (
  input  logic clk, rst_n,
  input  logic upd_valid,                    // every book update (rate time base)
  input  trade_pkg::gated_intent_t in,
  input  logic                     in_valid,
  output trade_pkg::order_intent_t out,
  output logic                     out_valid, // 1-cycle pulse, cycle after an ACCEPTED in_valid
  output logic [31:0] accept_count, sanity_reject_count, collar_reject_count,
                      rate_reject_count, pos_reject_count
);

  import book_pkg::NUM_SYMBOLS;

  // Rate counter only ever needs to distinguish "< MIN_ORDER_SPACING" from
  // ">=", so it saturates at MIN_ORDER_SPACING rather than growing without
  // bound -- an exact match for the Python model's comparison, since the
  // model's unbounded int has no other effect once it clears the threshold.
  // $clog2 of 1 is 0, which is not a legal vector width, hence the floor.
  localparam int RATE_W = (MIN_ORDER_SPACING < 1) ? 1 : $clog2(MIN_ORDER_SPACING + 1);

  // Per-symbol signed position register file.
  logic signed [34:0] pos_q [NUM_SYMBOLS];
  logic [RATE_W-1:0]  rate_q;

  // The post-accept value of the counter when an update coincides with the
  // accepted intent: 1, i.e. that later update counted afresh. Degenerates to
  // 0 when MIN_ORDER_SPACING is 0, where the counter saturates at 0 and the
  // rate check never binds.
  localparam logic [RATE_W-1:0] RATE_ONE = (MIN_ORDER_SPACING < 1) ? RATE_W'(0) : RATE_W'(1);

  logic [RATE_W-1:0] rate_next;
  assign rate_next = (rate_q >= RATE_W'(MIN_ORDER_SPACING)) ? rate_q : (rate_q + RATE_W'(1));

  // Effective rate count used for the comparison this cycle: the PRE-coincident
  // count. A same-cycle upd_valid is a later event than the intent being
  // judged (see the coincidence rule in the header) and is not folded in.
  logic [RATE_W-1:0] rate_eff;
  assign rate_eff = rate_q;

  // -------------------------------------------------------------- sanity
  logic sane;
  assign sane = (in.bid0 != 32'd0) && (in.ask0 != 32'd0) && (in.bid0 < in.ask0);

  // --------------------------------------------------------------- collar
  // mid = (bid0+ask0)>>1 needs one extra bit over the 32-bit fields to avoid
  // wrapping when both are near their max; the Python model's ints have no
  // such limit, and a wrap here would be a divergence.
  logic [32:0] bid_ask_sum;
  logic [31:0] mid, band;
  assign bid_ask_sum = {1'b0, in.bid0} + {1'b0, in.ask0};
  assign mid         = bid_ask_sum[32:1];
  assign band        = mid >> COLLAR_SHIFT;

  // price/mid comparison done in a signed width wide enough that neither the
  // subtraction nor the negation for abs() can overflow.
  logic signed [39:0] pdiff, pdiff_abs;
  assign pdiff     = signed'({8'd0, in.intent.price}) - signed'({8'd0, mid});
  assign pdiff_abs = pdiff[39] ? -pdiff : pdiff;

  logic collar_ok;
  assign collar_ok = !(pdiff_abs > signed'(40'(band)));

  // ----------------------------------------------------------------- rate
  logic rate_ok;
  assign rate_ok = (rate_eff >= RATE_W'(MIN_ORDER_SPACING));

  // -------------------------------------------------------------- position
  logic [book_pkg::BOOK_IDX_W-1:0] idx;
  assign idx = in.intent.symbol_idx;

  logic signed [39:0] pos_ext, shares_ext, delta, new_pos;
  assign pos_ext    = 40'(pos_q[idx]);                      // sign-extends (pos_q is signed)
  assign shares_ext = {8'd0, in.intent.shares};             // always non-negative
  assign delta      = in.intent.side ? shares_ext : -shares_ext;
  assign new_pos     = pos_ext + delta;

  logic signed [39:0] new_pos_abs;
  assign new_pos_abs = new_pos[39] ? -new_pos : new_pos;

  logic pos_ok;
  assign pos_ok = !(new_pos_abs > signed'(40'(MAX_POSITION)));

  // ------------------------------------------------------------- decision
  // Checks are evaluated in the contract's order; each reject signal is true
  // only when every earlier check passed, so at most one is ever asserted.
  logic reject_sanity, reject_collar, reject_rate, reject_pos, accept;
  assign reject_sanity = !sane;
  assign reject_collar = sane && !collar_ok;
  assign reject_rate   = sane && collar_ok && !rate_ok;
  assign reject_pos    = sane && collar_ok && rate_ok && !pos_ok;
  assign accept         = sane && collar_ok && rate_ok && pos_ok;

  // -------------------------------------------------------------- registers
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int s = 0; s < NUM_SYMBOLS; s++) pos_q[s] <= '0;
      rate_q               <= '0;
      out                  <= '0;
      out_valid            <= 1'b0;
      accept_count         <= '0;
      sanity_reject_count  <= '0;
      collar_reject_count  <= '0;
      rate_reject_count    <= '0;
      pos_reject_count     <= '0;
    end else begin
      out_valid <= 1'b0;

      // The rate counter advances on every book update, independent of
      // whether an intent is presented this cycle.
      if (upd_valid) rate_q <= rate_next;

      if (in_valid) begin
        if (accept) begin
          pos_q[idx]   <= new_pos[34:0];
          // Overrides the upd_valid increment above: the accept clears the
          // count, but a coincident (later-event) update still counts as 1.
          rate_q       <= upd_valid ? RATE_ONE : '0;
          accept_count <= accept_count + 32'd1;
          out          <= in.intent;
          out_valid    <= 1'b1;
        end else if (reject_sanity) begin
          sanity_reject_count <= sanity_reject_count + 32'd1;
        end else if (reject_collar) begin
          collar_reject_count <= collar_reject_count + 32'd1;
        end else if (reject_rate) begin
          rate_reject_count <= rate_reject_count + 32'd1;
        end else if (reject_pos) begin
          pos_reject_count <= pos_reject_count + 32'd1;
        end
      end
    end
  end

  // ------------------------------------------------------------- assertions
`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (rst_n) begin
      // Exactly one of accept/reject_* may be true for a given in.
      if ((int'(accept) + int'(reject_sanity) + int'(reject_collar) +
           int'(reject_rate) + int'(reject_pos)) > 1)
        $fatal(1, "risk_gate: more than one outcome asserted simultaneously");
      if (in_valid && !(accept || reject_sanity || reject_collar || reject_rate || reject_pos))
        $fatal(1, "risk_gate: in_valid with no outcome asserted");
      if (rate_q > RATE_W'(MIN_ORDER_SPACING))
        $fatal(1, "risk_gate: rate counter %0d exceeds saturation value %0d",
               rate_q, MIN_ORDER_SPACING);
    end
  end
`endif

endmodule
