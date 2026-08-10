// replay_main.cpp -- Verilator C++ replay harness for tick_to_trade_top.
//
// Streams a pre-wrapped MoldUDP64 byte file (produced by
// `model/dump_trace.py --wrap-out`, i.e. byte-identical to what the Python
// golden model consumed) into the DUT one byte per clock, and writes one JSONL
// line per book update in exactly the golden-trace format plus a `lat` field:
//
//   {"n": <ordinal>, "symbol_idx": <book_idx>,
//    "bid": [[px,sh] x 8], "ask": [[px,sh] x 8], "lat": <cycles>}
//
// ORDINAL ALIGNMENT (the whole comparison hinges on this)
// ------------------------------------------------------
// `dump_trace` numbers updates with `n` = the 0-based index, over ALL messages
// read from the capture (parsed or not, tracked or not), of the message BEING
// PROCESSED. The DUT's `msg_boundary` pulses once per message that leaves the
// framer, on the cycle carrying that message's last byte -- so after the pulse
// for message k, `msgs_seen` is k+1 and any update that follows belongs to
// message k = msgs_seen-1. Hence, each cycle: consume `upd_valid` FIRST using
// msgs_seen-1, THEN apply this cycle's boundary pulse -- so an update landing on
// the very same cycle as the next boundary is still attributed to the message
// that produced it.
//
// That ordering fixes the same-cycle case only. The margins beyond it:
//   * Consecutive boundaries are 2 + len(next message) cycles apart (the two
//     BinaryFILE/MoldUDP64 length bytes plus the next message's own bytes), more
//     across a packet edge (20-byte MoldUDP64 header) or whenever in_ready
//     deasserts. The shortest ITCH message in this feed is a 12-byte system
//     event, so the true floor is 14 cycles -- not 21; 19 bytes (Delete) is the
//     shortest *table-touching* message, which is a different question.
//   * Worst-case boundary->update latency is ~18 cycles: 1 framer->decoder, up
//     to 16 in the router (a REPLACE doing two MAX_PROBES-deep probe walks), 1
//     in price_book.
// 18 > 14, so a bound-by-construction argument does NOT hold: a maximally slow
// REPLACE followed immediately by a 12-byte system event could in principle emit
// after the next boundary and be attributed to msgs_seen-1 one too high. Two
// things keep the runs sound. First, measurement: over 260,053 updates from 10M
// real messages the observed maximum was 7 cycles, half the 14-cycle floor --
// the worst case needs a REPLACE whose two probe walks both run to depth 8,
// which a table with 6 probes of headroom never produces. Second, and more
// importantly, misattribution is not silent: `n` is written into the trace and
// compared against the golden model as data, so any skew fails the comparison
// rather than hiding. Zero mismatches is therefore also the evidence that no
// update was ever misattributed.
//
// `lat` is (cycle of upd_valid) - (cycle of the most recent msg_boundary),
// i.e. end-of-message to book-snapshot latency in clock cycles.
//
// ORDER STREAM (--orders-out)
// ---------------------------
// The DUT also emits OUCH 4.2 Enter Order frames byte-serially on
// ouch_valid/ouch_data, with ouch_last on the final byte and frame_start on
// the first. The harness reassembles each frame and writes one JSONL line:
//
//   {"n": <msg ordinal at frame_start>, "raw": "<hex>", "lat": <cycles>}
//
// `n` uses exactly the same rule as a book update -- msgs_seen-1, consumed
// before this cycle's boundary pulse is applied. The margin is wider here than
// for book updates: an order can only follow the update that triggered it, so
// its boundary->frame_start distance is the update latency plus the
// strategy(1) + risk(1) + encoder-pop(1) cycles, observed at 9 cycles max on
// the 10M run against the same 14-cycle floor on message spacing. As with
// updates, this is not merely an argument: `n` is written into the trace and
// compared against the golden model, so any skew fails the comparison instead
// of hiding. `orphan_orders` (frame_start before the first msg_boundary)
// counts what the ordinal rule cannot express at all and must stay 0.
//
// `raw` is compared byte-for-byte against model/ouch.py's frame, which
// includes the order token -- so the RTL's free-running token counter and the
// model's must stay in lockstep, i.e. the two must accept exactly the same
// orders in exactly the same sequence.
//
// in_ready: itch_book_top holds it low for the 2**TABLE_ADDR_W-cycle post-reset
// table-clear sweep and any byte offered while it is low is dropped, not
// buffered, so the harness waits for it before feeding byte 0. It is sampled
// BEFORE each posedge (pre-edge value) to decide whether the byte was accepted;
// sampling after eval() would read the post-edge register value.

#include "Vreplay_top.h"
#include "verilated.h"

#include <algorithm>
#include <chrono>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

namespace {

constexpr int N_LEVELS = 8;
constexpr int DRAIN_CYCLES = 256;   // let the pipeline empty after the last byte

// ------------------------------------------------------------------ byte feed
class ByteFeed {
 public:
  explicit ByteFeed(const char* path) {
    f_ = std::fopen(path, "rb");
    if (!f_) {
      std::fprintf(stderr, "replay: cannot open %s: %s\n", path, std::strerror(errno));
      std::exit(2);
    }
    buf_.resize(1 << 20);
  }
  ~ByteFeed() { if (f_) std::fclose(f_); }

  // Returns false at end of stream.
  bool peek(uint8_t* out) {
    if (pos_ == fill_) {
      fill_ = std::fread(buf_.data(), 1, buf_.size(), f_);
      pos_ = 0;
      if (fill_ == 0) return false;
    }
    *out = buf_[pos_];
    return true;
  }
  void advance() { ++pos_; ++consumed_; }
  uint64_t consumed() const { return consumed_; }

 private:
  std::FILE* f_ = nullptr;
  std::vector<uint8_t> buf_;
  size_t pos_ = 0, fill_ = 0;
  uint64_t consumed_ = 0;
};

// --------------------------------------------------------------- JSONL writer
// Hand-rolled formatting: at tens of millions of messages, printf-per-field is
// a measurable share of wall time.
class JsonlWriter {
 public:
  explicit JsonlWriter(const char* path) {
    f_ = std::fopen(path, "wb");
    if (!f_) {
      std::fprintf(stderr, "replay: cannot open %s for writing: %s\n",
                   path, std::strerror(errno));
      std::exit(2);
    }
    out_.reserve(1 << 21);
  }
  ~JsonlWriter() { flush(); if (f_) std::fclose(f_); }

  void num(uint64_t v) {
    char tmp[24];
    int i = 0;
    if (v == 0) { tmp[i++] = '0'; }
    while (v) { tmp[i++] = static_cast<char>('0' + (v % 10)); v /= 10; }
    while (i) out_.push_back(tmp[--i]);
  }
  void lit(const char* s) { out_.append(s); }
  void hexbyte(uint8_t b) {
    static const char kHex[] = "0123456789abcdef";
    out_.push_back(kHex[b >> 4]);
    out_.push_back(kHex[b & 0xf]);
  }
  void endline() {
    out_.push_back('\n');
    if (out_.size() >= (1u << 20)) flush();
  }
  void flush() {
    if (!out_.empty() && f_) {
      std::fwrite(out_.data(), 1, out_.size(), f_);
      out_.clear();
    }
  }

 private:
  std::FILE* f_ = nullptr;
  std::string out_;
};

struct Percentiles {
  uint32_t min = 0, median = 0, p99 = 0, max = 0;
};

Percentiles percentiles(std::vector<uint32_t>& v) {
  Percentiles p;
  if (v.empty()) return p;
  std::sort(v.begin(), v.end());
  p.min = v.front();
  p.max = v.back();
  p.median = v[v.size() / 2];
  size_t idx = static_cast<size_t>(0.99 * static_cast<double>(v.size()));
  if (idx >= v.size()) idx = v.size() - 1;
  p.p99 = v[idx];
  return p;
}

void usage() {
  std::fprintf(stderr,
      "usage: replay --in <stream.mold> --out <rtl.jsonl> "
      "[--orders-out <rtl_orders.jsonl>] [--progress N] [--no-lat-hist]\n"
      "       replay --in <fuzz.mold> --out <rtl.jsonl> --fuzz "
      "--tail-start <byte-offset> [--watchdog N]\n"
      "\n"
      "--fuzz mode (robustness): the input is expected to be a stream produced by\n"
      "model/fuzz_stream.py -- an in-band-corrupted section followed by a clean\n"
      "tail of valid messages starting at byte offset --tail-start (the tool's\n"
      "own metadata sidecar reports this). Pass criteria, checked at exit:\n"
      "  1. no hang: some observable output (msg_boundary, upd_valid, or any\n"
      "     status counter) must change at least once every --watchdog cycles\n"
      "     (default 10000) for as long as bytes remain.\n"
      "  2. at least one error counter (gap/malformed/unknown/drop/table_full/\n"
      "     reduce_miss/evict) is nonzero.\n"
      "  3. at least one book update is emitted from bytes at or after "
      "--tail-start.\n"
      "Exit 0 = pass, 1 = fail (reason on stderr), 2 = usage error.\n");
}

}  // namespace

int main(int argc, char** argv) {
  const char* in_path = nullptr;
  const char* out_path = nullptr;
  const char* orders_path = nullptr;
  uint64_t progress_every = 1000000;
  bool keep_lat = true;
  bool fuzz = false;
  uint64_t tail_start = 0;
  bool have_tail_start = false;
  uint64_t watchdog_limit = 10000;

  for (int i = 1; i < argc; ++i) {
    if (!std::strcmp(argv[i], "--in") && i + 1 < argc)        in_path = argv[++i];
    else if (!std::strcmp(argv[i], "--out") && i + 1 < argc)  out_path = argv[++i];
    else if (!std::strcmp(argv[i], "--orders-out") && i + 1 < argc)
      orders_path = argv[++i];
    else if (!std::strcmp(argv[i], "--progress") && i + 1 < argc)
      progress_every = std::strtoull(argv[++i], nullptr, 10);
    else if (!std::strcmp(argv[i], "--no-lat-hist"))          keep_lat = false;
    else if (!std::strcmp(argv[i], "--fuzz"))                 fuzz = true;
    else if (!std::strcmp(argv[i], "--tail-start") && i + 1 < argc) {
      tail_start = std::strtoull(argv[++i], nullptr, 10);
      have_tail_start = true;
    } else if (!std::strcmp(argv[i], "--watchdog") && i + 1 < argc)
      watchdog_limit = std::strtoull(argv[++i], nullptr, 10);
    else { usage(); return 2; }
  }
  if (!in_path || !out_path) { usage(); return 2; }
  if (fuzz && !have_tail_start) {
    std::fprintf(stderr, "replay: --fuzz requires --tail-start <byte-offset>\n");
    usage();
    return 2;
  }

  Verilated::traceEverOn(false);
  auto* top = new Vreplay_top;
  ByteFeed feed(in_path);
  JsonlWriter jsonl(out_path);
  std::unique_ptr<JsonlWriter> orders_jsonl;
  if (orders_path) orders_jsonl.reset(new JsonlWriter(orders_path));

  uint64_t cycle = 0;
  uint64_t msgs_seen = 0;
  uint64_t updates = 0;
  uint64_t last_boundary_cycle = 0;
  uint64_t orphan_updates = 0;   // upd_valid before any msg_boundary: must stay 0
  std::vector<uint32_t> lats;
  if (keep_lat) lats.reserve(1 << 20);

  // ------------------------------------------------------------ order stream
  // A frame is opened by frame_start and closed by ouch_last; the bytes in
  // between are the wire frame, buffered so the line can carry `raw` whole.
  uint64_t frames = 0;              // frames completed (frame_start..ouch_last)
  uint64_t ouch_bytes = 0;
  uint64_t orphan_orders = 0;       // frame_start before any msg_boundary
  uint64_t truncated_frames = 0;    // stream ended mid-frame: must stay 0
  bool     frame_open = false;
  uint64_t frame_n = 0, frame_lat = 0;
  std::vector<uint8_t> frame_buf;
  frame_buf.reserve(64);
  std::vector<uint32_t> order_lats;
  if (keep_lat) order_lats.reserve(1 << 12);

  // --fuzz bookkeeping: a hang watchdog (armed only once bytes start flowing)
  // and a before/after-tail split of update counts.
  uint64_t last_progress_cycle = 0;
  uint32_t prev_gap = 0, prev_malformed = 0, prev_unknown = 0, prev_drop = 0,
           prev_table_full = 0, prev_reduce_miss = 0, prev_evict = 0;
  bool     prev_eos = false;
  uint64_t updates_before_tail = 0, updates_after_tail = 0;
  bool     hang_detected = false;

  const auto t_start = std::chrono::steady_clock::now();
  uint64_t next_progress = progress_every;

  // ------------------------------------------------------------------- reset
  top->clk = 0;
  top->rst_n = 0;
  top->in_valid = 0;
  top->in_data = 0;
  top->eval();
  for (int i = 0; i < 10; ++i) {
    top->clk = 1; top->eval();
    top->clk = 0; top->eval();
  }
  top->rst_n = 1;

  // Sampled after each posedge; consumed at the top of the next iteration.
  auto sample = [&]() {
    if (top->upd_valid) {
      if (msgs_seen == 0) {
        ++orphan_updates;
      } else {
        jsonl.lit("{\"n\": ");
        jsonl.num(msgs_seen - 1);
        jsonl.lit(", \"symbol_idx\": ");
        jsonl.num(top->upd_book_idx);
        jsonl.lit(", \"bid\": [");
        for (int j = 0; j < N_LEVELS; ++j) {
          if (j) jsonl.lit(", ");
          jsonl.lit("[");
          jsonl.num(top->bid_price[j]);
          jsonl.lit(", ");
          jsonl.num(top->bid_shares[j]);
          jsonl.lit("]");
        }
        jsonl.lit("], \"ask\": [");
        for (int j = 0; j < N_LEVELS; ++j) {
          if (j) jsonl.lit(", ");
          jsonl.lit("[");
          jsonl.num(top->ask_price[j]);
          jsonl.lit(", ");
          jsonl.num(top->ask_shares[j]);
          jsonl.lit("]");
        }
        jsonl.lit("], \"lat\": ");
        const uint64_t lat = cycle - last_boundary_cycle;
        jsonl.num(lat);
        jsonl.lit("}");
        jsonl.endline();
        if (keep_lat) lats.push_back(static_cast<uint32_t>(lat));
        ++updates;
        if (fuzz) {
          if (feed.consumed() > tail_start) ++updates_after_tail;
          else                              ++updates_before_tail;
        }
      }
    }
    // Order stream. frame_start is asserted on the same cycle as the frame's
    // first ouch_valid byte, so it must be handled first; and, like upd_valid
    // above, both are consumed BEFORE this cycle's boundary pulse is applied.
    if (top->frame_start) {
      if (msgs_seen == 0) {
        ++orphan_orders;
        frame_open = false;
      } else {
        frame_open = true;
        frame_n = msgs_seen - 1;
        frame_lat = cycle - last_boundary_cycle;
        frame_buf.clear();
      }
    }
    if (top->ouch_valid) {
      ++ouch_bytes;
      if (frame_open) frame_buf.push_back(static_cast<uint8_t>(top->ouch_data));
      if (top->ouch_last && frame_open) {
        ++frames;
        if (orders_jsonl) {
          orders_jsonl->lit("{\"n\": ");
          orders_jsonl->num(frame_n);
          orders_jsonl->lit(", \"raw\": \"");
          for (uint8_t b : frame_buf) orders_jsonl->hexbyte(b);
          orders_jsonl->lit("\", \"lat\": ");
          orders_jsonl->num(frame_lat);
          orders_jsonl->lit("}");
          orders_jsonl->endline();
        }
        if (keep_lat) order_lats.push_back(static_cast<uint32_t>(frame_lat));
        frame_open = false;
      }
    }

    if (top->msg_boundary) {
      ++msgs_seen;
      last_boundary_cycle = cycle;
    }
    if (fuzz) {
      const bool progressed =
          top->msg_boundary || top->upd_valid ||
          top->gap_count != prev_gap || top->malformed_count != prev_malformed ||
          top->unknown_count != prev_unknown || top->drop_count != prev_drop ||
          top->table_full_count != prev_table_full ||
          top->reduce_miss_count != prev_reduce_miss ||
          top->evict_count != prev_evict ||
          (top->end_of_session && !prev_eos);
      prev_gap = top->gap_count;
      prev_malformed = top->malformed_count;
      prev_unknown = top->unknown_count;
      prev_drop = top->drop_count;
      prev_table_full = top->table_full_count;
      prev_reduce_miss = top->reduce_miss_count;
      prev_evict = top->evict_count;
      prev_eos = top->end_of_session;
      if (progressed) last_progress_cycle = cycle;
    }
  };

  // ---------------------------------- wait out the post-reset clear sweep ---
  // in_ready is read with clk low, i.e. the value the DUT's own flops will see
  // at the coming edge.
  while (!top->in_ready) {
    top->clk = 1; top->eval(); ++cycle;
    top->clk = 0; top->eval();
  }
  std::fprintf(stderr, "replay: in_ready after %" PRIu64 " cycles "
                       "(post-reset table-clear sweep)\n", cycle);
  last_progress_cycle = cycle;   // watchdog armed only once bytes can flow

  // ------------------------------------------------------------- stream feed
  uint8_t byte = 0;
  bool have = feed.peek(&byte);
  while (have) {
    const bool ready = top->in_ready;   // pre-edge
    top->in_valid = 1;
    top->in_data = byte;

    top->clk = 1; top->eval(); ++cycle;
    if (ready) feed.advance();
    sample();
    top->clk = 0; top->eval();

    if (fuzz && (cycle - last_progress_cycle > watchdog_limit)) {
      hang_detected = true;
      std::fprintf(stderr, "replay: FUZZ WATCHDOG TRIPPED at cycle %" PRIu64
                            ": no observable progress for %" PRIu64
                            " cycles (bytes remain, %" PRIu64 " consumed of "
                            "input)\n", cycle, cycle - last_progress_cycle,
                   feed.consumed());
      break;
    }

    if (progress_every && msgs_seen >= next_progress) {
      const auto now = std::chrono::steady_clock::now();
      const double secs = std::chrono::duration<double>(now - t_start).count();
      std::fprintf(stderr, "replay: %" PRIu64 " msgs, %" PRIu64 " updates, "
                           "%" PRIu64 " cycles, %.1fs (%.0f msgs/s)\n",
                   msgs_seen, updates, cycle, secs,
                   secs > 0 ? static_cast<double>(msgs_seen) / secs : 0.0);
      next_progress += progress_every;
    }

    have = feed.peek(&byte);
  }

  // ------------------------------------------------------------------- drain
  top->in_valid = 0;
  top->in_data = 0;
  for (int i = 0; i < DRAIN_CYCLES; ++i) {
    top->clk = 1; top->eval(); ++cycle;
    sample();
    top->clk = 0; top->eval();
  }

  // A frame still open after DRAIN_CYCLES means the stream stopped mid-frame:
  // the partial frame is deliberately NOT written (a half frame would fail the
  // comparator's shape check as noise rather than as this specific fault), but
  // it is counted and reported.
  if (frame_open) { truncated_frames = 1; frame_open = false; }

  jsonl.flush();
  if (orders_jsonl) orders_jsonl->flush();

  const auto t_end = std::chrono::steady_clock::now();
  const double secs = std::chrono::duration<double>(t_end - t_start).count();

  // ------------------------------------------------------------------ report
  Percentiles p = percentiles(lats);

  std::printf("=== replay summary ===\n");
  std::printf("input            : %s\n", in_path);
  std::printf("output           : %s\n", out_path);
  std::printf("bytes fed        : %" PRIu64 "\n", feed.consumed());
  std::printf("messages         : %" PRIu64 "\n", msgs_seen);
  std::printf("updates          : %" PRIu64 "\n", updates);
  std::printf("cycles           : %" PRIu64 "\n", cycle);
  std::printf("orphan updates   : %" PRIu64 "\n", orphan_updates);
  std::printf("orders           : %" PRIu64 "\n", frames);
  std::printf("ouch bytes       : %" PRIu64 "\n", ouch_bytes);
  std::printf("orphan orders    : %" PRIu64 "\n", orphan_orders);
  std::printf("truncated frames : %" PRIu64 "\n", truncated_frames);
  std::printf("--- counters ---\n");
  std::printf("gap_count        : %u\n", top->gap_count);
  std::printf("malformed_count  : %u\n", top->malformed_count);
  std::printf("unknown_count    : %u\n", top->unknown_count);
  std::printf("drop_count       : %u\n", top->drop_count);
  std::printf("table_full_count : %u\n", top->table_full_count);
  std::printf("reduce_miss_count: %u\n", top->reduce_miss_count);
  std::printf("evict_count      : %u\n", top->evict_count);
  std::printf("end_of_session   : %u\n", top->end_of_session);
  // Machine-readable for scripts/run_replay.sh, which asserts each of these
  // against the golden model's own summary line.
  std::printf("--- trade counters ---\n");
  std::printf("intent_count        : %u\n", top->intent_count);
  std::printf("accept_count        : %u\n", top->accept_count);
  std::printf("sanity_reject_count : %u\n", top->sanity_reject_count);
  std::printf("collar_reject_count : %u\n", top->collar_reject_count);
  std::printf("rate_reject_count   : %u\n", top->rate_reject_count);
  std::printf("pos_reject_count    : %u\n", top->pos_reject_count);
  std::printf("order_count         : %u\n", top->order_count);
  std::printf("fifo_drop_count     : %u\n", top->fifo_drop_count);
  std::printf("--- latency (message boundary -> update, cycles) ---\n");
  if (keep_lat && !lats.empty()) {
    std::printf("min=%u median=%u p99=%u max=%u\n", p.min, p.median, p.p99, p.max);
  } else {
    std::printf("(not collected)\n");
  }
  Percentiles op = percentiles(order_lats);
  std::printf("--- tick-to-trade latency (message boundary -> frame_start, cycles) ---\n");
  if (keep_lat && !order_lats.empty()) {
    std::printf("min=%u median=%u p99=%u max=%u\n",
                op.min, op.median, op.p99, op.max);
  } else {
    std::printf("(not collected)\n");
  }
  std::printf("--- performance ---\n");
  std::printf("wall time        : %.2f s\n", secs);
  if (secs > 0) {
    std::printf("msgs/sec         : %.0f\n", static_cast<double>(msgs_seen) / secs);
    std::printf("cycles/sec       : %.0f\n", static_cast<double>(cycle) / secs);
  }

  if (fuzz) {
    const uint32_t err_sum = top->gap_count + top->malformed_count +
        top->unknown_count + top->drop_count + top->table_full_count +
        top->reduce_miss_count + top->evict_count;
    const bool errors_nonzero = err_sum > 0;
    const bool tail_updates_ok = updates_after_tail > 0;
    const bool orphan_ok = orphan_updates == 0 && orphan_orders == 0;
    const bool pass = !hang_detected && errors_nonzero && tail_updates_ok && orphan_ok;

    std::printf("--- fuzz ---\n");
    std::printf("tail_start_byte    : %" PRIu64 "\n", tail_start);
    std::printf("hang_detected      : %s\n", hang_detected ? "YES" : "no");
    std::printf("updates_before_tail: %" PRIu64 "\n", updates_before_tail);
    std::printf("updates_after_tail : %" PRIu64 "\n", updates_after_tail);
    std::printf("error_counters_sum : %u\n", err_sum);
    std::printf("orphan_updates     : %" PRIu64 "\n", orphan_updates);
    std::printf("orphan_orders      : %" PRIu64 "\n", orphan_orders);
    std::printf("fuzz result        : %s\n", pass ? "PASS" : "FAIL");

    top->final();
    delete top;
    return pass ? 0 : 1;
  }

  const uint32_t dut_order_count = top->order_count;
  const uint32_t dut_fifo_drops  = top->fifo_drop_count;
  top->final();
  delete top;

  int rc = 0;
  if (orphan_updates) {
    std::fprintf(stderr, "replay: %" PRIu64 " update(s) arrived before any message "
                         "boundary -- ordinal alignment is broken\n", orphan_updates);
    rc = 1;
  }
  if (orphan_orders) {
    std::fprintf(stderr, "replay: %" PRIu64 " order frame(s) started before any "
                         "message boundary -- ordinal alignment is broken\n",
                 orphan_orders);
    rc = 1;
  }
  if (truncated_frames) {
    std::fprintf(stderr, "replay: the stream ended mid-frame; the trailing partial "
                         "OUCH frame was not written\n");
    rc = 1;
  }
  // The DUT's own order_count and the number of frames the harness reassembled
  // are independent measurements of the same thing; a split between them means
  // bytes were lost on the way out, which the trace comparison alone would
  // report only as a length mismatch.
  if (frames != dut_order_count) {
    std::fprintf(stderr, "replay: reassembled %" PRIu64 " frame(s) but the DUT's "
                         "order_count is %u\n", frames, dut_order_count);
    rc = 1;
  }
  if (dut_fifo_drops) {
    std::fprintf(stderr, "replay: %u accepted order(s) were dropped by the "
                         "encoder FIFO -- the order stream is incomplete\n",
                 dut_fifo_drops);
    rc = 1;
  }
  return rc;
}
