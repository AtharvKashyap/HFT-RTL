// mold_framer -- byte-serial MoldUDP64 packet framer.
//
// One byte per cycle in. Strips the MoldUDP64 packet header (session[10B],
// sequence[8B BE], count[2B BE]) and each message's 2B BE length prefix,
// passing the message payload bytes straight through with `out_last` marking
// the final byte of each message.
//
// Sequence tracking: `expected_seq` predicts the next packet's header
// sequence as (previous received sequence + previous message count). A
// mismatch increments `gap_count` and resynchronizes off the sequence that
// was actually received (matches model/moldwrap.py semantics). count==0
// (heartbeat) and count==0xFFFF (end of session) contribute zero to the
// running sequence, mirroring the Python wrapper's `flush()`.
//
// count==0xFFFF also sets the sticky `end_of_session` flag and no message
// bytes are read for that packet. count==0 (heartbeat) likewise carries no
// messages. A zero-length message (len==0) increments `malformed_count` and
// the FSM proceeds directly to the next message's length field (or back to
// SESSION if it was the last one in the packet) -- no payload bytes for it.
//
// Errors are never fatal: the framer always keeps consuming bytes.
module mold_framer (
  input  logic        clk, rst_n,
  input  logic        in_valid,
  input  logic [7:0]  in_data,
  output logic        in_ready,       // always 1 in v1; kept for interface stability
  output logic        out_valid,
  output logic [7:0]  out_data,
  output logic        out_last,       // last byte of current ITCH message
  output logic [31:0] gap_count,
  output logic [31:0] malformed_count,
  output logic        end_of_session  // sticky, set on count==16'hFFFF
);

  assign in_ready = 1'b1;

  typedef enum logic [2:0] {
    ST_SESSION,
    ST_SEQ,
    ST_COUNT,
    ST_MSG_LEN,
    ST_MSG_BODY
  } state_e;

  state_e state;

  localparam int SESSION_LEN = 10;
  localparam int SEQ_LEN     = 8;
  localparam int COUNT_LEN   = 2;
  localparam int LEN_LEN     = 2;

  logic [3:0]  hdr_cnt;   // generic byte counter within SESSION/SEQ/COUNT/MSG_LEN
  logic [63:0] seq_reg;
  logic [15:0] count_reg;      // messages remaining to be read in this packet
  logic [15:0] msg_len_reg;
  logic [15:0] body_cnt;       // bytes of current message body already passed through

  logic [63:0] expected_seq;
  logic        first_pkt;    // no prior sequence to compare against yet

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state           <= ST_SESSION;
      hdr_cnt         <= '0;
      seq_reg         <= '0;
      count_reg       <= '0;
      msg_len_reg     <= '0;
      body_cnt        <= '0;
      expected_seq    <= '0;
      first_pkt       <= 1'b1;
      gap_count       <= '0;
      malformed_count <= '0;
      end_of_session  <= 1'b0;
      out_valid       <= 1'b0;
      out_data        <= '0;
      out_last        <= 1'b0;
    end else begin
      out_valid <= 1'b0;
      out_last  <= 1'b0;

      if (in_valid) begin
        unique case (state)
          // ---------------------------------------------------- SESSION
          ST_SESSION: begin
            if (hdr_cnt == 4'(SESSION_LEN - 1)) begin
              hdr_cnt <= '0;
              state   <= ST_SEQ;
            end else begin
              hdr_cnt <= hdr_cnt + 4'd1;
            end
          end

          // -------------------------------------------------------- SEQ
          ST_SEQ: begin
            seq_reg <= {seq_reg[55:0], in_data};
            if (hdr_cnt == 4'(SEQ_LEN - 1)) begin
              hdr_cnt <= '0;
              state   <= ST_COUNT;
            end else begin
              hdr_cnt <= hdr_cnt + 4'd1;
            end
          end

          // ------------------------------------------------------ COUNT
          ST_COUNT: begin
            count_reg <= {count_reg[7:0], in_data};
            if (hdr_cnt == 4'(COUNT_LEN - 1)) begin
              // Full header now available: seq_reg holds the received
              // sequence, count_reg will hold the final count byte once
              // this assignment lands next cycle -- compute directly from
              // the byte just latched to avoid a cycle of lag.
              logic [15:0] full_count;
              logic [63:0] rx_seq;
              logic [15:0] contrib;
              full_count = {count_reg[7:0], in_data};
              rx_seq     = seq_reg;
              contrib    = (full_count == 16'h0000 || full_count == 16'hFFFF) ? 16'd0 : full_count;

              if (!first_pkt && rx_seq != expected_seq) gap_count <= gap_count + 32'd1;
              first_pkt    <= 1'b0;
              expected_seq <= rx_seq + {48'd0, contrib};

              if (full_count == 16'hFFFF) begin
                end_of_session <= 1'b1;
                state          <= ST_SESSION;
              end else if (full_count == 16'h0000) begin
                state <= ST_SESSION;
              end else begin
                state <= ST_MSG_LEN;
              end
              hdr_cnt <= '0;
            end else begin
              hdr_cnt <= hdr_cnt + 4'd1;
            end
          end

          // ---------------------------------------------------- MSG_LEN
          ST_MSG_LEN: begin
            msg_len_reg <= {msg_len_reg[7:0], in_data};
            if (hdr_cnt == 4'(LEN_LEN - 1)) begin
              logic [15:0] full_len;
              full_len = {msg_len_reg[7:0], in_data};
              hdr_cnt  <= '0;
              if (full_len == 16'd0) begin
                // Zero-length message: no body bytes to read.
                malformed_count <= malformed_count + 32'd1;
                count_reg       <= count_reg - 16'd1;
                state           <= (count_reg == 16'd1) ? ST_SESSION : ST_MSG_LEN;
              end else begin
                body_cnt <= '0;
                state    <= ST_MSG_BODY;
              end
            end else begin
              hdr_cnt <= hdr_cnt + 4'd1;
            end
          end

          // --------------------------------------------------- MSG_BODY
          ST_MSG_BODY: begin
            out_valid <= 1'b1;
            out_data  <= in_data;
            if (body_cnt == msg_len_reg - 16'd1) begin
              out_last  <= 1'b1;
              count_reg <= count_reg - 16'd1;
              state     <= (count_reg == 16'd1) ? ST_SESSION : ST_MSG_LEN;
            end else begin
              body_cnt <= body_cnt + 16'd1;
            end
          end

          default: state <= ST_SESSION;
        endcase
      end
    end
  end

endmodule
