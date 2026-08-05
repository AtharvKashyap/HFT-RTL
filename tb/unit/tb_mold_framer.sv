// Unit testbench for mold_framer.
//
// Builds MoldUDP64 packets byte-by-byte per global-context.md's layout
// (session[0:9], sequence[10:17] BE, count[18:19] BE, then count x
// {2B BE length, message}) and checks the framer's byte-passthrough,
// message boundary (out_last), and anomaly-counting behavior.
//
// Timescale comes from the Makefile (--timescale 1ns/1ps) so the RTL stays
// free of timing directives.

module tb_mold_framer;

  logic        clk;
  logic        rst_n = 1'b0;
  logic        in_valid = 1'b0;
  logic [7:0]  in_data  = 8'h00;
  logic        in_ready;
  logic        out_valid;
  logic [7:0]  out_data;
  logic        out_last;
  logic [31:0] gap_count;
  logic [31:0] malformed_count;
  logic        end_of_session;

  mold_framer dut (
    .clk             (clk),
    .rst_n           (rst_n),
    .in_valid        (in_valid),
    .in_data         (in_data),
    .in_ready        (in_ready),
    .out_valid       (out_valid),
    .out_data        (out_data),
    .out_last        (out_last),
    .gap_count       (gap_count),
    .malformed_count (malformed_count),
    .end_of_session  (end_of_session)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  // ---------------------------------------------------------------- monitor
  // Reassembles the framer's output byte stream into a queue of messages,
  // splitting on out_last.
  typedef byte msg_t[$];
  msg_t cur;
  msg_t got[$];

  always @(posedge clk) begin
    if (out_valid) begin
      cur.push_back(out_data);
      if (out_last) begin
        got.push_back(cur);
        cur = {};
      end
    end
  end

  // ------------------------------------------------------- payload builders
  typedef byte queue_t[$];

  function automatic queue_t be16(logic [15:0] v);
    queue_t q;
    q.push_back(byte'(v[15:8]));
    q.push_back(byte'(v[7:0]));
    return q;
  endfunction

  function automatic queue_t be64(logic [63:0] v);
    queue_t q;
    for (int i = 7; i >= 0; i--) q.push_back(byte'(v[i*8+7 -: 8]));
    return q;
  endfunction

  // A trivial fixed-length "ITCH-ish" message body for framing purposes: the
  // framer only passes bytes through, so content is opaque filler.
  function automatic queue_t filler_msg(int len, byte tag);
    queue_t q;
    for (int i = 0; i < len; i++) q.push_back(tag + byte'(i));
    return q;
  endfunction

  // Builds a full MoldUDP64 packet. count_ovr, if >= 0, overrides the count
  // field written on the wire (used for heartbeat/end-of-session packets
  // that carry no messages of their own).
  function automatic queue_t build_packet(logic [63:0] seq, msg_t msgs[$],
                                           int count_ovr = -1);
    queue_t pkt;
    logic [15:0] count;
    count = (count_ovr >= 0) ? 16'(count_ovr) : 16'(msgs.size());
    for (int i = 0; i < 10; i++) pkt.push_back(byte'(8'h53 + 8'(i))); // session bytes, arbitrary
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
  // Drives a byte queue one byte per cycle. When gaps=1, deasserts in_valid
  // for a cycle after every third byte to prove idle cycles don't corrupt
  // framing.
  task automatic send_bytes(queue_t data, bit gaps = 0);
    for (int i = 0; i < data.size(); i++) begin
      in_valid = 1'b1;
      in_data  = data[i];
      @(negedge clk);
      if (gaps && (i % 3) == 1) begin
        in_valid = 1'b0;
        @(negedge clk);
      end
    end
    in_valid = 1'b0;
  endtask

  task automatic idle(int n);
    in_valid = 1'b0;
    in_data  = 8'h00;
    repeat (n) @(negedge clk);
  endtask

  // ---------------------------------------------------------------- checkers
  task automatic chk_msg_count(string name, int exp_n);
    if (got.size() !== exp_n)
      $fatal(1, "%s: got %0d messages, expected %0d", name, got.size(), exp_n);
    $display("  ok: %s (msg count)", name);
  endtask

  task automatic chk_msg(string name, int idx, msg_t exp);
    if (got[idx].size() !== exp.size())
      $fatal(1, "%s: msg[%0d] len %0d, expected %0d",
             name, idx, got[idx].size(), exp.size());
    foreach (exp[i])
      if (got[idx][i] !== exp[i])
        $fatal(1, "%s: msg[%0d] byte[%0d] = %0h, expected %0h",
               name, idx, i, got[idx][i], exp[i]);
    $display("  ok: %s (msg[%0d] content)", name, idx);
  endtask

  // -------------------------------------------------------------- test body
  initial begin
    idle(2);
    rst_n = 1'b1;
    idle(2);

    if (gap_count !== 32'd0)       $fatal(1, "gap_count not zero after reset");
    if (malformed_count !== 32'd0) $fatal(1, "malformed_count not zero after reset");
    if (end_of_session !== 1'b0)   $fatal(1, "end_of_session set after reset");
    if (got.size() !== 0)          $fatal(1, "spurious output after reset");

    // ---- Test 1: single packet, single message ----------------------
    begin
      msg_t msgs[$];
      msgs.push_back(filler_msg(5, 8'hA0));
      send_bytes(build_packet(64'd1, msgs));
      idle(4);
      chk_msg_count("single msg", 1);
      chk_msg("single msg", 0, msgs[0]);
      if (gap_count !== 32'd0) $fatal(1, "single msg: unexpected gap_count %0d", gap_count);
    end

    // ---- Test 2: multi-message packet (4 messages) -------------------
    begin
      msg_t msgs[$];
      msgs.push_back(filler_msg(3, 8'hB0));
      msgs.push_back(filler_msg(7, 8'hB1));
      msgs.push_back(filler_msg(1, 8'hB2));
      msgs.push_back(filler_msg(4, 8'hB3));
      // seq continues on from test 1 (prev seq 1 + prev count 1 = 2)
      send_bytes(build_packet(64'd2, msgs));
      idle(4);
      chk_msg_count("multi msg", 5);
      for (int i = 0; i < 4; i++) chk_msg("multi msg", 1 + i, msgs[i]);
      if (gap_count !== 32'd0) $fatal(1, "multi msg: unexpected gap_count %0d", gap_count);
    end

    // ---- Test 3: heartbeat (count == 0) produces no output ------------
    begin
      msg_t empty[$];
      // expected seq: prev seq 2 + prev count 4 = 6
      send_bytes(build_packet(64'd6, empty, 0));
      idle(4);
      chk_msg_count("heartbeat", 5);
      if (gap_count !== 32'd0) $fatal(1, "heartbeat: unexpected gap_count %0d", gap_count);
    end

    // ---- Test 4: sequence gap increments gap_count exactly once -------
    begin
      msg_t msgs[$];
      msgs.push_back(filler_msg(6, 8'hC0));
      // expected seq would be 6 (heartbeat added 0), but send seq 9: a gap.
      send_bytes(build_packet(64'd9, msgs));
      idle(4);
      chk_msg_count("gap", 6);
      chk_msg("gap", 5, msgs[0]);
      if (gap_count !== 32'd1)
        $fatal(1, "gap: gap_count %0d, expected 1", gap_count);

      // Stream continues normally: next packet resyncs off the received seq
      // (9 + 1 message = 10), no further gap.
      begin
        msg_t msgs2[$];
        msgs2.push_back(filler_msg(2, 8'hC1));
        send_bytes(build_packet(64'd10, msgs2));
        idle(4);
        chk_msg_count("gap recovery", 7);
        chk_msg("gap recovery", 6, msgs2[0]);
        if (gap_count !== 32'd1)
          $fatal(1, "gap recovery: gap_count %0d, expected still 1", gap_count);
      end
    end

    // ---- Test 5: zero-length message increments malformed_count -------
    begin
      msg_t msgs[$];
      msg_t zerolen;
      msgs.push_back(zerolen);                 // len == 0
      msgs.push_back(filler_msg(5, 8'hD0));     // must still decode after it
      // expected seq: prev seq 10 + prev count 1 = 11
      send_bytes(build_packet(64'd11, msgs));
      idle(4);
      chk_msg_count("zero-length", 8);
      chk_msg("zero-length", 7, msgs[1]);
      if (malformed_count !== 32'd1)
        $fatal(1, "zero-length: malformed_count %0d, expected 1", malformed_count);
      if (gap_count !== 32'd1)
        $fatal(1, "zero-length: unexpected gap_count change %0d", gap_count);
    end

    // ---- Test 6: idle gaps mid-packet frame identically ---------------
    begin
      msg_t msgs[$];
      msgs.push_back(filler_msg(9, 8'hE0));
      // expected seq: prev seq 11 + prev count 2 = 13
      send_bytes(build_packet(64'd13, msgs), 1'b1);
      idle(4);
      chk_msg_count("idle gaps", 9);
      chk_msg("idle gaps", 8, msgs[0]);
      if (gap_count !== 32'd1) $fatal(1, "idle gaps: unexpected gap_count %0d", gap_count);
    end

    // ---- Test 7: end-of-session sets sticky flag -----------------------
    begin
      msg_t empty[$];
      // expected seq: prev seq 13 + prev count 1 = 14
      send_bytes(build_packet(64'd14, empty, 32'h0000FFFF));
      idle(4);
      if (end_of_session !== 1'b1) $fatal(1, "end-of-session flag not set");
      chk_msg_count("end of session", 9); // no new messages
      // Sticky: send another packet afterwards, flag must stay set.
      begin
        msg_t msgs2[$];
        msgs2.push_back(filler_msg(3, 8'hF0));
        send_bytes(build_packet(64'd14, msgs2));
        idle(4);
        if (end_of_session !== 1'b1) $fatal(1, "end-of-session flag not sticky");
      end
    end

    $display("PASS");
    $finish;
  end

  // Watchdog: never let a broken DUT hang the run.
  initial begin
    #200000;
    $fatal(1, "TIMEOUT");
  end

endmodule
