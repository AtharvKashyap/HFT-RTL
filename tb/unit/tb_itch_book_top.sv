// Unit testbench for itch_book_top -- end-to-end smoke test.
//
// Drives one MoldUDP64 packet containing four ITCH messages for AAPL
// (book_idx 0) byte-by-byte into the top level: an Add bid, an Add ask, an
// Executed partially reducing the bid, and a Delete removing the ask. Each
// message is expected to produce exactly one `upd` snapshot, and every
// snapshot is checked against the hand-computed book state. A second packet
// (heartbeat, count==0) and a third (end-of-session, count==0xFFFF) then
// exercise the sticky `end_of_session` flag.
//
// INTEGRATION REQUIREMENT under test: book_router runs a
// 2**TABLE_ADDR_W-cycle table-clear sweep after reset with no backpressure,
// so itch_book_top must hold `in_ready` low until that sweep finishes. This
// TB waits for `in_ready` before driving any byte, which is the whole point
// of the requirement -- driving earlier would silently lose the first
// message (and this TB would then fail the snapshot checks instead of
// exercising the gate).
//
// Timescale comes from the Makefile (--timescale 1ns/1ps).

module tb_itch_book_top;
  import book_pkg::*;

  localparam logic [63:0] SYM_LIST [NUM_SYMBOLS] =
      '{0: "AAPL    ", default: 64'd0};

  logic         clk;
  logic         rst_n = 1'b0;
  logic         in_valid = 1'b0;
  logic [7:0]   in_data  = 8'h00;
  logic         in_ready;
  book_update_t upd;
  logic         upd_valid;
  logic [31:0]  gap_count, malformed_count, unknown_count;
  logic [31:0]  drop_count, table_full_count;
  logic         end_of_session;
  logic         msg_boundary;
  logic [31:0]  reduce_miss_count, evict_count;

  itch_book_top #(.SYMBOLS(SYM_LIST)) dut (
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

  initial clk = 1'b0;
  always #5 clk = ~clk;

  // ---------------------------------------------------------------- monitor
  book_update_t got [$];

  always @(posedge clk) begin
    if (rst_n && upd_valid) got.push_back(upd);
  end

  // ------------------------------------------------------- payload builders
  typedef byte queue_t[$];

  function automatic queue_t be16(logic [15:0] v);
    queue_t q;
    q.push_back(byte'(v[15:8]));
    q.push_back(byte'(v[7:0]));
    return q;
  endfunction

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

  function automatic queue_t zeros(int n);
    queue_t q;
    for (int i = 0; i < n; i++) q.push_back(8'h00);
    return q;
  endfunction

  // Common header after the type byte: stock_locate[2B] + tracking[2B] +
  // timestamp[6B], all ignored by the decoder -- zero-filled here.
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

  // 'E' Executed (31 bytes).
  function automatic queue_t build_exec(logic [63:0] oid, logic [31:0] shares);
    queue_t q;
    q.push_back(8'h45);
    q = {q, hdr10()};
    q = {q, be64(oid)};
    q = {q, be32(shares)};
    q = {q, zeros(8)};  // match_num, ignored
    return q;
  endfunction

  // 'D' Delete (19 bytes).
  function automatic queue_t build_delete(logic [63:0] oid);
    queue_t q;
    q.push_back(8'h44);
    q = {q, hdr10()};
    q = {q, be64(oid)};
    return q;
  endfunction

  typedef byte msg_t[$];

  // Full MoldUDP64 packet. count_ovr, if >= 0, overrides the wire count
  // field (used for heartbeat/end-of-session packets that carry no
  // messages of their own).
  function automatic queue_t build_packet(logic [63:0] seq, msg_t msgs[$],
                                           int count_ovr = -1);
    queue_t pkt;
    logic [15:0] count;
    count = (count_ovr >= 0) ? 16'(count_ovr) : 16'(msgs.size());
    pkt = zeros(10);  // session, arbitrary
    pkt = {pkt, be64(seq)};
    pkt = {pkt, be16(count)};
    if (count_ovr < 0) begin
      foreach (msgs[i]) begin
        pkt = {pkt, be16(16'(msgs[i].size()))};
        pkt = {pkt, msgs[i]};
      end
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

  // ---------------------------------------------------------------- checker
  task automatic chk_snapshot(string name, int idx,
                               logic [31:0] bid_px, logic [31:0] bid_sh,
                               logic [31:0] ask_px, logic [31:0] ask_sh);
    book_update_t s;
    s = got[idx];
    if (s.book_idx !== BOOK_IDX_W'(0))
      $fatal(1, "%s: snapshot[%0d] book_idx=%0d, expected 0", name, idx, s.book_idx);
    if (s.bid_price[0] !== bid_px || s.bid_shares[0] !== bid_sh)
      $fatal(1, "%s: snapshot[%0d] bid[0]=(%0d,%0d), expected (%0d,%0d)",
             name, idx, s.bid_price[0], s.bid_shares[0], bid_px, bid_sh);
    if (s.ask_price[0] !== ask_px || s.ask_shares[0] !== ask_sh)
      $fatal(1, "%s: snapshot[%0d] ask[0]=(%0d,%0d), expected (%0d,%0d)",
             name, idx, s.ask_price[0], s.ask_shares[0], ask_px, ask_sh);
    for (int i = 1; i < N_LEVELS; i++) begin
      if (s.bid_price[i] !== 32'd0 || s.bid_shares[i] !== 32'd0)
        $fatal(1, "%s: snapshot[%0d] bid[%0d] not zero", name, idx, i);
      if (s.ask_price[i] !== 32'd0 || s.ask_shares[i] !== 32'd0)
        $fatal(1, "%s: snapshot[%0d] ask[%0d] not zero", name, idx, i);
    end
    $display("  ok: %s snapshot[%0d]", name, idx);
  endtask

  // ------------------------------------------------------------- test body
  msg_t msgs [$];

  initial begin
    in_valid = 1'b0;
    in_data  = 8'h00;

    repeat (3) @(negedge clk);
    rst_n = 1'b1;

    // ---- gate under test: in_ready must stay low through the post-reset
    // table-clear sweep, and any byte offered while low must be ignored.
    if (in_ready !== 1'b0) $fatal(1, "in_ready asserted before the clear sweep finished");
    // Try to smuggle a byte in while gated: it must not be consumed.
    in_valid = 1'b1;
    in_data  = 8'hFF;
    @(negedge clk);
    in_valid = 1'b0;
    if (got.size() != 0) $fatal(1, "a snapshot appeared despite in_ready being low");

    while (!in_ready) @(negedge clk);
    $display("  in_ready asserted after the table-clear sweep");

    // ---- packet 1: Add bid, Add ask, Exec (partial reduce), Delete -----
    msgs.delete();
    msgs.push_back(build_add(64'd1, 8'h42 /* 'B' */, 32'd100, "AAPL    ", 32'd1805000));
    msgs.push_back(build_add(64'd2, 8'h53 /* 'S' */, 32'd50,  "AAPL    ", 32'd1806000));
    msgs.push_back(build_exec(64'd1, 32'd40));
    msgs.push_back(build_delete(64'd2));
    send_bytes(build_packet(64'd1, msgs));
    idle(8);

    if (got.size() !== 4)
      $fatal(1, "expected 4 snapshots, got %0d", got.size());

    chk_snapshot("add bid",    0, 32'd1805000, 32'd100, 32'd0,       32'd0);
    chk_snapshot("add ask",    1, 32'd1805000, 32'd100, 32'd1806000, 32'd50);
    chk_snapshot("exec 40",    2, 32'd1805000, 32'd60,  32'd1806000, 32'd50);
    chk_snapshot("delete ask", 3, 32'd1805000, 32'd60,  32'd0,       32'd0);

    for (int i = 1; i < 4; i++)
      if (!(got[i].timestamp > got[i-1].timestamp))
        $fatal(1, "timestamp did not strictly increase at snapshot %0d (%0d -> %0d)",
               i, got[i-1].timestamp, got[i].timestamp);

    if (unknown_count !== 32'd0) $fatal(1, "unexpected unknown_count %0d", unknown_count);
    if (drop_count    !== 32'd0) $fatal(1, "unexpected drop_count %0d", drop_count);
    if (end_of_session !== 1'b0) $fatal(1, "end_of_session set too early");

    // ---- packet 2: heartbeat (count == 0) -- no messages, no snapshots -
    msgs.delete();
    send_bytes(build_packet(64'd5, msgs, 0));
    idle(8);
    if (got.size() !== 4) $fatal(1, "heartbeat produced a spurious snapshot");
    if (end_of_session !== 1'b0) $fatal(1, "end_of_session set by heartbeat");

    // ---- packet 3: end of session (count == 0xFFFF) --------------------
    msgs.delete();
    send_bytes(build_packet(64'd5, msgs, 'hFFFF));
    idle(8);
    if (end_of_session !== 1'b1) $fatal(1, "end_of_session not set after count==0xFFFF");
    // Sticky: stays set.
    idle(4);
    if (end_of_session !== 1'b1) $fatal(1, "end_of_session did not stay set");

    if (gap_count !== 32'd0) $fatal(1, "unexpected gap_count %0d", gap_count);

    $display("PASS");
    $finish;
  end

  // Watchdog. The post-reset table-clear sweep alone costs 2**TABLE_ADDR_W
  // cycles; allow generously on top of that for the message traffic.
  initial begin
    #200000000;
    $fatal(1, "TIMEOUT");
  end

endmodule
