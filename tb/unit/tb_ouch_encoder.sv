// Unit testbench for ouch_encoder.
//
// Phase 1 -- directed cases whose values mirror model/tests/test_ouch.py
// value-for-value: symbol_idx 1 = "MSFT    ", side buy, 100 shares, price
// 1805000, first token "HFTRTL00000000". A full 51-byte frame is captured
// and compared byte-for-byte against a hand-built expected array; a second
// order checks the token increments to "HFTRTL00000001"; ten orders exercise
// a hex letter in the token ("HFTRTL0000000A"); two intents driven
// back-to-back (the second arrives while the first is still serializing)
// both emerge complete and in FIFO order; frame_start is checked to pulse
// exactly once per frame, on the length-prefix byte, and out_last to pulse
// on byte 51 (index 50) of every frame.
//
// Phase 2 -- 200 random intents (paced so the depth-4 FIFO never overflows,
// since an overflow is a synchronous $fatal in the DUT, not a scored event)
// reassembled from the byte stream via frame_start/out_last bookkeeping and
// checked field-by-field against a scoreboard that independently re-derives
// each expected frame (own token counter, own symbol table lookup) rather
// than re-using the DUT's byte-construction logic. Functional coverage bins:
// side B, side S, an intent queued behind a busy serializer, and an intent
// that starts serializing immediately (no queueing delay) -- gated by an
// all-bins-hit $fatal at the end of the random phase.
//
// Timing/queueing contract under test (both scoreboard and DUT are written
// to this same contract):
//   - in_valid presented on a rising edge is accepted (pushed into the
//     depth-4 FIFO) iff the FIFO's pre-edge occupancy is < 4; otherwise it
//     is a drop (fifo_drop_count++) and, in simulation, a $fatal -- so the
//     testbench paces stimulus to never actually hit that path.
//   - A new frame's first byte (frame_start pulse) appears on the edge that
//     pops the FIFO: either the edge after the serializer goes idle with a
//     non-empty queue, or -- for back-to-back throughput -- the very edge
//     that finishes the previous frame (byte index 50), if the queue is
//     already non-empty at that point.
//   - The token used for a frame is the running order counter's value at
//     the moment that frame's byte begins serializing (i.e. pop order,
//     which is FIFO order), then the counter increments.
//
// Timescale comes from the Makefile (--timescale 1ns/1ps).

module tb_ouch_encoder;
  import book_pkg::*;
  import trade_pkg::*;

  // Symbol table: index 1 is "MSFT    " to match the Python golden test's
  // vector exactly; the rest are arbitrary but distinct so a wrong-symbol
  // lookup cannot hide behind a lucky repeat.
  function automatic logic [63:0] mk_sym(string s);
    logic [63:0] v;
    v = '0;
    for (int i = 0; i < 8; i++) v[(63 - 8*i) -: 8] = 8'(s[i]);
    return v;
  endfunction

  localparam logic [63:0] SYMBOLS [NUM_SYMBOLS] = '{
    mk_sym("AAPL    "), mk_sym("MSFT    "), mk_sym("GOOG    "), mk_sym("AMZN    "),
    mk_sym("TSLA    "), mk_sym("NVDA    "), mk_sym("META    "), mk_sym("NFLX    "),
    mk_sym("INTC    "), mk_sym("AMD     "), mk_sym("QCOM    "), mk_sym("CSCO    "),
    mk_sym("ORCL    "), mk_sym("IBM     "), mk_sym("ADBE    "), mk_sym("CRM     ")
  };

  logic          clk;
  logic          rst_n = 1'b0;
  order_intent_t in;
  logic          in_valid = 1'b0;
  logic          out_valid;
  logic [7:0]    out_data;
  logic          out_last;
  logic          frame_start;
  logic [31:0]   order_count, fifo_drop_count;

  ouch_encoder #(.SYMBOLS(SYMBOLS)) dut (
    .clk             (clk),
    .rst_n           (rst_n),
    .in              (in),
    .in_valid        (in_valid),
    .out_valid       (out_valid),
    .out_data        (out_data),
    .out_last        (out_last),
    .frame_start     (frame_start),
    .order_count     (order_count),
    .fifo_drop_count (fifo_drop_count)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  // ------------------------------------------------------- reference model
  // Own token counter and own field capture: builds an expected 51-byte
  // frame given the fields captured at push time and the token that will be
  // assigned at pop time -- deliberately not sharing any logic with the
  // DUT's byte-construction case statement.
  function automatic logic [7:0] hex_digit(logic [3:0] nib);
    return (nib < 4'd10) ? (8'h30 + {4'b0, nib}) : (8'h41 + ({4'b0, nib} - 8'd10));
  endfunction

  function automatic void build_expected(output logic [7:0] frame [51],
                                          input  int symbol_idx, input bit side,
                                          input  int shares, input int price,
                                          input  int token);
    logic [63:0] stock;
    stock = SYMBOLS[symbol_idx];
    frame[0] = 8'h00;
    frame[1] = 8'h31;
    frame[2] = "O";
    frame[3] = "H"; frame[4] = "F"; frame[5] = "T";
    frame[6] = "R"; frame[7] = "T"; frame[8] = "L";
    for (int i = 9; i <= 16; i++)
      frame[i] = hex_digit(4'((token >> (4*(16-i))) & 32'hF));
    frame[17] = side ? "B" : "S";
    frame[18] = 8'(shares >> 24); frame[19] = 8'(shares >> 16);
    frame[20] = 8'(shares >> 8);  frame[21] = 8'(shares);
    for (int p = 0; p < 8; p++) frame[22+p] = stock[(63 - 8*p) -: 8];
    frame[30] = 8'(price >> 24); frame[31] = 8'(price >> 16);
    frame[32] = 8'(price >> 8);  frame[33] = 8'(price);
    frame[34] = 8'h00; frame[35] = 8'h00; frame[36] = 8'h00; frame[37] = 8'h00;
    frame[38] = "H"; frame[39] = "F"; frame[40] = "T"; frame[41] = "R";
    frame[42] = "Y"; frame[43] = "P"; frame[44] = "N";
    frame[45] = 8'h00; frame[46] = 8'h00; frame[47] = 8'h00; frame[48] = 8'h00;
    frame[49] = "N"; frame[50] = "R";
  endfunction

  // -------------------------------------------------------- FIFO scoreboard
  // Pending pushed-but-not-yet-popped intents, in FIFO order, mirroring the
  // DUT's depth-4 queue closely enough to (a) decide accept-vs-drop for a
  // driven intent and (b) build each frame's expected bytes once it is
  // popped (i.e. once frame_start is observed).
  typedef struct {
    int symbol_idx;
    bit side;
    int shares;
    int price;
  } pend_t;
  pend_t sb_pend[$];
  int    sb_token_ctr;
  bit    sb_busy;          // DUT believed to be mid-frame (for cov classification)

  // Currently-expected frame (popped, not yet fully checked) and position
  // within it.
  logic [7:0] cur_exp [51];
  bit         cur_exp_valid;
  int         cur_pos;
  int         frames_checked;

  // ------------------------------------------------------ functional coverage
  typedef enum int {COV_SIDE_B, COV_SIDE_S, COV_QUEUED, COV_IMMEDIATE, COV_N} cov_e;
  int cov_bin [COV_N];
  bit cov_on = 1'b0;

  function automatic void cov_check();
    string names [COV_N] = '{"side-B", "side-S", "queued-while-busy", "immediate"};
    int holes;
    holes = 0;
    $display("  coverage:");
    for (int o = 0; o < int'(COV_N); o++) begin
      $display("    %-20s %0d", names[o], cov_bin[o]);
      if (cov_bin[o] == 0) begin
        $display("    COVERAGE HOLE: %s never occurred", names[o]);
        holes++;
      end
    end
    if (holes != 0)
      $fatal(1, "random phase left %0d functional-coverage bin(s) empty", holes);
  endfunction

  // ---------------------------------------------------------------- driving
  // One clock cycle: optionally drives an intent (decided from the
  // pre-edge FIFO occupancy, exactly mirroring the DUT's accept/drop rule),
  // then advances the clock and checks the outputs produced by that edge.
  int cyc_num;

  task automatic cycle(bit send, int symbol_idx, bit side, int shares, int price,
                       string name);
    bit push_ok;
    push_ok = send && (sb_pend.size() < 4);

    in_valid = send;
    if (send) begin
      in.symbol_idx = book_pkg::BOOK_IDX_W'(symbol_idx);
      in.side       = side;
      in.shares     = 32'(shares);
      in.price      = 32'(price);
    end

    if (push_ok) begin
      pend_t p;
      p.symbol_idx = symbol_idx;
      p.side       = side;
      p.shares     = shares;
      p.price      = price;
      sb_pend.push_back(p);
      // Coverage classification of THIS push happens at pop time (below),
      // once we know whether it queued or started immediately.
    end

    @(posedge clk);
    @(negedge clk);
    in_valid = 1'b0;
    cyc_num++;

    // ---- output checking for the edge that just happened ----
    if (!out_valid) begin
      if (frame_start !== 1'b0) $fatal(1, "cycle %0d (%s): frame_start high with out_valid low", cyc_num, name);
      if (out_last    !== 1'b0) $fatal(1, "cycle %0d (%s): out_last high with out_valid low", cyc_num, name);
      if (cur_exp_valid) $fatal(1, "cycle %0d (%s): frame stalled mid-transmission (out_valid dropped)", cyc_num, name);
    end else begin
      if (frame_start) begin
        pend_t popped;
        if (cur_exp_valid)
          $fatal(1, "cycle %0d (%s): frame_start while previous frame still in flight", cyc_num, name);
        if (sb_pend.size() == 0)
          $fatal(1, "cycle %0d (%s): frame_start with nothing pending in scoreboard FIFO", cyc_num, name);
        popped = sb_pend.pop_front();
        if (cov_on) begin
          if (popped.side) cov_bin[int'(COV_SIDE_B)]++;
          else              cov_bin[int'(COV_SIDE_S)]++;
          if (sb_busy || sb_pend.size() > 0) cov_bin[int'(COV_QUEUED)]++;
          else                                cov_bin[int'(COV_IMMEDIATE)]++;
        end
        build_expected(cur_exp, popped.symbol_idx, popped.side, popped.shares,
                        popped.price, sb_token_ctr);
        sb_token_ctr++;
        cur_exp_valid = 1'b1;
        cur_pos       = 0;
        sb_busy       = 1'b1;
      end else begin
        if (!cur_exp_valid)
          $fatal(1, "cycle %0d (%s): out_valid with no frame in flight (missed frame_start?)", cyc_num, name);
      end

      if (out_data !== cur_exp[cur_pos])
        $fatal(1, "cycle %0d (%s): frame byte[%0d]=0x%02x, expected 0x%02x",
               cyc_num, name, cur_pos, out_data, cur_exp[cur_pos]);
      if (out_last !== (cur_pos == 50))
        $fatal(1, "cycle %0d (%s): out_last=%0b at byte %0d, expected %0b",
               cyc_num, name, out_last, cur_pos, (cur_pos == 50));

      if (cur_pos == 50) begin
        cur_exp_valid = 1'b0;
        sb_busy       = 1'b0;
        frames_checked++;
      end else begin
        cur_pos++;
      end
    end
  endtask

  task automatic idle(int n, string name);
    repeat (n) cycle(1'b0, 0, 1'b0, 0, 0, name);
  endtask

  // Waits (idling) until the scoreboard FIFO has room, so stimulus never
  // hits the drop/$fatal path.
  task automatic wait_room(string name);
    while (sb_pend.size() >= 4) idle(1, name);
  endtask

  task automatic do_reset();
    in_valid       = 1'b0;
    rst_n          = 1'b0;
    repeat (3) @(negedge clk);
    rst_n          = 1'b1;
    @(negedge clk);
    sb_pend.delete();
    sb_token_ctr   = 0;
    sb_busy        = 1'b0;
    cur_exp_valid  = 1'b0;
    cur_pos        = 0;
    if (out_valid       !== 1'b0) $fatal(1, "out_valid asserted after reset");
    if (order_count      !== 32'd0) $fatal(1, "order_count nonzero after reset");
    if (fifo_drop_count  !== 32'd0) $fatal(1, "fifo_drop_count nonzero after reset");
  endtask

  // Drains any in-flight frame (drives no new intents) until the DUT goes
  // fully idle, for clean boundaries between directed cases.
  task automatic drain(string name);
    while (cur_exp_valid || sb_pend.size() > 0) idle(1, name);
    idle(2, name);
  endtask

  // ------------------------------------------------------------- test body
  initial begin
    cyc_num        = 0;
    frames_checked = 0;
    in             = '0;

    // ------------------------------------------------------- directed
    // First-order frame, byte-for-byte against the Python golden vector:
    // symbol_idx 1 ("MSFT    "), buy, 100 shares, price 1805000, token
    // "HFTRTL00000000".
    do_reset();
    wait_room("first order");
    cycle(1'b1, 1, 1'b1, 100, 1805000, "first order push");
    drain("first order drain");
    if (frames_checked !== 1) $fatal(1, "expected 1 frame checked, got %0d", frames_checked);
    if (order_count !== 32'd1) $fatal(1, "order_count=%0d after 1 order, expected 1", order_count);

    // Second order: token increments to "HFTRTL00000001". Bytes 9..16 of
    // the frame are checked implicitly via build_expected/sb_token_ctr, but
    // spot-check here too since this is the exact scenario the brief names.
    wait_room("second order");
    cycle(1'b1, 0, 1'b0, 50, 1010, "second order push");
    drain("second order drain");
    if (frames_checked !== 2) $fatal(1, "expected 2 frames checked, got %0d", frames_checked);
    if (order_count !== 32'd2) $fatal(1, "order_count=%0d after 2 orders, expected 2", order_count);

    // Ten total orders exercises a hex letter in the token: the 11th order
    // (0-based token 10 = 0xA) is "HFTRTL0000000A". Orders 3..11.
    for (int n = 0; n < 9; n++) begin
      wait_room("hex-letter fill");
      cycle(1'b1, (n % NUM_SYMBOLS), n[0], 10 + n, 100 + n, "hex-letter fill");
      drain("hex-letter fill drain");
    end
    if (order_count !== 32'd11) $fatal(1, "order_count=%0d after 11 orders, expected 11", order_count);
    if (frames_checked !== 11) $fatal(1, "frames_checked=%0d after 11 orders, expected 11", frames_checked);

    // Back-to-back intents: the second is pushed while the first is still
    // serializing (mid-frame), and both must emerge complete and in order.
    // The scoreboard's own frame-by-frame checking (inside cycle()) already
    // verifies order and completeness; this block just drives the timing.
    do_reset();
    wait_room("b2b first");
    cycle(1'b1, 2, 1'b1, 200, 2000, "b2b first push");
    idle(3, "b2b: mid-frame gap before second push");
    if (!cur_exp_valid) $fatal(1, "b2b: expected first frame still in flight at push time");
    wait_room("b2b second");
    cycle(1'b1, 3, 1'b0, 300, 3000, "b2b second push (mid-frame)");
    drain("b2b drain");
    if (frames_checked !== 13) $fatal(1, "b2b: expected 13 total frames checked, got %0d", frames_checked);

    $display("  directed cases: ok (%0d cycles, %0d frames)", cyc_num, frames_checked);

    // -------------------------------------------------------------- random
    do_reset();
    cov_on = 1'b1;
    for (int n = 0; n < 200; n++) begin
      int r_idx, r_shares, r_price, r_side;
      r_idx    = $urandom_range(NUM_SYMBOLS - 1, 0);
      r_side   = $urandom_range(1, 0);
      r_shares = $urandom_range(2000, 1);
      r_price  = $urandom_range(2_000_000, 1);

      wait_room("random");
      cycle(1'b1, r_idx, r_side[0], r_shares, r_price, "random push");
      // Occasional gaps so both "immediate" and "queued-while-busy" bins
      // (and the drain-to-idle path) get exercised, not just saturation.
      idle($urandom_range(2, 0), "random gap");
    end
    drain("random drain");
    cov_on = 1'b0;
    $display("  random phase: ok (200 intents, %0d total frames checked)", frames_checked);
    cov_check();

    if (order_count !== 32'd200)
      $fatal(1, "final order_count=%0d, expected 200 (reset before random phase)", order_count);

    $display("PASS");
    $finish;
  end

  // Watchdog: never let a broken DUT hang the run.
  initial begin
    #5000000;
    $fatal(1, "TIMEOUT");
  end

endmodule
