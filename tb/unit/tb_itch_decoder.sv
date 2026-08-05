// Unit testbench for itch_decoder.
//
// Directed tests mirror model/tests/test_itch.py field-for-field so that the
// Python golden model and the RTL decoder are checked against the same vectors.
//
// Timescale comes from the Makefile (--timescale 1ns/1ps) so the RTL stays free
// of timing directives.

module tb_itch_decoder;
  import book_pkg::*;

  logic         clk;
  logic         rst_n = 1'b0;
  logic         in_valid = 1'b0;
  logic [7:0]   in_data  = 8'h00;
  logic         in_last  = 1'b0;
  decoded_msg_t out_msg;
  logic         out_valid;
  logic [31:0]  unknown_count;

  itch_decoder dut (
    .clk           (clk),
    .rst_n         (rst_n),
    .in_valid      (in_valid),
    .in_data       (in_data),
    .in_last       (in_last),
    .out_msg       (out_msg),
    .out_valid     (out_valid),
    .unknown_count (unknown_count)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  // ---------------------------------------------------------------- monitor
  int           seen;   // number of out_valid pulses observed
  decoded_msg_t last;   // most recently captured decoded message

  initial seen = 0;

  always @(posedge clk) begin
    if (out_valid) begin
      seen <= seen + 1;
      last <= out_msg;
    end
  end

  // ------------------------------------------------------- payload builders
  byte pay[$];

  task automatic p8(byte v);
    pay.push_back(v);
  endtask

  task automatic p16(logic [15:0] v);
    p8(byte'(v[15:8]));
    p8(byte'(v[7:0]));
  endtask

  task automatic p32(logic [31:0] v);
    p16(v[31:16]);
    p16(v[15:0]);
  endtask

  task automatic p64(logic [63:0] v);
    p32(v[63:32]);
    p32(v[31:0]);
  endtask

  // Common ITCH header: type[0], stock_locate[1:2], tracking[3:4], timestamp[5:10]
  task automatic hdr(byte t);
    pay.delete();
    p8(t);
    p16(16'd1);
    p16(16'd0);
    p32(32'd0);
    p16(16'd0);
  endtask

  // 8-char space-padded stock symbol
  task automatic pstr8(string s);
    for (int i = 0; i < 8; i++) p8(byte'(s[i]));
  endtask

  // --------------------------------------------------------------- stimulus
  // Drives the queued payload one byte per cycle, asserting in_last on the
  // final byte. Leaves in_valid asserted on exit so two consecutive calls
  // produce back-to-back messages with no idle cycle.
  task automatic send_msg();
    for (int i = 0; i < pay.size(); i++) begin
      in_valid = 1'b1;
      in_data  = pay[i];
      in_last  = (i == pay.size() - 1);
      @(negedge clk);
    end
  endtask

  task automatic idle(int n);
    in_valid = 1'b0;
    in_last  = 1'b0;
    in_data  = 8'h00;
    repeat (n) @(negedge clk);
  endtask

  // ---------------------------------------------------------------- checkers
  task automatic chk(string name, int exp_seen, msg_kind_e k,
                     logic [63:0] oid, logic [63:0] nid, logic sd,
                     logic [31:0] sh, logic [31:0] pr, logic [63:0] sym);
    if (seen !== exp_seen)
      $fatal(1, "%s: out_valid pulse count %0d, expected %0d", name, seen, exp_seen);
    if (last.kind !== k)
      $fatal(1, "%s: kind %0d, expected %0d", name, last.kind, k);
    if (last.order_id !== oid)
      $fatal(1, "%s: order_id %0d, expected %0d", name, last.order_id, oid);
    if (last.new_order_id !== nid)
      $fatal(1, "%s: new_order_id %0d, expected %0d", name, last.new_order_id, nid);
    if (last.side !== sd)
      $fatal(1, "%s: side %0b, expected %0b", name, last.side, sd);
    if (last.shares !== sh)
      $fatal(1, "%s: shares %0d, expected %0d", name, last.shares, sh);
    if (last.price !== pr)
      $fatal(1, "%s: price %0d, expected %0d", name, last.price, pr);
    if (last.symbol !== sym)
      $fatal(1, "%s: symbol %h, expected %h", name, last.symbol, sym);
    $display("  ok: %s", name);
  endtask

  task automatic chk_unknown(string name, int exp_seen, logic [31:0] exp_unknown);
    if (seen !== exp_seen)
      $fatal(1, "%s: out_valid pulse count %0d, expected %0d (must not decode)",
             name, seen, exp_seen);
    if (unknown_count !== exp_unknown)
      $fatal(1, "%s: unknown_count %0d, expected %0d", name, unknown_count, exp_unknown);
    $display("  ok: %s", name);
  endtask

  // -------------------------------------------------------------- test body
  initial begin
    idle(2);
    rst_n = 1'b1;
    idle(2);

    if (unknown_count !== 32'd0) $fatal(1, "unknown_count not zero after reset");
    if (seen !== 0)              $fatal(1, "spurious out_valid after reset");

    // 'A' Add Order (36B) -- matches test_add_order
    hdr("A");
    p64(64'd42); p8("B"); p32(32'd100); pstr8("AAPL    "); p32(32'd1805000);
    if (pay.size() != 36) $fatal(1, "A payload built with %0d bytes", pay.size());
    send_msg();
    idle(2);
    chk("A add", 1, MSG_ADD, 64'd42, 64'd0, 1'b1, 32'd100, 32'd1805000, "AAPL    ");

    // 'F' Add Order with MPID (40B) -- matches test_add_order_with_mpid
    hdr("F");
    p64(64'd7); p8("S"); p32(32'd200); pstr8("MSFT    "); p32(32'd3210000);
    p8("M"); p8("P"); p8("I"); p8("D"); // 4-byte attribution field, ignored
    if (pay.size() != 40) $fatal(1, "F payload built with %0d bytes", pay.size());
    send_msg();
    idle(2);
    chk("F add w/ mpid", 2, MSG_ADD, 64'd7, 64'd0, 1'b0, 32'd200, 32'd3210000, "MSFT    ");

    // 'E' Order Executed (31B) -- matches test_executed
    hdr("E");
    p64(64'd42); p32(32'd30); p64(64'd0);
    if (pay.size() != 31) $fatal(1, "E payload built with %0d bytes", pay.size());
    send_msg();
    idle(2);
    chk("E exec", 3, MSG_EXEC, 64'd42, 64'd0, 1'b0, 32'd30, 32'd0, 64'd0);

    // 'C' Order Executed with Price (36B) -- matches test_executed_with_price
    hdr("C");
    p64(64'd42); p32(32'd30); p64(64'd0); p8(8'd0); p32(32'd1805000);
    if (pay.size() != 36) $fatal(1, "C payload built with %0d bytes", pay.size());
    send_msg();
    idle(2);
    // exec_price is ignored: the book reduces at the resting price.
    chk("C exec w/ price", 4, MSG_EXEC, 64'd42, 64'd0, 1'b0, 32'd30, 32'd0, 64'd0);

    // 'X' Order Cancel (23B) -- matches test_cancel
    hdr("X");
    p64(64'd42); p32(32'd25);
    if (pay.size() != 23) $fatal(1, "X payload built with %0d bytes", pay.size());
    send_msg();
    idle(2);
    chk("X cancel", 5, MSG_CANCEL, 64'd42, 64'd0, 1'b0, 32'd25, 32'd0, 64'd0);

    // 'D' Order Delete (19B) -- matches test_delete
    hdr("D");
    p64(64'd42);
    if (pay.size() != 19) $fatal(1, "D payload built with %0d bytes", pay.size());
    send_msg();
    idle(2);
    chk("D delete", 6, MSG_DELETE, 64'd42, 64'd0, 1'b0, 32'd0, 32'd0, 64'd0);

    // 'U' Order Replace (35B) -- matches test_replace
    hdr("U");
    p64(64'd42); p64(64'd43); p32(32'd50); p32(32'd1804000);
    if (pay.size() != 35) $fatal(1, "U payload built with %0d bytes", pay.size());
    send_msg();
    idle(2);
    chk("U replace", 7, MSG_REPLACE, 64'd42, 64'd43, 1'b0, 32'd50, 32'd1804000, 64'd0);

    // 'S' System Event (12B) -- matches test_system_event
    hdr("S");
    p8("O");
    if (pay.size() != 12) $fatal(1, "S payload built with %0d bytes", pay.size());
    send_msg();
    idle(2);
    chk("S system", 8, MSG_SYSTEM, 64'd0, 64'd0, 1'b0, 32'd0, 32'd0, 64'd0);

    // Unknown type 'P' (34B) -- matches test_unknown_type_returns_none
    hdr("P");
    for (int i = 0; i < 23; i++) p8(8'd0);
    if (pay.size() != 34) $fatal(1, "P payload built with %0d bytes", pay.size());
    send_msg();
    idle(2);
    chk_unknown("P unknown type", 8, 32'd1);

    // Truncated 'A' (19B instead of 36) -- matches test_truncated_payload_returns_none
    hdr("A");
    p64(64'd42);
    if (pay.size() != 19) $fatal(1, "truncated A built with %0d bytes", pay.size());
    send_msg();
    idle(2);
    chk_unknown("A truncated", 8, 32'd2);

    // Recovery: a good message right after the two bad ones must still decode,
    // proving the byte buffer/counter reset after every message.
    hdr("D");
    p64(64'd99);
    send_msg();
    idle(2);
    chk("D after errors", 9, MSG_DELETE, 64'd99, 64'd0, 1'b0, 32'd0, 32'd0, 64'd0);

    // Back-to-back messages with no idle cycle between them.
    hdr("X");
    p64(64'd7); p32(32'd5);
    send_msg();
    hdr("D");
    p64(64'd8);
    send_msg();
    hdr("A");
    p64(64'd9); p8("S"); p32(32'd11); pstr8("TSLA    "); p32(32'd2500000);
    send_msg();
    idle(2);
    chk("back-to-back last (A)", 12, MSG_ADD, 64'd9, 64'd0, 1'b0, 32'd11,
        32'd2500000, "TSLA    ");
    if (unknown_count !== 32'd2)
      $fatal(1, "back-to-back: unknown_count %0d, expected 2", unknown_count);

    $display("PASS");
    $finish;
  end

  // Watchdog: never let a broken DUT hang the run.
  initial begin
    #100000;
    $fatal(1, "TIMEOUT");
  end

endmodule
