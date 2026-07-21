// CdpRelay (Windows) — the token-gated loopback CDP HTTP+WebSocket relay.
//
// A direct winsock port of the macOS reference
// packages/flutter_cef_macos/macos/Classes/CdpRelay.swift (the canonical
// relay): it re-exposes cef_host's CDP-over-pipe (Chromium
// --remote-debugging-pipe + --remote-debugging-io-pipes, NUL-framed JSON on
// two inherited anonymous pipes — the S3 recipe) to a standard CDP client
// (Playwright via connectOverCDP / agent-browser) as a loopback HTTP+WebSocket
// endpoint. The Swift protocol logic ports directly: the POSIX socket calls
// (socket/bind/listen/accept/recv/send, fd) become winsock (WSAStartup,
// SOCKET, closesocket, the same BSD-ish API); the RFC-6455 handshake
// (SHA-1 Sec-WebSocket-Accept via BCrypt), frame codec, the mandatory-token
// gate, and the CDP-pipe bridge are otherwise identical.
//
// SECURITY MODEL (verbatim from CdpRelay.swift — the trust boundary):
//  - Mandatory bearer token: the ws upgrade is rejected 401 without a valid
//    `Authorization: Bearer <token>` header (a `?token=` query is an accepted
//    fallback). Discovery (/json/*) stays token-free, so a port-scanner learns
//    the ws-url but can't upgrade — it never sees the token.
//  - Loopback only (127.0.0.1) — never reachable off-box.
//  - Ephemeral, OS-assigned port; exists only during a grant
//    (enableAgentControl -> Start, disableAgentControl/dispose/host-death ->
//    Stop). No standing port.
//  - Single active client — a second concurrent ws upgrade is rejected 503.
//  - CSPRNG token (BCryptGenRandom), constant-time compared.
//
// SINGLE-TILE SCOPE (P9): this relay is the raw browser-level PASSTHROUGH
// (CEF-2a) — the CDP pipe carries exactly ONE page target (the one tile), so a
// passthrough is functionally correct and safe (there is no sibling tile to
// hide). The per-tile Target-domain FILTER + N-relay CDP-id MULTIPLEX (CEF-2b —
// the `scopeTargetId`/`relayId` machinery in CdpRelay.swift:560-884) is the
// documented follow-up for N-tile Target multiplexing and is NOT implemented
// here. The `scope_target_id` seam below is left in place for it (empty =
// passthrough today); see the class comment where the filter hooks would go.
//
// LIFETIME: the relay is always owned by a std::shared_ptr (the plugin's
// CdpTransport::relay). Its worker threads are DETACHED and each holds a
// shared_from_this(), so the object outlives any in-flight thread; Stop() only
// closes the sockets (unblocking those threads), which then release their refs
// and let the last one destroy the object — the C++ analogue of the Swift
// "shutdown() wakes the blocked handler; the handler owns the close" protocol.

#ifndef FLUTTER_PLUGIN_FLUTTER_CEF_CDP_RELAY_H_
#define FLUTTER_PLUGIN_FLUTTER_CEF_CDP_RELAY_H_

#include <winsock2.h>  // must precede windows.h
#include <windows.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace flutter_cef {

class CdpRelay : public std::enable_shared_from_this<CdpRelay> {
 public:
  // Forwards one CDP message (a single JSON line, no framing) to cef_host over
  // the inherited command pipe (the plugin adds the NUL terminator). Must be
  // safe to call from the relay's frame-loop thread.
  using SendToPipe = std::function<void(const std::string&)>;

  // `send_to_pipe` bridges client->pipe. `scope_target_id` is the CEF-2b
  // per-tile filter seam: empty (the P9 single-tile default) is the raw
  // browser-level passthrough; a non-empty targetId would engage the
  // Target-domain filter (NOT implemented in the slice — see the file comment).
  explicit CdpRelay(SendToPipe send_to_pipe,
                    std::string scope_target_id = std::string());
  ~CdpRelay();

  CdpRelay(const CdpRelay&) = delete;
  CdpRelay& operator=(const CdpRelay&) = delete;

  // Bind a loopback TCP listener on an OS-assigned ephemeral port and start
  // accepting. Returns false (cleaning up) on any failure. Must be called on a
  // shared_ptr-owned instance (launches threads via shared_from_this()).
  bool Start();

  // Stop the listener, drop any client, and refuse further connections.
  // Idempotent. Closes the sockets (waking blocked worker threads); the threads
  // self-terminate and the last shared_ptr release destroys the object.
  void Stop();

  // Deliver one CDP message from the pipe to the connected client (framed as a
  // WebSocket text frame). Called off the plugin's CDP reader thread. A no-op
  // when no client is attached.
  void DeliverToClient(const std::string& json);

  uint16_t port() const { return port_; }
  const std::string& token() const { return token_; }

 private:
  // RFC-6455 server-accept GUID (appended to Sec-WebSocket-Key before SHA-1).
  static constexpr const char* kWsGuid =
      "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
  // Frame/message size cap (mirrors the IPC reader's 64 MiB cap): a hostile or
  // buggy client must not make us allocate unbounded.
  static constexpr uint64_t kMaxFrame = 64ull << 20;

  void AcceptLoop();
  void HandleConnection(SOCKET fd);
  void ServeDiscovery(SOCKET fd, const std::string& path);
  void FrameLoop(SOCKET fd);

  // HTTP handshake helpers.
  bool ReadRequestHead(SOCKET fd, std::string* method, std::string* target,
                       std::map<std::string, std::string>* headers);
  bool TokenAcceptable(const std::string& target,
                       const std::map<std::string, std::string>& headers);

  // WebSocket framing / blocking IO.
  void WriteFrameLocked(SOCKET fd, uint8_t opcode,
                        const std::vector<uint8_t>& payload);
  bool ReadN(SOCKET fd, void* buf, int count);
  bool WriteAll(SOCKET fd, const void* buf, int len);
  void WriteRaw(SOCKET fd, const std::string& s);

  const SendToPipe send_to_pipe_;
  const std::string scope_target_id_;  // CEF-2b seam (empty = passthrough)
  std::string token_;
  uint16_t port_ = 0;

  SOCKET listen_sock_ = INVALID_SOCKET;
  std::atomic<bool> running_{false};

  // The single active ws client (one connection per relay; a second upgrade is
  // 503'd). Guarded by client_lock_, which also serializes writes to it.
  SOCKET client_sock_ = INVALID_SOCKET;
  std::mutex client_lock_;

  bool wsa_started_ = false;  // this instance called WSAStartup (balance it)
};

}  // namespace flutter_cef

#endif  // FLUTTER_PLUGIN_FLUTTER_CEF_CDP_RELAY_H_
