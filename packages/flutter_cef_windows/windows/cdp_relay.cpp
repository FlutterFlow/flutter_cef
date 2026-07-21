#include "cdp_relay.h"

#include <bcrypt.h>
#include <ws2tcpip.h>

#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <thread>

// winsock + bcrypt (SHA-1 accept, CSPRNG token). ws2_32 is also linked via
// CMakeLists; the pragma keeps this TU self-documenting.
#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "bcrypt.lib")

namespace flutter_cef {

namespace {

// Diagnostics are gated behind FLUTTER_CEF_DEBUG (mirrors CdpRelay.swift
// dlog): a release build stays quiet and never logs the port or per-frame,
// peer-controlled protocol errors. Win32 env read (the plugin bans the CRT
// getenv, which is C4996/treated-as-error here).
bool DebugEnabled() {
  wchar_t buf[8] = {};
  return GetEnvironmentVariableW(L"FLUTTER_CEF_DEBUG", buf, 8) > 0;
}
void DLog(const char* fmt, ...) {
  static const bool enabled = DebugEnabled();
  if (!enabled) return;
  char buf[512];
  va_list ap;
  va_start(ap, fmt);
  _vsnprintf_s(buf, _TRUNCATE, fmt, ap);
  va_end(ap);
  fprintf(stderr, "[cef][relay] %s\n", buf);
  fflush(stderr);
}

// Hash `data` with SHA-1 (BCrypt); writes 20 bytes into `out`. False on any
// CNG failure.
bool Sha1(const uint8_t* data, size_t len, uint8_t out[20]) {
  BCRYPT_ALG_HANDLE alg = nullptr;
  if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA1_ALGORITHM, nullptr, 0) != 0)
    return false;
  BCRYPT_HASH_HANDLE hash = nullptr;
  bool ok = false;
  if (BCryptCreateHash(alg, &hash, nullptr, 0, nullptr, 0, 0) == 0) {
    if (BCryptHashData(hash, const_cast<PUCHAR>(data),
                       static_cast<ULONG>(len), 0) == 0 &&
        BCryptFinishHash(hash, out, 20, 0) == 0) {
      ok = true;
    }
    BCryptDestroyHash(hash);
  }
  BCryptCloseAlgorithmProvider(alg, 0);
  return ok;
}

// Standard base64 of `n` bytes.
std::string Base64(const uint8_t* p, size_t n) {
  static const char* tbl =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string out;
  out.reserve(((n + 2) / 3) * 4);
  size_t i = 0;
  for (; i + 3 <= n; i += 3) {
    uint32_t v = (uint32_t(p[i]) << 16) | (uint32_t(p[i + 1]) << 8) | p[i + 2];
    out.push_back(tbl[(v >> 18) & 0x3f]);
    out.push_back(tbl[(v >> 12) & 0x3f]);
    out.push_back(tbl[(v >> 6) & 0x3f]);
    out.push_back(tbl[v & 0x3f]);
  }
  if (n - i == 1) {
    uint32_t v = uint32_t(p[i]) << 16;
    out.push_back(tbl[(v >> 18) & 0x3f]);
    out.push_back(tbl[(v >> 12) & 0x3f]);
    out.push_back('=');
    out.push_back('=');
  } else if (n - i == 2) {
    uint32_t v = (uint32_t(p[i]) << 16) | (uint32_t(p[i + 1]) << 8);
    out.push_back(tbl[(v >> 18) & 0x3f]);
    out.push_back(tbl[(v >> 12) & 0x3f]);
    out.push_back(tbl[(v >> 6) & 0x3f]);
    out.push_back('=');
  }
  return out;
}

// CSPRNG token: 24 random bytes hex-encoded (48 chars), matching
// CdpRelay.swift randomToken(). Fails closed to an unguessable-but-unusable
// value if CNG somehow fails (Start() success is the gate; a bad token just
// means no client can connect).
std::string RandomToken() {
  uint8_t bytes[24] = {};
  if (BCryptGenRandom(nullptr, bytes, sizeof(bytes),
                      BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) {
    // Never expected; keep the buffer zeroed (still 48 hex chars, unusable).
  }
  static const char* hex = "0123456789abcdef";
  std::string s;
  s.reserve(48);
  for (uint8_t b : bytes) {
    s.push_back(hex[b >> 4]);
    s.push_back(hex[b & 0xf]);
  }
  return s;
}

bool ConstantTimeEquals(const std::string& a, const std::string& b) {
  if (a.size() != b.size()) return false;
  uint8_t diff = 0;
  for (size_t i = 0; i < a.size(); ++i)
    diff |= static_cast<uint8_t>(a[i]) ^ static_cast<uint8_t>(b[i]);
  return diff == 0;
}

std::string ToLower(std::string s) {
  for (char& c : s)
    if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
  return s;
}

std::string Trim(const std::string& s) {
  size_t a = s.find_first_not_of(" \t");
  if (a == std::string::npos) return std::string();
  size_t b = s.find_last_not_of(" \t");
  return s.substr(a, b - a + 1);
}

}  // namespace

CdpRelay::CdpRelay(SendToPipe send_to_pipe, std::string scope_target_id)
    : send_to_pipe_(std::move(send_to_pipe)),
      scope_target_id_(std::move(scope_target_id)),
      token_(RandomToken()) {}

CdpRelay::~CdpRelay() {
  Stop();
  if (wsa_started_) WSACleanup();
}

// MARK: Lifecycle

bool CdpRelay::Start() {
  WSADATA wsa = {};
  if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
    DLog("WSAStartup failed");
    return false;
  }
  wsa_started_ = true;

  SOCKET fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (fd == INVALID_SOCKET) {
    DLog("socket() failed");
    return false;
  }
  BOOL on = TRUE;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast<char*>(&on),
             sizeof(on));

  sockaddr_in addr = {};
  addr.sin_family = AF_INET;
  addr.sin_port = 0;  // OS picks an ephemeral port
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);  // 127.0.0.1 — loopback only
  if (bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0 ||
      listen(fd, 4) != 0) {
    DLog("bind/listen failed (wsa=%d)", WSAGetLastError());
    closesocket(fd);
    return false;
  }

  sockaddr_in bound = {};
  int len = sizeof(bound);
  if (getsockname(fd, reinterpret_cast<sockaddr*>(&bound), &len) != 0) {
    DLog("getsockname failed");
    closesocket(fd);
    return false;
  }
  port_ = ntohs(bound.sin_port);

  listen_sock_ = fd;
  running_.store(true);
  std::thread([self = shared_from_this()]() { self->AcceptLoop(); }).detach();
  DLog("listening on 127.0.0.1:%u", port_);
  return true;
}

void CdpRelay::Stop() {
  running_.store(false);
  SOCKET lfd = listen_sock_;
  listen_sock_ = INVALID_SOCKET;
  if (lfd != INVALID_SOCKET) {
    shutdown(lfd, SD_BOTH);
    closesocket(lfd);  // wakes accept()
  }
  std::lock_guard<std::mutex> lock(client_lock_);
  if (client_sock_ != INVALID_SOCKET) {
    shutdown(client_sock_, SD_BOTH);  // wakes the handler's blocked recv()
    closesocket(client_sock_);
    client_sock_ = INVALID_SOCKET;
  }
}

// MARK: Accept

void CdpRelay::AcceptLoop() {
  while (running_.load()) {
    SOCKET fd = accept(listen_sock_, nullptr, nullptr);
    if (fd == INVALID_SOCKET) {
      if (running_.load()) continue;
      break;
    }
    // Detached handler thread; the shared_from_this() keeps the relay alive for
    // the duration of the connection even across a concurrent Stop().
    std::thread([self = shared_from_this(), fd]() {
      self->HandleConnection(fd);
    }).detach();
  }
}

// MARK: HTTP / handshake

void CdpRelay::HandleConnection(SOCKET fd) {
  // Read timeout for the HANDSHAKE only (slowloris backstop). Cleared after a
  // successful upgrade — the ws frame loop idles between agent commands.
  DWORD rcv = 10000;
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<char*>(&rcv),
             sizeof(rcv));
  DWORD snd = 2000;  // a stalled client must not wedge DeliverToClient/stop
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<char*>(&snd),
             sizeof(snd));

  std::string method, target;
  std::map<std::string, std::string> headers;
  if (!ReadRequestHead(fd, &method, &target, &headers)) {
    closesocket(fd);
    return;
  }
  std::string path = target.substr(0, target.find('?'));
  // Normalize a trailing slash: Playwright fetches `GET /json/version/`.
  if (path.size() > 1 && path.back() == '/') path.pop_back();

  // CDP discovery (token-free): the client GETs this to find the ws-url.
  if (method == "GET" &&
      (path == "/json/version" || path == "/json" || path == "/json/list")) {
    ServeDiscovery(fd, path);
    closesocket(fd);
    return;
  }

  // WebSocket upgrade — the only authenticated path.
  auto up = headers.find("upgrade");
  const bool is_upgrade =
      up != headers.end() && ToLower(up->second).find("websocket") !=
                                 std::string::npos;
  auto key_it = headers.find("sec-websocket-key");
  if (!is_upgrade || key_it == headers.end() || key_it->second.empty()) {
    WriteRaw(fd,
             "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: "
             "close\r\n\r\n");
    closesocket(fd);
    return;
  }
  if (!TokenAcceptable(target, headers)) {
    DLog("ws upgrade rejected: token absent or invalid");
    WriteRaw(fd,
             "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: "
             "close\r\n\r\n");
    closesocket(fd);
    return;
  }

  // One active client per relay: reject a second concurrent upgrade (503).
  {
    std::unique_lock<std::mutex> lock(client_lock_);
    if (client_sock_ != INVALID_SOCKET) {
      lock.unlock();
      WriteRaw(fd,
               "HTTP/1.1 503 Service Unavailable\r\nContent-Length: "
               "0\r\nConnection: close\r\n\r\n");
      closesocket(fd);
      return;
    }
    client_sock_ = fd;
  }

  // Sec-WebSocket-Accept = base64(SHA1(key + GUID)).
  std::string accept_src = key_it->second + kWsGuid;
  uint8_t digest[20] = {};
  std::string accept_key;
  if (Sha1(reinterpret_cast<const uint8_t*>(accept_src.data()),
           accept_src.size(), digest)) {
    accept_key = Base64(digest, sizeof(digest));
  }
  WriteRaw(fd,
           "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
           "Connection: Upgrade\r\nSec-WebSocket-Accept: " +
               accept_key + "\r\n\r\n");
  DLog("client attached");

  // Clear the handshake read timeout: the ws connection idles between commands.
  DWORD zero = 0;
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<char*>(&zero),
             sizeof(zero));
  FrameLoop(fd);

  // Whoever clears client_sock_ from `fd` owns the close: if Stop() already took
  // the slot (client_sock_ != fd) it closed the fd, so closing here too would be
  // a double-close on a possibly-reused socket.
  bool owned = false;
  {
    std::lock_guard<std::mutex> lock(client_lock_);
    if (client_sock_ == fd) {
      client_sock_ = INVALID_SOCKET;
      owned = true;
    }
  }
  if (owned) closesocket(fd);
  DLog("client detached");
}

void CdpRelay::ServeDiscovery(SOCKET fd, const std::string& path) {
  // Token-free ws-url. The token is NOT advertised here — the broker presents
  // it as an Authorization: Bearer header on the upgrade, so a local
  // port-scanner that reads this url still can't connect.
  char ws[64];
  _snprintf_s(ws, _TRUNCATE, "ws://127.0.0.1:%u/devtools/browser", port_);
  std::string body;
  if (path == "/json/list") {
    body = std::string("[{\"type\":\"page\",\"webSocketDebuggerUrl\":\"") + ws +
           "\"}]";
  } else {
    body = std::string(
               "{\"Browser\":\"flutter_cef\",\"Protocol-Version\":\"1.3\","
               "\"webSocketDebuggerUrl\":\"") +
           ws + "\"}";
  }
  char head[160];
  _snprintf_s(head, _TRUNCATE,
              "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
              "Content-Length: %zu\r\nConnection: close\r\n\r\n",
              body.size());
  WriteRaw(fd, std::string(head) + body);
}

// True iff the connection presents the correct token (now REQUIRED — an absent
// OR wrong token is rejected). Preferred: Authorization: Bearer <token>;
// fallback: ?token=<token> in the request target. Constant-time compared.
bool CdpRelay::TokenAcceptable(
    const std::string& target,
    const std::map<std::string, std::string>& headers) {
  std::string supplied;
  bool have = false;
  auto auth = headers.find("authorization");
  if (auth != headers.end()) {
    const std::string& v = auth->second;
    size_t sp = v.find(' ');
    if (sp != std::string::npos && ToLower(v.substr(0, sp)) == "bearer") {
      supplied = Trim(v.substr(sp + 1));
      have = true;
    }
  }
  if (!have) {
    size_t q = target.find('?');
    if (q != std::string::npos) {
      std::string query = target.substr(q + 1);
      size_t start = 0;
      while (start <= query.size()) {
        size_t amp = query.find('&', start);
        std::string pair = query.substr(
            start, amp == std::string::npos ? std::string::npos : amp - start);
        size_t eq = pair.find('=');
        std::string k = pair.substr(0, eq);
        if (k == "token") {
          supplied = eq == std::string::npos ? std::string()
                                             : pair.substr(eq + 1);
          have = true;
          break;
        }
        if (amp == std::string::npos) break;
        start = amp + 1;
      }
    }
  }
  if (!have || supplied.empty()) return false;  // absent -> REJECT
  return ConstantTimeEquals(supplied, token_);
}

// Read the HTTP request head (request line + headers) up to CRLFCRLF. Bounded
// to 16 KiB; a truncated head is rejected (never parsed as complete).
bool CdpRelay::ReadRequestHead(
    SOCKET fd, std::string* method, std::string* target,
    std::map<std::string, std::string>* headers) {
  std::string acc;
  char c = 0;
  while (acc.size() < (16u << 10)) {
    int n = recv(fd, &c, 1, 0);
    if (n <= 0) return false;
    acc.push_back(c);
    size_t s = acc.size();
    if (s >= 4 && acc[s - 4] == '\r' && acc[s - 3] == '\n' &&
        acc[s - 2] == '\r' && acc[s - 1] == '\n')
      break;
  }
  size_t s = acc.size();
  if (!(s >= 4 && acc[s - 4] == '\r' && acc[s - 3] == '\n' &&
        acc[s - 2] == '\r' && acc[s - 1] == '\n'))
    return false;

  // Split into CRLF lines.
  std::vector<std::string> lines;
  size_t start = 0;
  while (start < acc.size()) {
    size_t nl = acc.find("\r\n", start);
    if (nl == std::string::npos) break;
    lines.push_back(acc.substr(start, nl - start));
    start = nl + 2;
  }
  if (lines.empty()) return false;
  // Request line: METHOD SP TARGET SP VERSION.
  const std::string& req = lines[0];
  size_t sp1 = req.find(' ');
  if (sp1 == std::string::npos) return false;
  size_t sp2 = req.find(' ', sp1 + 1);
  *method = req.substr(0, sp1);
  *target = req.substr(sp1 + 1,
                       sp2 == std::string::npos ? std::string::npos
                                                : sp2 - sp1 - 1);
  for (size_t i = 1; i < lines.size(); ++i) {
    const std::string& line = lines[i];
    if (line.empty()) continue;
    size_t colon = line.find(':');
    if (colon == std::string::npos) continue;
    std::string k = ToLower(Trim(line.substr(0, colon)));
    std::string v = Trim(line.substr(colon + 1));
    (*headers)[k] = v;
  }
  return true;
}

// MARK: WebSocket framing (RFC 6455, server side)

void CdpRelay::FrameLoop(SOCKET fd) {
  std::vector<uint8_t> msg;       // accumulated payload of the current message
  bool assembling = false;        // a fragmented data message is in progress
  bool assembling_text = false;   // ...and it's text (binary payload dropped)
  while (running_.load()) {
    uint8_t h[2];
    if (!ReadN(fd, h, 2)) return;
    const bool fin = (h[0] & 0x80) != 0;
    const uint8_t opcode = h[0] & 0x0f;
    const bool masked = (h[1] & 0x80) != 0;
    uint64_t len = h[1] & 0x7f;
    if (len == 126) {
      uint8_t e[2];
      if (!ReadN(fd, e, 2)) return;
      len = (uint64_t(e[0]) << 8) | e[1];
    } else if (len == 127) {
      uint8_t e[8];
      if (!ReadN(fd, e, 8)) return;
      len = 0;
      for (int i = 0; i < 8; ++i) len = (len << 8) | e[i];
    }
    if (len > kMaxFrame) {
      DLog("frame too large");
      return;
    }
    // RFC 6455 §5.5: control frames are <=125 bytes and never fragmented.
    if (opcode == 0x8 || opcode == 0x9 || opcode == 0xA) {
      if (len > 125 || !fin) {
        DLog("bad control frame");
        return;
      }
    }
    // Client->server frames MUST be masked (RFC 6455 §5.1).
    if (!masked) return;
    uint8_t mask[4];
    if (!ReadN(fd, mask, 4)) return;
    std::vector<uint8_t> payload(static_cast<size_t>(len));
    if (len > 0 && !ReadN(fd, payload.data(), static_cast<int>(len))) return;
    for (size_t i = 0; i < payload.size(); ++i) payload[i] ^= mask[i % 4];

    switch (opcode) {
      case 0x0:
      case 0x1:
      case 0x2: {
        if (opcode == 0x0) {
          if (!assembling) {
            DLog("continuation with no message");
            return;
          }
        } else {
          if (assembling) {
            DLog("new data frame mid-message");
            return;
          }
          assembling_text = (opcode == 0x1);  // 0x2 binary: payload dropped
        }
        if (assembling_text) {
          if (msg.size() + payload.size() > kMaxFrame) {
            DLog("message too large");
            return;
          }
          msg.insert(msg.end(), payload.begin(), payload.end());
        }
        assembling = !fin;
        if (fin) {
          if (assembling_text) {
            // Single-tile passthrough: forward the CDP message verbatim. (The
            // CEF-2b filterClientToPipe + rewriteOutgoingId hooks would go here
            // for the N-tile follow-up — see the header comment.)
            send_to_pipe_(std::string(msg.begin(), msg.end()));
          }
          msg.clear();
          assembling_text = false;
        }
        break;
      }
      case 0x8: {  // close
        std::lock_guard<std::mutex> lock(client_lock_);
        WriteFrameLocked(fd, 0x8, {});
        return;
      }
      case 0x9: {  // ping -> pong
        std::lock_guard<std::mutex> lock(client_lock_);
        WriteFrameLocked(fd, 0xA, payload);
        break;
      }
      case 0xA:  // pong — ignore
        break;
      default:
        DLog("unknown opcode %u", opcode);
        return;
    }
  }
}

void CdpRelay::DeliverToClient(const std::string& json) {
  // Single-tile passthrough: deliver verbatim. (The CEF-2b demux + filter
  // seam — demuxPipeToClient/filterPipeToClient — would gate this for N-tile.)
  std::vector<uint8_t> payload(json.begin(), json.end());
  std::lock_guard<std::mutex> lock(client_lock_);
  if (client_sock_ == INVALID_SOCKET) return;
  WriteFrameLocked(client_sock_, 0x1, payload);
}

// Write a server frame (unmasked). Caller holds client_lock_.
void CdpRelay::WriteFrameLocked(SOCKET fd, uint8_t opcode,
                                const std::vector<uint8_t>& payload) {
  std::vector<uint8_t> frame;
  frame.push_back(0x80 | opcode);  // FIN + opcode
  const size_t n = payload.size();
  if (n < 126) {
    frame.push_back(static_cast<uint8_t>(n));
  } else if (n <= 0xFFFF) {
    frame.push_back(126);
    frame.push_back(static_cast<uint8_t>((n >> 8) & 0xff));
    frame.push_back(static_cast<uint8_t>(n & 0xff));
  } else {
    frame.push_back(127);
    for (int s = 56; s >= 0; s -= 8)
      frame.push_back(static_cast<uint8_t>((uint64_t(n) >> s) & 0xff));
  }
  frame.insert(frame.end(), payload.begin(), payload.end());
  if (!WriteAll(fd, frame.data(), static_cast<int>(frame.size()))) {
    // Write failed (stuck/dead peer, possibly mid-frame -> stream desynced).
    // Don't keep writing onto a broken stream: shut it down so the handler's
    // blocked recv() returns and it exits, closing the fd via the ownership
    // protocol. Only shutdown here (not close/clear) — leave the single
    // close-owner intact.
    shutdown(fd, SD_BOTH);
  }
}

// MARK: Blocking IO helpers

bool CdpRelay::ReadN(SOCKET fd, void* buf, int count) {
  uint8_t* p = static_cast<uint8_t*>(buf);
  int got = 0;
  while (got < count) {
    int n = recv(fd, reinterpret_cast<char*>(p + got), count - got, 0);
    if (n <= 0) return false;
    got += n;
  }
  return true;
}

bool CdpRelay::WriteAll(SOCKET fd, const void* buf, int len) {
  const uint8_t* p = static_cast<const uint8_t*>(buf);
  int off = 0;
  while (off < len) {
    int n = send(fd, reinterpret_cast<const char*>(p + off), len - off, 0);
    if (n <= 0) return false;  // WSAEWOULDBLOCK (SO_SNDTIMEO) or a dead socket
    off += n;
  }
  return true;
}

void CdpRelay::WriteRaw(SOCKET fd, const std::string& s) {
  WriteAll(fd, s.data(), static_cast<int>(s.size()));
}

}  // namespace flutter_cef
