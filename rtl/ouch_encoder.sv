// ouch_encoder -- serializes accepted order_intent_t pulses (from risk_gate)
// into OUCH 4.2 Enter Order wire frames, one byte per cycle.
//
// Bit-matches model/ouch.py's OuchEncoder: a 2-byte big-endian length prefix
// (always 49) followed by the fixed 49-byte Enter Order body --
//   'O' | 14B token | side | 4B shares (BE) | 8B stock | 4B price (BE) |
//   4B TIF(=0) | 4B firm("HFTR") | display('Y') | capacity('P') |
//   ISO('N') | 4B min-qty(=0) | cross-type('N') | customer-type('R')
// -- for 51 bytes total per frame. The order token is "HFTRTL" followed by 8
// uppercase-hex digits of a free-running 32-bit counter that also doubles as
// order_count; the stock field is SYMBOLS[in.symbol_idx], an 8-character
// (64-bit) ASCII field with the same byte order itch_decoder uses for
// decoded_msg_t.symbol (character 0 in bits [63:56]).
//
// Queueing: risk_gate can present accepted intents faster than one every 51
// cycles, so a depth-4 FIFO absorbs bursts. in_valid presented while the
// FIFO already holds 4 entries is a drop (fifo_drop_count++); this is meant
// to be caught by the caller sizing its burst tolerance, not to happen in
// normal operation, hence the simulation-only assertion below.
//
// Serializer/FIFO handoff: the FIFO's occupancy (count_q) and read/write
// pointers are read at their pre-edge (current) values to decide both this
// cycle's push (in_valid && count_q < 4) and this cycle's pop, so a push and
// a pop on the same edge are independent and both land via the same
// nonblocking update. A pop happens either when the serializer is idle and
// the queue is non-empty, or -- for back-to-back throughput with no idle
// gap -- on the very edge that finishes a frame (byte_idx_q == 50) if the
// queue is already non-empty at that point. The frame's fields (side,
// shares, price, looked-up stock) and its token (the counter's pre-increment
// value) are latched at pop time and held for the whole 51-cycle frame.
//
// Outputs: out_valid/out_data/out_last (asserted on cycles the byte at index
// 50 is on out_data) are combinational functions of the current state, so
// they land the same cycle byte_idx_q reflects a freshly popped frame's
// index 0 -- which is also the cycle frame_start pulses.
module ouch_encoder #(
  parameter logic [63:0] SYMBOLS [book_pkg::NUM_SYMBOLS] = '{default: '0}
) (
  input  logic clk, rst_n,
  input  trade_pkg::order_intent_t in,
  input  logic                     in_valid,
  output logic       out_valid,
  output logic [7:0] out_data,
  output logic       out_last,          // final byte of a frame
  output logic       frame_start,       // 1-cycle pulse on the FIRST byte of a frame (harness latency hook)
  output logic [31:0] order_count, fifo_drop_count
);

  localparam int FIFO_DEPTH = 4;
  localparam int PTR_W      = $clog2(FIFO_DEPTH);

  typedef enum logic {ST_IDLE, ST_SEND} state_e;

  // ------------------------------------------------------------- FIFO state
  trade_pkg::order_intent_t queue_mem [FIFO_DEPTH];
  logic [PTR_W-1:0] wr_ptr_q, rd_ptr_q;
  logic [PTR_W:0]   count_q;   // 0..FIFO_DEPTH, one extra bit for depth==4

  // ------------------------------------------------------------ serializer
  state_e        state_q;
  logic [5:0]    byte_idx_q;      // 0..50
  trade_pkg::order_intent_t cur_intent_q;
  logic [63:0]   cur_stock_q;
  logic [31:0]   cur_token_q;

  logic push_ok, pop_ok;
  assign push_ok = in_valid && (count_q < (PTR_W+1)'(FIFO_DEPTH));
  assign pop_ok  = (count_q > '0) &&
                    ((state_q == ST_IDLE) || (state_q == ST_SEND && byte_idx_q == 6'd50));

  assign out_valid   = (state_q == ST_SEND);
  assign out_last    = out_valid && (byte_idx_q == 6'd50);
  assign frame_start = out_valid && (byte_idx_q == 6'd0);

  // -------------------------------------------------------- byte generation
  function automatic logic [7:0] hex_digit(logic [3:0] nib);
    return (nib < 4'd10) ? (8'h30 + {4'b0, nib}) : (8'h41 + ({4'b0, nib} - 8'd10));
  endfunction

  function automatic logic [7:0] frame_byte(logic [5:0] idx,
                                             trade_pkg::order_intent_t it,
                                             logic [63:0] stock,
                                             logic [31:0] token);
    logic [7:0] b;
    b = 8'h00;
    case (idx)
      6'd0:  b = 8'h00;                          // length prefix hi
      6'd1:  b = 8'h31;                          // length prefix lo (49)
      6'd2:  b = "O";
      6'd3:  b = "H"; 6'd4:  b = "F"; 6'd5:  b = "T";
      6'd6:  b = "R"; 6'd7:  b = "T"; 6'd8:  b = "L";
      6'd9, 6'd10, 6'd11, 6'd12, 6'd13, 6'd14, 6'd15, 6'd16:
        b = hex_digit(4'((token >> (4*(16-int'(idx)))) & 32'hF));
      6'd17: b = it.side ? "B" : "S";
      6'd18: b = it.shares[31:24]; 6'd19: b = it.shares[23:16];
      6'd20: b = it.shares[15:8];  6'd21: b = it.shares[7:0];
      6'd22, 6'd23, 6'd24, 6'd25, 6'd26, 6'd27, 6'd28, 6'd29:
        b = stock[(63 - 8*(int'(idx)-22)) -: 8];
      6'd30: b = it.price[31:24]; 6'd31: b = it.price[23:16];
      6'd32: b = it.price[15:8];  6'd33: b = it.price[7:0];
      6'd34, 6'd35, 6'd36, 6'd37: b = 8'h00;      // time-in-force (IOC)
      6'd38: b = "H"; 6'd39: b = "F"; 6'd40: b = "T"; 6'd41: b = "R";
      6'd42: b = "Y";                             // display
      6'd43: b = "P";                             // capacity
      6'd44: b = "N";                             // intermarket sweep
      6'd45, 6'd46, 6'd47, 6'd48: b = 8'h00;       // min quantity
      6'd49: b = "N";                              // cross type
      6'd50: b = "R";                              // customer type
      default: b = 8'h00;
    endcase
    return b;
  endfunction

  assign out_data = out_valid ? frame_byte(byte_idx_q, cur_intent_q, cur_stock_q, cur_token_q)
                               : 8'h00;

  // -------------------------------------------------------------- registers
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wr_ptr_q        <= '0;
      rd_ptr_q        <= '0;
      count_q         <= '0;
      state_q         <= ST_IDLE;
      byte_idx_q      <= '0;
      cur_intent_q    <= '0;
      cur_stock_q     <= '0;
      cur_token_q     <= '0;
      order_count     <= '0;
      fifo_drop_count <= '0;
    end else begin
      // ---- FIFO push ----
      if (push_ok) begin
        queue_mem[wr_ptr_q] <= in;
        wr_ptr_q            <= wr_ptr_q + PTR_W'(1);
      end else if (in_valid) begin
        fifo_drop_count <= fifo_drop_count + 32'd1;
      end

      // ---- pop / serializer advance ----
      if (pop_ok) begin
        cur_intent_q <= queue_mem[rd_ptr_q];
        cur_stock_q  <= SYMBOLS[queue_mem[rd_ptr_q].symbol_idx];
        cur_token_q  <= order_count;
        order_count  <= order_count + 32'd1;
        rd_ptr_q     <= rd_ptr_q + PTR_W'(1);
        byte_idx_q   <= 6'd0;
        state_q      <= ST_SEND;
      end else if (state_q == ST_SEND) begin
        if (byte_idx_q == 6'd50) state_q <= ST_IDLE;
        else                     byte_idx_q <= byte_idx_q + 6'd1;
      end

      count_q <= count_q + ((push_ok ? (PTR_W+1)'(1) : (PTR_W+1)'(0))) -
                            ((pop_ok  ? (PTR_W+1)'(1) : (PTR_W+1)'(0)));
    end
  end

  // ------------------------------------------------------------- assertions
`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (in_valid && !push_ok)
        $fatal(1, "ouch_encoder: intent dropped, FIFO full (fifo_drop_count now %0d)",
               fifo_drop_count + 32'd1);
      if (count_q > (PTR_W+1)'(FIFO_DEPTH))
        $fatal(1, "ouch_encoder: FIFO count %0d exceeds depth %0d", count_q, FIFO_DEPTH);
      if (state_q == ST_SEND && byte_idx_q > 6'd50)
        $fatal(1, "ouch_encoder: byte_idx %0d out of range mid-frame", byte_idx_q);
    end
  end
`endif

endmodule
