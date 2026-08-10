// Unit testbench for tick_to_trade_top -- end-to-end smoke test.
//
// Exercises the whole pipeline (itch_book_top -> strategy_imbalance ->
// risk_gate -> ouch_encoder) with a single scenario that fires an intent,
// gets it rate-rejected, re-arms through cooldown, and re-fires to a fully
// checked OUCH frame -- fire -> reject -> re-arm -> accept, end to end.
//
// Scenario (book_idx 0 = AAPL, book_idx 1 = MSFT):
//   Packet 1 (2 messages):
//     1. AAPL ADD ask 124 @ 1010000  -- state NEUTRAL->SHORT, blocked (bid0==0
//        so do_sell can't fire), no intent, cooldown NOT armed.
//     2. AAPL ADD bid  500 @ 1000000 -- mass_b=500 > mass_a<<2=124<<2=496, so
//        state SHORT->LONG: an edge, and ask0=1010000 != 0, so this DOES fire
//        (bid0=1000000, ask0=1010000, price=ask0=1010000). Only 2 book updates
//        have occurred (any symbol) at judgement time, far under
//        MIN_ORDER_SPACING=10, so risk_gate rate-rejects it. Firing (even
//        though later rejected) is what the strategy sees, so cooldown DOES
//        arm (COOLDOWN_UPDATES=16 further AAPL updates suppressed).
//   Packet 2 (26 messages):
//     3..11. Nine benign MSFT ADD-bid-same-price updates: pad the rate
//        counter and prove other symbols don't touch AAPL's cooldown.
//     12.    AAPL ADD ask 900 @ 1015000 (new, worse, level): flips AAPL back
//        to NEUTRAL (mass_b=500, mass_a=124+450=574; neither > the other's
//        <<2). Drain step 1/16 (cooldown 16->15).
//     13..27. Fifteen AAPL ADD-bid-1@900000 (same price, aggregate into a
//        worse level1, negligible mass): drain steps 2..16/16 (cooldown
//        15->0), state stays NEUTRAL throughout.
//     28.    AAPL ADD bid 3000 @ 1002000 (new best level, old levels shift
//        down): mass_b=3000+500>>1+15>>2=3253, mass_a=574 unchanged;
//        3253 > 574<<2=2296, so NEUTRAL->LONG, cooldown now 0 (not
//        suppressed) -- re-fires. bid0=1002000, ask0=1010000, price=ask0=
//        1010000. Sanity ok (bid0<ask0, both nonzero). Collar: mid=1006000,
//        band=125750, |1010000-1006000|=4000 -- passes. Rate: 28 updates
//        since reset, no prior accept -- passes (saturates well above 10).
//        Position: first-ever accept, |100|<=1000 -- passes. Accepted, and
//        the encoder emits exactly one OUCH frame, token "HFTRTL00000000"
//        (first-ever accepted order).
//
// The 51-byte frame is checked byte-for-byte against a hand-computed literal
// array (side 'B', shares 100, price 1010000, stock "AAPL    ", token all
// zero digits).
//
// Timescale comes from the Makefile (--timescale 1ns/1ps).

module tb_tick_to_trade_top;
  import book_pkg::*;
  import trade_pkg::*;

  localparam logic [63:0] SYM_LIST [NUM_SYMBOLS] =
      '{0: "AAPL    ", 1: "MSFT    ", default: 64'd0};

  logic         clk;
  logic         rst_n = 1'b0;
  logic         in_valid = 1'b0;
  logic [7:0]   in_data  = 8'h00;
  logic         in_ready;

  book_update_t upd;
  logic         upd_valid;
  logic         msg_boundary;
  logic [31:0]  gap_count, malformed_count, unknown_count;
  logic [31:0]  drop_count, table_full_count, reduce_miss_count, evict_count;
  logic         end_of_session;

  logic         ouch_valid;
  logic [7:0]   ouch_data;
  logic         ouch_last;
  logic         frame_start;
  logic [31:0]  intent_count, accept_count, sanity_reject_count;
  logic [31:0]  collar_reject_count, rate_reject_count, pos_reject_count;
  logic [31:0]  order_count, fifo_drop_count;

  tick_to_trade_top #(.SYMBOLS(SYM_LIST)) dut (
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

  initial clk = 1'b0;
  always #5 clk = ~clk;

  // ---------------------------------------------------------------- monitors
  book_update_t upd_got [$];
  logic [7:0]   frame_bytes [$];
  bit           frame_done_q [$];

  always @(posedge clk) begin
    if (rst_n && upd_valid) upd_got.push_back(upd);
    if (rst_n && ouch_valid) begin
      frame_bytes.push_back(ouch_data);
      if (ouch_last) frame_done_q.push_back(1'b1);
    end
  end

  // ------------------------------------------------------- payload builders
  typedef byte queue_t[$];

  function automatic queue_t be32(logic [31:0] v);
    queue_t q;
    for (int i = 3; i >= 0; i--) q.push_back(byte'(v[i*8+7 -: 8]));
    return q;
  endfunction

  function automatic queue_t be64(logic [63:0] v);
    queue_t q;
    for (int i = 7; i >= 0; i--) q.push_back(byte'(v[i*8+7 -: 8]));
    return q;
  endfunction

  function automatic queue_t be16(logic [15:0] v);
    queue_t q;
    q.push_back(byte'(v[15:8]));
    q.push_back(byte'(v[7:0]));
    return q;
  endfunction

  function automatic queue_t zeros(int n);
    queue_t q;
    for (int i = 0; i < n; i++) q.push_back(8'h00);
    return q;
  endfunction

  function automatic queue_t hdr10();
    return zeros(10);
  endfunction

  function automatic queue_t stock8(string s);
    queue_t q;
    for (int i = 0; i < 8; i++) q.push_back(byte'(s[i]));
    return q;
  endfunction

  // 'A' Add Order (36 bytes).
  function automatic queue_t build_add(logic [63:0] oid, byte side_ch,
                                        logic [31:0] shares, string stock,
                                        logic [31:0] price);
    queue_t q;
    q.push_back(8'h41);
    q = {q, hdr10()};
    q = {q, be64(oid)};
    q.push_back(side_ch);
    q = {q, be32(shares)};
    q = {q, stock8(stock)};
    q = {q, be32(price)};
    return q;
  endfunction

  typedef byte msg_t[$];

  function automatic queue_t build_packet(logic [63:0] seq, msg_t msgs[$]);
    queue_t pkt;
    pkt = zeros(10);  // session, arbitrary
    pkt = {pkt, be64(seq)};
    pkt = {pkt, be16(16'(msgs.size()))};
    foreach (msgs[i]) begin
      pkt = {pkt, be16(16'(msgs[i].size()))};
      pkt = {pkt, msgs[i]};
    end
    return pkt;
  endfunction

  // --------------------------------------------------------------- stimulus
  task automatic send_bytes(queue_t data);
    for (int i = 0; i < data.size(); i++) begin
      in_valid = 1'b1;
      in_data  = data[i];
      @(negedge clk);
    end
    in_valid = 1'b0;
  endtask

  task automatic idle(int n);
    in_valid = 1'b0;
    in_data  = 8'h00;
    repeat (n) @(negedge clk);
  endtask

  // ------------------------------------------------------------- test body
  msg_t msgs [$];
  logic [63:0] oid;

  logic [7:0] expected_frame [51];

  initial begin
    // Hand-computed OUCH frame: side B (buy), 100 shares, price 1010000,
    // stock "AAPL    ", token "HFTRTL00000000" (first-ever accepted order).
    expected_frame[0]  = 8'h00; expected_frame[1]  = 8'h31;  // length prefix (49)
    expected_frame[2]  = "O";
    expected_frame[3]  = "H"; expected_frame[4]  = "F"; expected_frame[5]  = "T";
    expected_frame[6]  = "R"; expected_frame[7]  = "T"; expected_frame[8]  = "L";
    expected_frame[9]  = "0"; expected_frame[10] = "0"; expected_frame[11] = "0";
    expected_frame[12] = "0"; expected_frame[13] = "0"; expected_frame[14] = "0";
    expected_frame[15] = "0"; expected_frame[16] = "0";
    expected_frame[17] = "B";                                 // side
    expected_frame[18] = 8'h00; expected_frame[19] = 8'h00;    // shares=100 BE32
    expected_frame[20] = 8'h00; expected_frame[21] = 8'h64;
    expected_frame[22] = "A"; expected_frame[23] = "A";        // stock "AAPL    "
    expected_frame[24] = "P"; expected_frame[25] = "L";
    expected_frame[26] = " "; expected_frame[27] = " ";
    expected_frame[28] = " "; expected_frame[29] = " ";
    expected_frame[30] = 8'h00; expected_frame[31] = 8'h0F;    // price=1010000 BE32
    expected_frame[32] = 8'h69; expected_frame[33] = 8'h50;
    expected_frame[34] = 8'h00; expected_frame[35] = 8'h00;    // TIF
    expected_frame[36] = 8'h00; expected_frame[37] = 8'h00;
    expected_frame[38] = "H"; expected_frame[39] = "F";        // firm "HFTR"
    expected_frame[40] = "T"; expected_frame[41] = "R";
    expected_frame[42] = "Y";                                  // display
    expected_frame[43] = "P";                                  // capacity
    expected_frame[44] = "N";                                  // ISO
    expected_frame[45] = 8'h00; expected_frame[46] = 8'h00;    // min qty
    expected_frame[47] = 8'h00; expected_frame[48] = 8'h00;
    expected_frame[49] = "N";                                  // cross type
    expected_frame[50] = "R";                                  // customer type

    in_valid = 1'b0;
    in_data  = 8'h00;

    repeat (3) @(negedge clk);
    rst_n = 1'b1;

    while (!in_ready) @(negedge clk);
    $display("  in_ready asserted after the table-clear sweep");

    // ---- packet 1: guaranteed fire, rate-rejected --------------------
    msgs.delete();
    msgs.push_back(build_add(64'd10, 8'h53 /* 'S' */, 32'd124, "AAPL    ", 32'd1010000));
    msgs.push_back(build_add(64'd11, 8'h42 /* 'B' */, 32'd500, "AAPL    ", 32'd1000000));
    send_bytes(build_packet(64'd1, msgs));
    idle(40);

    if (upd_got.size() !== 2)
      $fatal(1, "packet 1: expected 2 book updates, got %0d", upd_got.size());
    if (intent_count !== 32'd1)
      $fatal(1, "packet 1: expected intent_count 1, got %0d", intent_count);
    if (rate_reject_count !== 32'd1)
      $fatal(1, "packet 1: expected rate_reject_count 1, got %0d", rate_reject_count);
    if (accept_count !== 32'd0)
      $fatal(1, "packet 1: expected accept_count 0, got %0d", accept_count);
    if (order_count !== 32'd0)
      $fatal(1, "packet 1: expected order_count 0 (no frame yet), got %0d", order_count);
    if (frame_done_q.size() !== 0)
      $fatal(1, "packet 1: unexpected OUCH frame emerged after the rate-rejected fire");
    $display("  packet 1 ok: fire -> rate-rejected, no frame");

    // ---- packet 2: 9 benign MSFT updates, 16 AAPL cooldown-drain updates,
    // then the re-trigger that survives to an accepted OUCH frame --------
    msgs.delete();
    oid = 64'd20;
    for (int i = 0; i < 9; i++) begin
      msgs.push_back(build_add(oid, 8'h42 /* 'B' */, 32'd10, "MSFT    ", 32'd500000));
      oid++;
    end
    // Drain step 1/16: flips AAPL back to NEUTRAL, cooldown 16->15.
    msgs.push_back(build_add(64'd30, 8'h53 /* 'S' */, 32'd900, "AAPL    ", 32'd1015000));
    // Drain steps 2..16/16: negligible-mass AAPL bid fillers, cooldown 15->0.
    oid = 64'd40;
    for (int i = 0; i < 15; i++) begin
      msgs.push_back(build_add(oid, 8'h42 /* 'B' */, 32'd1, "AAPL    ", 32'd900000));
      oid++;
    end
    // Re-trigger: NEUTRAL->LONG edge, cooldown now 0 -- fires and is accepted.
    msgs.push_back(build_add(64'd99, 8'h42 /* 'B' */, 32'd3000, "AAPL    ", 32'd1002000));

    send_bytes(build_packet(64'd3, msgs));
    idle(200);

    if (upd_got.size() !== 28)
      $fatal(1, "packet 2: expected 28 total book updates, got %0d", upd_got.size());
    if (intent_count !== 32'd2)
      $fatal(1, "packet 2: expected intent_count 2, got %0d", intent_count);
    if (rate_reject_count !== 32'd1)
      $fatal(1, "packet 2: rate_reject_count changed unexpectedly, got %0d", rate_reject_count);
    if (sanity_reject_count !== 32'd0)
      $fatal(1, "packet 2: unexpected sanity_reject_count %0d", sanity_reject_count);
    if (collar_reject_count !== 32'd0)
      $fatal(1, "packet 2: unexpected collar_reject_count %0d", collar_reject_count);
    if (pos_reject_count !== 32'd0)
      $fatal(1, "packet 2: unexpected pos_reject_count %0d", pos_reject_count);
    if (accept_count !== 32'd1)
      $fatal(1, "packet 2: expected accept_count 1, got %0d", accept_count);
    if (order_count !== 32'd1)
      $fatal(1, "packet 2: expected order_count 1, got %0d", order_count);
    if (fifo_drop_count !== 32'd0)
      $fatal(1, "packet 2: unexpected fifo_drop_count %0d", fifo_drop_count);
    if (frame_done_q.size() !== 1)
      $fatal(1, "packet 2: expected exactly 1 OUCH frame, got %0d", frame_done_q.size());
    if (frame_bytes.size() !== 51)
      $fatal(1, "packet 2: expected a 51-byte frame, got %0d bytes", frame_bytes.size());

    for (int i = 0; i < 51; i++) begin
      if (frame_bytes[i] !== expected_frame[i])
        $fatal(1, "packet 2: frame byte[%0d]=0x%02x, expected 0x%02x",
               i, frame_bytes[i], expected_frame[i]);
    end
    $display("  packet 2 ok: 9 benign + 16 drain + re-trigger -> 1 accepted OUCH frame, bytes match");

    // ---- phase-1 pass-through counters still sane -----------------------
    if (gap_count         !== 32'd0) $fatal(1, "unexpected gap_count %0d", gap_count);
    if (malformed_count   !== 32'd0) $fatal(1, "unexpected malformed_count %0d", malformed_count);
    if (unknown_count     !== 32'd0) $fatal(1, "unexpected unknown_count %0d", unknown_count);
    if (drop_count        !== 32'd0) $fatal(1, "unexpected drop_count %0d", drop_count);
    if (table_full_count  !== 32'd0) $fatal(1, "unexpected table_full_count %0d", table_full_count);
    if (reduce_miss_count !== 32'd0) $fatal(1, "unexpected reduce_miss_count %0d", reduce_miss_count);
    if (evict_count       !== 32'd0) $fatal(1, "unexpected evict_count %0d", evict_count);
    if (end_of_session    !== 1'b0)  $fatal(1, "end_of_session unexpectedly set");
    $display("  phase-1 pass-through counters sane");

    $display("PASS");
    $finish;
  end

  // Watchdog. The post-reset table-clear sweep alone costs 2**TABLE_ADDR_W
  // (4,194,304) cycles; allow generously on top of that for the message
  // traffic and the OUCH frame's 51-cycle serialization.
  initial begin
    #200000000;
    $fatal(1, "TIMEOUT");
  end

endmodule
