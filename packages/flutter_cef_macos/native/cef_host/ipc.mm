#include "ipc.h"

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include <unistd.h>

namespace cef_host {

std::atomic<int> g_ipc_fd{-1};
std::mutex g_ipc_write_mutex;

namespace {
bool WriteAll(int fd, const void* buf, size_t len) {
  const uint8_t* p = static_cast<const uint8_t*>(buf);
  size_t off = 0;
  while (off < len) {
    ssize_t n = write(fd, p + off, len - off);
    if (n <= 0) {
      if (n < 0 && (errno == EINTR)) continue;
      return false;
    }
    off += static_cast<size_t>(n);
  }
  return true;
}
}  // namespace

bool ReadAll(int fd, void* buf, size_t len) {
  uint8_t* p = static_cast<uint8_t*>(buf);
  size_t off = 0;
  while (off < len) {
    ssize_t n = read(fd, p + off, len - off);
    if (n == 0) return false;  // peer closed
    if (n < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    off += static_cast<size_t>(n);
  }
  return true;
}

void SendFrame(uint32_t browser_id, uint8_t opcode, const void* payload,
               size_t payload_len) {
  if (g_ipc_fd < 0) return;  // racy early-out; the authoritative check is under the lock
  // Most payloads carry page-chosen text. One the plugin would refuse must not
  // cost every browser on the host its connection, so it is dropped instead.
  if (payload_len > kMaxFrameBody - 5) {
    fprintf(stderr,
            "[cef_host] dropped a %zu-byte frame (op 0x%02x, browser %u): over "
            "the IPC frame limit\n",
            payload_len, opcode, browser_id);
    return;
  }
  std::lock_guard<std::mutex> lock(g_ipc_write_mutex);
  // C3: SNAPSHOT the fd under the write lock and write to the snapshot, never re-loading
  // g_ipc_fd at write time. Teardown sets g_ipc_fd=-1 (exchange) and close()s the old fd
  // under this same lock, so once we hold it the fd is either still valid (write) or
  // already -1 (skip) — a paint thread can no longer pass the early-out and then write
  // into a closed/recycled fd.
  int fd = g_ipc_fd.load();
  if (fd < 0) return;
  uint32_t body_len = static_cast<uint32_t>(4 + 1 + payload_len);
  // Assemble the whole frame and write it in one WriteAll so a partial write
  // never leaves the peer with a length prefix it can't satisfy (stream desync).
  std::vector<uint8_t> frame(4 + body_len);
  frame[0] = static_cast<uint8_t>((body_len >> 24) & 0xff);
  frame[1] = static_cast<uint8_t>((body_len >> 16) & 0xff);
  frame[2] = static_cast<uint8_t>((body_len >> 8) & 0xff);
  frame[3] = static_cast<uint8_t>(body_len & 0xff);
  frame[4] = static_cast<uint8_t>((browser_id >> 24) & 0xff);
  frame[5] = static_cast<uint8_t>((browser_id >> 16) & 0xff);
  frame[6] = static_cast<uint8_t>((browser_id >> 8) & 0xff);
  frame[7] = static_cast<uint8_t>(browser_id & 0xff);
  frame[8] = opcode;
  if (payload_len) memcpy(frame.data() + 9, payload, payload_len);
  WriteAll(fd, frame.data(), frame.size());
}

void SendLog(uint32_t browser_id, const std::string& msg) {
  SendFrame(browser_id, kOpLog, msg.data(), msg.size());
}

void SendUtf8(uint32_t browser_id, uint8_t op, const std::string& s) {
  SendFrame(browser_id, op, s.data(), s.size());
}

std::string TruncateUtf8(const std::string& s, size_t max) {
  if (s.size() <= max) return s;
  size_t end = max;
  while (end > 0 && (static_cast<unsigned char>(s[end]) & 0xC0) == 0x80) --end;
  return s.substr(0, end) + "…[truncated]";
}

std::string RandomNonce() {
  uint8_t bytes[16];
  arc4random_buf(bytes, sizeof(bytes));
  static const char kHex[] = "0123456789abcdef";
  std::string out;
  for (uint8_t b : bytes) {
    out += kHex[b >> 4];
    out += kHex[b & 0xf];
  }
  return out;
}

void SendLoadState(uint32_t browser_id, bool loading, bool back, bool forward) {
  uint8_t p[3];
  p[0] = loading ? 1 : 0;
  p[1] = back ? 1 : 0;
  p[2] = forward ? 1 : 0;
  SendFrame(browser_id, kOpLoadState, p, 3);
}

void SendCodePlusUtf8(uint32_t browser_id, uint8_t op, uint32_t code,
                      const std::string& body) {
  std::vector<uint8_t> p(4 + body.size());
  p[0] = (code >> 24) & 0xff;
  p[1] = (code >> 16) & 0xff;
  p[2] = (code >> 8) & 0xff;
  p[3] = code & 0xff;
  memcpy(p.data() + 4, body.data(), body.size());
  SendFrame(browser_id, op, p.data(), static_cast<uint32_t>(p.size()));
}

uint32_t ReadU32BE(const uint8_t* p) {
  return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) |
         uint32_t(p[3]);
}

void WriteU32BE(uint8_t* p, uint32_t v) {
  p[0] = static_cast<uint8_t>((v >> 24) & 0xff);
  p[1] = static_cast<uint8_t>((v >> 16) & 0xff);
  p[2] = static_cast<uint8_t>((v >> 8) & 0xff);
  p[3] = static_cast<uint8_t>(v & 0xff);
}

namespace {
uint64_t ReadU64BE(const uint8_t* p) {
  uint64_t v = 0;
  for (int i = 0; i < 8; ++i) v = (v << 8) | p[i];
  return v;
}
}  // namespace

double ReadF64BE(const uint8_t* p) {
  uint64_t bits = ReadU64BE(p);
  double d;
  memcpy(&d, &bits, sizeof(d));
  return d;
}

std::string JsonEscape(const std::string& s) {
  std::string out;
  out.reserve(s.size() + 2);
  for (unsigned char ch : s) {
    switch (ch) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (ch < 0x20) {
          char buf[8];
          snprintf(buf, sizeof(buf), "\\u%04x", ch);
          out += buf;
        } else {
          out += static_cast<char>(ch);
        }
    }
  }
  return out;
}

}  // namespace cef_host
