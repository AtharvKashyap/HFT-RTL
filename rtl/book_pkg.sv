package book_pkg;
  parameter int NUM_SYMBOLS   = 16;
  parameter int N_LEVELS      = 8;
  // Resting-order table address width (book_router). 22 bits = 4,194,304 slots.
  // Sized from the real capture, empirically, because an ADD whose 8-slot probe
  // window is full is dropped (table_full_count) and every follow-up message for
  // that order id then drops too -- a hard, permanent divergence from the Python
  // model, which has no notion of probe geometry.
  //
  // Measurements over 10M messages of 12302019.NASDAQ_ITCH50 for the 8 replay
  // symbols (peak 94,799 simultaneously live tracked orders), using a Python
  // replica of this table's exact hash + linear probing + tombstone logic:
  //   16 bits: probe window overflows repeatedly at the open.
  //   20 bits: 1 overflow (deepest insert probe used: 7 of 8) -- confirmed by
  //            the replay harness reporting table_full_count == 1, which cost
  //            one book update and one wrong price level for the rest of the run.
  //   21 bits: 0 overflows, deepest insert probe 4 of 8.
  //   22 bits: 0 overflows, deepest insert probe 2 of 8 -- 6 probes of headroom.
  // Occupancy is far below capacity in every case; the failures come from
  // clustering, since near-sequential ITCH order ids XOR-fold to near-sequential
  // slots and linear probing then piles them into contiguous runs. Extra address
  // bits spread those runs out, which is why they are the effective lever.
  //
  // Sim-first: 2^22 x ~137b is ~80 MB in Verilator and adds a 4.2M-cycle
  // post-reset clear sweep (~3 s), both negligible. A real board port would not
  // store the full 64-bit order id per slot -- it would keep a hash tag, mix the
  // hash to kill the sequential-id clustering, and move the table to external
  // memory (phase-2 concern).
  parameter int TABLE_ADDR_W  = 22;
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
