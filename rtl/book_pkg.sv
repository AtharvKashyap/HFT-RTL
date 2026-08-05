package book_pkg;
  parameter int NUM_SYMBOLS   = 16;
  parameter int N_LEVELS      = 8;
  // Resting-order table address width (book_router). 20 bits = 1,048,576 slots.
  // Sized from the real capture: 13.6M messages of AAPL + MSFT alone peak at
  // 42,190 simultaneously live orders, which overruns a 16-bit (65,536-slot)
  // table at the open -- an 8-deep probe window starts failing, dropping ADDs
  // and every follow-up message for them, which is a hard divergence from the
  // Python model. At 20 bits the same feed never exhausts the probe window.
  // Sim-first: 2^20 x ~137b is trivial for Verilator. A real board port would
  // not store the full 64-bit order id per slot -- it would keep a hash tag and
  // move the table to external memory (phase-2 concern).
  parameter int TABLE_ADDR_W  = 20;
  parameter int MAX_PROBES    = 8;
  parameter int BOOK_IDX_W    = $clog2(NUM_SYMBOLS);

  typedef enum logic [2:0] {MSG_ADD, MSG_EXEC, MSG_CANCEL, MSG_DELETE,
                            MSG_REPLACE, MSG_SYSTEM} msg_kind_e;

  typedef struct packed {
    msg_kind_e   kind;
    logic [63:0] order_id;      // original ref for REPLACE
    logic [63:0] new_order_id;  // REPLACE only, else 0
    logic        side;          // 1=bid('B'), 0=ask('S'); ADD only
    logic [31:0] shares;
    logic [31:0] price;         // 1/10000 USD; ADD and REPLACE only
    logic [63:0] symbol;        // 8 ASCII chars; ADD only, else 0
  } decoded_msg_t;

  typedef enum logic {OP_ADD, OP_REDUCE} book_op_e;

  typedef struct packed {
    book_op_e                op;
    logic [BOOK_IDX_W-1:0]   book_idx;
    logic                    side;
    logic [31:0]             price;
    logic [31:0]             shares;
  } book_op_t;

  typedef struct packed {
    logic [BOOK_IDX_W-1:0]        book_idx;
    logic [N_LEVELS-1:0][31:0]    bid_price;
    logic [N_LEVELS-1:0][31:0]    bid_shares;
    logic [N_LEVELS-1:0][31:0]    ask_price;
    logic [N_LEVELS-1:0][31:0]    ask_shares;
    logic [63:0]                  timestamp;
  } book_update_t;
endpackage
