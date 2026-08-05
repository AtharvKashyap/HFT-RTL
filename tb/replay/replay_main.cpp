// replay_main.cpp -- Verilator C++ replay harness for itch_book_top.
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
// msgs_seen-1, THEN apply this cycle's boundary pulse. Both orderings agree in
// practice because an update cannot arrive as late as the next boundary --
// framer->decoder is 1 cycle, the router's worst case is 16 (a REPLACE probing
// MAX_PROBES twice), and price_book adds 1, for 18 cycles, while consecutive
// message boundaries are at least 2 + 19 = 21 cycles apart (2 length bytes plus
// the shortest table-touching message, a 19-byte Delete). Doing it in this
// order makes the attribution correct even if that margin were ever eroded.
//
// `lat` is (cycle of upd_valid) - (cycle of the most recent msg_boundary),
// i.e. end-of-message to book-snapshot latency in clock cycles.
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
      "usage: replay --in <stream.mold> --out <rtl.jsonl> [--progress N] "
      "[--no-lat-hist]\n");
}

}  // namespace

int main(int argc, char** argv) {
  const char* in_path = nullptr;
  const char* out_path = nullptr;
  uint64_t progress_every = 1000000;
  bool keep_lat = true;

  for (int i = 1; i < argc; ++i) {
    if (!std::strcmp(argv[i], "--in") && i + 1 < argc)        in_path = argv[++i];
    else if (!std::strcmp(argv[i], "--out") && i + 1 < argc)  out_path = argv[++i];
    else if (!std::strcmp(argv[i], "--progress") && i + 1 < argc)
      progress_every = std::strtoull(argv[++i], nullptr, 10);
    else if (!std::strcmp(argv[i], "--no-lat-hist"))          keep_lat = false;
    else { usage(); return 2; }
  }
  if (!in_path || !out_path) { usage(); return 2; }

  Verilated::traceEverOn(false);
  auto* top = new Vreplay_top;
  ByteFeed feed(in_path);
  JsonlWriter jsonl(out_path);

  uint64_t cycle = 0;
  uint64_t msgs_seen = 0;
  uint64_t updates = 0;
  uint64_t last_boundary_cycle = 0;
  uint64_t orphan_updates = 0;   // upd_valid before any msg_boundary: must stay 0
  std::vector<uint32_t> lats;
  if (keep_lat) lats.reserve(1 << 20);

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
      }
    }
    if (top->msg_boundary) {
      ++msgs_seen;
      last_boundary_cycle = cycle;
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

  jsonl.flush();

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
  std::printf("--- counters ---\n");
  std::printf("gap_count        : %u\n", top->gap_count);
  std::printf("malformed_count  : %u\n", top->malformed_count);
  std::printf("unknown_count    : %u\n", top->unknown_count);
  std::printf("drop_count       : %u\n", top->drop_count);
  std::printf("table_full_count : %u\n", top->table_full_count);
  std::printf("reduce_miss_count: %u\n", top->reduce_miss_count);
  std::printf("evict_count      : %u\n", top->evict_count);
  std::printf("end_of_session   : %u\n", top->end_of_session);
  std::printf("--- latency (message boundary -> update, cycles) ---\n");
  if (keep_lat && !lats.empty()) {
    std::printf("min=%u median=%u p99=%u max=%u\n", p.min, p.median, p.p99, p.max);
  } else {
    std::printf("(not collected)\n");
  }
  std::printf("--- performance ---\n");
  std::printf("wall time        : %.2f s\n", secs);
  if (secs > 0) {
    std::printf("msgs/sec         : %.0f\n", static_cast<double>(msgs_seen) / secs);
    std::printf("cycles/sec       : %.0f\n", static_cast<double>(cycle) / secs);
  }

  top->final();
  delete top;

  if (orphan_updates) {
    std::fprintf(stderr, "replay: %" PRIu64 " update(s) arrived before any message "
                         "boundary -- ordinal alignment is broken\n", orphan_updates);
    return 1;
  }
  return 0;
}
