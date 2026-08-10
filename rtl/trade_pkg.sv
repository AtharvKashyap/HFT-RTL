// trade_pkg -- shared parameter defaults and datatypes for the trading path
// (strategy -> risk gate -> OUCH encoder) that sits downstream of the phase-1
// order book. book_pkg is a fixed contract and is not extended; everything the
// trading path introduces lives here.
//
// The defaults must stay identical to model/strategy.py and model/risk.py, as
// the RTL is checked bit-for-bit against those golden models.
package trade_pkg;
  parameter int THRESH_LOG2_DEF      = 2;
  parameter int COOLDOWN_UPDATES_DEF = 16;
  parameter int ORDER_SHARES_DEF     = 100;
  parameter int MAX_POSITION_DEF     = 1000;
  parameter int MIN_ORDER_SPACING_DEF = 10;
  parameter int COLLAR_SHIFT_DEF     = 3;

  typedef struct packed {
    logic [book_pkg::BOOK_IDX_W-1:0] symbol_idx;
    logic                            side;    // 1=buy, 0=sell
    logic [31:0]                     shares;
    logic [31:0]                     price;
  } order_intent_t;

  typedef struct packed {
    order_intent_t intent;
    logic [31:0]   bid0;   // level-0 prices from the triggering update
    logic [31:0]   ask0;
  } gated_intent_t;
endpackage
