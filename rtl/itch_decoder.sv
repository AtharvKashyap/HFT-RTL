// itch_decoder -- byte-serial Nasdaq TotalView-ITCH 5.0 message decoder.
//
// One byte per cycle in; `in_last` marks the final byte of a message. Bytes are
// accumulated into a 40-byte buffer (40 = longest message we care about, 'F').
// On the final byte the whole message is decoded combinationally and registered,
// so `out_valid` pulses for exactly one cycle, the cycle after `in_last`.
//
// A known type whose observed length differs from the spec length, or an unknown
// type, increments `unknown_count` and produces no `out_valid`. Errors are never
// fatal: the buffer and byte counter reset after every message, good or bad.
//
// Multi-byte ITCH fields are big-endian on the wire and are normalized here.
module itch_decoder (
  input  logic        clk, rst_n,
  input  logic        in_valid,
  input  logic [7:0]  in_data,
  input  logic        in_last,       // final byte of one ITCH message
  output book_pkg::decoded_msg_t out_msg,
  output logic        out_valid,     // 1-cycle pulse, cycle after in_last
  output logic [31:0] unknown_count
);
  import book_pkg::*;

  localparam int         MAX_LEN = 40;     // longest handled message ('F')
  localparam logic [5:0] LEN_MAX = 6'd40;
  localparam logic [5:0] CNT_SAT = 6'd63;  // counter saturation

  // ITCH message type characters
  localparam logic [7:0] T_SYSTEM  = 8'h53; // 'S'
  localparam logic [7:0] T_ADD     = 8'h41; // 'A'
  localparam logic [7:0] T_ADD_MP  = 8'h46; // 'F'
  localparam logic [7:0] T_EXEC    = 8'h45; // 'E'
  localparam logic [7:0] T_EXEC_PR = 8'h43; // 'C'
  localparam logic [7:0] T_CANCEL  = 8'h58; // 'X'
  localparam logic [7:0] T_DELETE  = 8'h44; // 'D'
  localparam logic [7:0] T_REPLACE = 8'h55; // 'U'
  localparam logic [7:0] SIDE_BUY  = 8'h42; // 'B'

  logic [MAX_LEN-1:0][7:0] msg_buf;
  logic [5:0]              byte_cnt;  // bytes already latched into msg_buf

  // Write index, clamped so a longer-than-MAX_LEN message cannot index past the
  // buffer (such a message can only ever be counted as unknown anyway).
  logic [5:0] widx;
  assign widx = (byte_cnt < LEN_MAX) ? byte_cnt : 6'd0;

  // ------------------------------------------------------------------------
  // Combinational view of the message including the byte arriving this cycle,
  // so the final byte can be decoded without an extra cycle of latency.
  // ------------------------------------------------------------------------
  logic [MAX_LEN-1:0][7:0] view;
  logic [5:0]              view_len;

  always_comb begin
    view = msg_buf;
    if (in_valid && (byte_cnt < LEN_MAX)) view[widx] = in_data;
    view_len = (in_valid && (byte_cnt != CNT_SAT)) ? (byte_cnt + 6'd1) : byte_cnt;
  end

  // ------------------------------------------------------- type / length table
  logic [5:0] exp_len;
  logic       known;
  msg_kind_e  kind;

  always_comb begin
    known   = 1'b1;
    exp_len = 6'd0;
    kind    = MSG_SYSTEM;
    case (view[0])
      T_SYSTEM:  begin exp_len = 6'd12; kind = MSG_SYSTEM;  end
      T_ADD:     begin exp_len = 6'd36; kind = MSG_ADD;     end
      T_ADD_MP:  begin exp_len = 6'd40; kind = MSG_ADD;     end
      T_EXEC:    begin exp_len = 6'd31; kind = MSG_EXEC;    end
      T_EXEC_PR: begin exp_len = 6'd36; kind = MSG_EXEC;    end
      T_CANCEL:  begin exp_len = 6'd23; kind = MSG_CANCEL;  end
      T_DELETE:  begin exp_len = 6'd19; kind = MSG_DELETE;  end
      T_REPLACE: begin exp_len = 6'd35; kind = MSG_REPLACE; end
      default:   known = 1'b0;
    endcase
  end

  logic dec_ok;
  assign dec_ok = known && (view_len == exp_len);

  // ------------------------------------------------------------ field extract
  // Common header: type[0], stock_locate[1:2], tracking[3:4], timestamp[5:10].
  logic [63:0] ref_at11;   // 8-byte order reference at offset 11
  logic [31:0] shares_at19;

  assign ref_at11    = {view[11], view[12], view[13], view[14],
                        view[15], view[16], view[17], view[18]};
  assign shares_at19 = {view[19], view[20], view[21], view[22]};

  decoded_msg_t dec_msg;

  always_comb begin
    dec_msg      = '0;
    dec_msg.kind = kind;
    case (kind)
      MSG_ADD: begin
        // order_ref[11:18], side[19], shares[20:23], stock[24:31], price[32:35]
        dec_msg.order_id = ref_at11;
        dec_msg.side     = (view[19] == SIDE_BUY);
        dec_msg.shares   = {view[20], view[21], view[22], view[23]};
        dec_msg.symbol   = {view[24], view[25], view[26], view[27],
                            view[28], view[29], view[30], view[31]};
        dec_msg.price    = {view[32], view[33], view[34], view[35]};
      end
      MSG_EXEC: begin
        // order_ref[11:18], exec_shares[19:22]. price stays 0: the book reduces
        // at the resting price, so 'C' exec_price is deliberately ignored.
        dec_msg.order_id = ref_at11;
        dec_msg.shares   = shares_at19;
      end
      MSG_CANCEL: begin
        // order_ref[11:18], canceled_shares[19:22]
        dec_msg.order_id = ref_at11;
        dec_msg.shares   = shares_at19;
      end
      MSG_DELETE: begin
        // order_ref[11:18]
        dec_msg.order_id = ref_at11;
      end
      MSG_REPLACE: begin
        // orig_ref[11:18], new_ref[19:26], shares[27:30], price[31:34]
        dec_msg.order_id     = ref_at11;
        dec_msg.new_order_id = {view[19], view[20], view[21], view[22],
                                view[23], view[24], view[25], view[26]};
        dec_msg.shares       = {view[27], view[28], view[29], view[30]};
        dec_msg.price        = {view[31], view[32], view[33], view[34]};
      end
      default: begin
        // MSG_SYSTEM (and unknown types, which never assert out_valid): no fields.
      end
    endcase
  end

  // ------------------------------------------------------------- register out
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      msg_buf       <= '0;
      byte_cnt      <= '0;
      out_msg       <= '0;
      out_valid     <= 1'b0;
      unknown_count <= '0;
    end else begin
      out_valid <= 1'b0;
      if (in_valid) begin
        if (in_last) begin
          // Reset for the next message regardless of decode success.
          msg_buf  <= '0;
          byte_cnt <= '0;
          if (dec_ok) begin
            out_msg   <= dec_msg;
            out_valid <= 1'b1;
          end else begin
            unknown_count <= unknown_count + 32'd1;
          end
        end else begin
          if (byte_cnt < LEN_MAX) msg_buf[widx] <= in_data;
          if (byte_cnt != CNT_SAT) byte_cnt <= byte_cnt + 6'd1;
        end
      end
    end
  end

endmodule
