import Foundation
import CryptoKit
import Security

/// The token-gated, per-tile-scoped localhost CDP relay (CEF-2a transport + CEF-2b
/// isolation). It re-exposes the CEF-1 CDP-over-pipe to a standard CDP client
/// (`agent-browser`) as a loopback HTTP+WebSocket endpoint, confined (when scoped) to
/// a single tile's CDP target — see the per-tile-isolation note below.
///
/// Why a hand-rolled server (no SwiftNIO/Starscream): the security review demanded
/// a minimal supply-chain surface, and the codebase already speaks raw BSD sockets
/// with dedicated blocking reader threads (`CefProfileHost.acceptAndRead`/
/// `readCdpLoop`) — this matches that style: a loopback `socket()`/`bind()`/
/// `listen()` on `127.0.0.1:0`, an accept thread, and per-connection handler
/// threads doing RFC-6455 framing by hand.
///
/// Security model. The agent does NOT connect directly: Campus brokers it — the app
/// spawns agent-browser, holds the per-grant token in memory, and presents it as an
/// `Authorization: Bearer <token>` header on the CDP upgrade (Playwright forwards
/// request headers). So the relay REQUIRES the token, defeating the classic "malware
/// scans localhost, finds the debug port, drives the browser" attack:
/// - **Mandatory token** — the ws upgrade is rejected (401) without a valid
///   `Authorization: Bearer <token>` (a `?token=` query is an accepted fallback).
///   Discovery (`/json/*`) stays token-free, so a port-scanner learns the ws-url but
///   can't upgrade — it never sees the token (held only in the Campus + spawned-agent
///   process memory; never on disk, argv, env, or the discovery response).
/// - **Loopback only** (`127.0.0.1`) — never reachable off-box.
/// - **Exists only during a grant** — created by enableAgentControl(), torn down by
///   disableAgentControl()/toggle-off/dispose. No standing port.
/// - **Ephemeral, unadvertised port** — random per grant.
/// - **Single active client** — a second concurrent ws upgrade is rejected (503).
/// Net: even a same-UID local process can't connect — it can't obtain the token
/// without reading the Campus/agent process memory (SIP/hardened-runtime protected).
/// Strictly better than raw Chrome's fixed, always-open, multi-client
/// `--remote-debugging-port`.
///
/// Per-tile isolation (CEF-2b): the CDP pipe is browser-wide, so when constructed
/// with a `scopeTargetId` the relay applies a Target-domain filter that exposes the
/// client ONLY that tile's target (and its sub-targets) — sibling tiles in the same
/// shared-profile process are hidden and unreachable. Constructed without a scope it
/// is a raw browser-level passthrough (CEF-2a; dev/test only).
final class CdpRelay {
  /// Forwards a CDP message (one JSON line) to cef_host over the pipe. Captures the
  /// host weakly so the host↔relay ownership (host strongly holds the relay) is not
  /// a cycle.
  private let sendToPipe: (String) -> Void
  /// Per-grant capability secret, REQUIRED on the ws upgrade (presented as an
  /// `Authorization: Bearer <token>` header, or a `?token=` query fallback).
  let token: String
  /// The loopback port the OS assigned (valid after `start()` succeeds).
  private(set) var port: UInt16 = 0

  private var listenFd: Int32 = -1
  private var running = false
  private let stateLock = NSLock()

  /// The single active ws client (CEF-2a supports one connection per relay; a
  /// second upgrade is rejected, avoiding any fd-replacement double-close race).
  /// Guarded by `clientLock`, which also serializes writes to it.
  private var clientFd: Int32 = -1
  private let clientLock = NSLock()

  /// In-flight connection (handler-thread) count, guarded by `stateLock`. Caps
  /// concurrent handshakes so a flood of half-open connections can't exhaust
  /// threads/fds before the single-client gate.
  private var connCount = 0
  private static let maxConns = 16

  /// RFC-6455 server-accept GUID (appended to Sec-WebSocket-Key before SHA-1).
  private static let wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  /// Frame/message size cap (mirrors the IPC reader's 64 MiB frame cap): a hostile
  /// or buggy client must not be able to make us allocate unbounded.
  private static let maxFrame = 64 << 20

  // CEF-2b: per-tile isolation filter. When `scopeTargetId` is set, the relay
  // exposes the client ONLY this CDP target (the opted-in tile) and its descendant
  // sub-targets — sibling tiles in the same shared-profile process are hidden. When
  // nil, the relay is a raw browser-level passthrough (CEF-2a; dev-only). The CDP
  // pipe is browser-wide, so this filter is the per-tile security boundary.
  private let scopeTargetId: String?
  private var ourSessionId: String?            // learned from our target's attachedToTarget
  private var allowedSessions = Set<String>()  // our session + descendant sub-target sessions
  private let filterLock = NSLock()

  // CEF-2b multiplex: this relay's identity in the shared pipe's CDP id space (the
  // owning browser's wire browserId). 0 for the CEF-2a passthrough / unit tests.
  private let relayId: Int

  // CEF-2b multiplex: N relays share ONE browser-wide pipe with ONE CDP id space.
  // Session-routed traffic is demuxed by sessionId, but BROWSER-LEVEL commands
  // (no sessionId — Playwright's connect handshake) would collide. We rewrite
  // EVERY outgoing command id to a globally-unique pipe id and demux responses
  // back. pipeId = (relayId << 21) | localSeq is unique per relay because
  // browserIds are strictly monotonic / never reused.
  private var pipeIdToClientId: [Int: Int] = [:]
  private var nextLocalId = 0
  private let multiplexLock = NSLock()

  init(sendToPipe: @escaping (String) -> Void, scopeTargetId: String? = nil, relayId: Int = 0) {
    self.sendToPipe = sendToPipe
    self.scopeTargetId = scopeTargetId
    self.relayId = relayId
    self.token = CdpRelay.randomToken()
  }

  // The relay runs on the normal grant path, so its diagnostics are gated behind
  // FLUTTER_CEF_DEBUG — a release build stays quiet (and doesn't log the port or
  // per-frame, peer-controlled protocol errors to unified logging).
  private static let debugEnabled =
    ProcessInfo.processInfo.environment["FLUTTER_CEF_DEBUG"] != nil
  private func dlog(_ msg: @autoclosure () -> String) {
    if CdpRelay.debugEnabled { NSLog("%@", msg()) }
  }

  private static func randomToken() -> String {
    var bytes = [UInt8](repeating: 0, count: 24)
    if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
      // SecRandomCopyBytes effectively never fails on macOS; if it ever did, fail
      // closed with a token that cannot be guessed-around (caller treats start()
      // success as the gate, and a bad token just means no client can connect).
      for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: arc4random()) }
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
  }

  // MARK: Lifecycle

  /// Bind a loopback TCP listener on an OS-assigned port and start accepting.
  /// Returns false (cleaning up) on any failure.
  func start() -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { dlog("[cef][relay] socket() failed"); return false }
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0  // OS picks an ephemeral port
    addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian  // 127.0.0.1 — loopback only
    let bindOK = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindOK == 0, listen(fd, 4) == 0 else {
      dlog("[cef][relay] bind/listen failed: \(String(cString: strerror(errno)))")
      close(fd); return false
    }

    // Read back the assigned port.
    var bound = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameOK = withUnsafeMutablePointer(to: &bound) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
    }
    guard nameOK == 0 else { dlog("[cef][relay] getsockname failed"); close(fd); return false }
    port = UInt16(bigEndian: bound.sin_port)

    stateLock.lock(); listenFd = fd; running = true; stateLock.unlock()
    Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
    dlog("[cef][relay] listening on 127.0.0.1:\(port)")
    return true
  }

  /// Stop the listener, drop any client, and refuse further connections. Idempotent.
  ///
  /// The CLIENT fd is only SHUT DOWN here, never close()'d: this process concurrently
  /// holds the IPC socket and the CDP pipe fds, so close()ing a number a handler thread
  /// is mid-syscall on (a pong/close write, or the next read) risks that number being
  /// reclaimed and the syscall hitting an unrelated descriptor (fd-reuse). shutdown()
  /// wakes the handler's blocked read() without freeing the number; the handler then
  /// performs the single close() via the clientFd ownership protocol (it is kept alive
  /// for the duration of its in-flight handleConnection call). Done under clientLock so
  /// clientFd can't be a stale number when we shut it down. The listener has no such
  /// race (its thread only ever blocks in accept()), so stop() owns its shutdown+close.
  func stop() {
    stateLock.lock()
    running = false
    let lfd = listenFd; listenFd = -1
    stateLock.unlock()
    if lfd >= 0 { shutdown(lfd, SHUT_RDWR); close(lfd) }  // wake accept() reliably, then close
    clientLock.lock()
    if clientFd >= 0 { shutdown(clientFd, SHUT_RDWR) }  // wake the handler; it owns the close
    clientLock.unlock()
  }

  private func isRunning() -> Bool { stateLock.lock(); defer { stateLock.unlock() }; return running }

  // MARK: Accept

  private func acceptLoop(_ lfd: Int32) {
    while isRunning() {
      let fd = accept(lfd, nil, nil)
      if fd < 0 { if isRunning() { continue } else { break } }
      _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
      var on: Int32 = 1
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
      // Send timeout: a stalled client (TCP send buffer full, peer not reading) must
      // not block deliverToClient (called from the CDP reader thread, under
      // clientLock) — which would also wedge stop()/shutdown. write() then fails and
      // the client is dropped. Loopback drains in microseconds, so 2s only ever trips
      // a genuinely stuck peer (and bounds the worst-case teardown wait).
      var tv = timeval(tv_sec: 2, tv_usec: 0)
      setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
      // Admit only up to maxConns concurrent handlers (slowloris / thread-exhaustion
      // backstop); the handler decrements on exit.
      stateLock.lock()
      let admit = connCount < CdpRelay.maxConns
      if admit { connCount += 1 }
      stateLock.unlock()
      if !admit { close(fd); continue }
      Thread.detachNewThread { [weak self] in
        self?.handleConnection(fd)
        guard let self = self else { return }
        self.stateLock.lock(); self.connCount -= 1; self.stateLock.unlock()
      }
    }
  }

  // MARK: HTTP / handshake

  private func handleConnection(_ fd: Int32) {
    // Read timeout for the HANDSHAKE only: a half-open peer (slowloris) can't hold the
    // handler open indefinitely. Cleared after a successful upgrade — the ws frame
    // loop idles between agent commands and must not time out.
    var rtv = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rtv, socklen_t(MemoryLayout<timeval>.size))
    guard let head = readRequestHead(fd) else { close(fd); return }
    let (method, target, headers) = head
    var path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    // Normalize a trailing slash: Playwright (which the agent-browser CLI wraps)
    // fetches `GET /json/version/` WITH a trailing slash, so an exact match misses.
    if path.count > 1, path.hasSuffix("/") { path.removeLast() }

    // CDP discovery (token-free): the client GETs this to find the ws-url. We
    // advertise a token-free /devtools/browser url (the upgrade is what's gated).
    if method == "GET", path == "/json/version" || path == "/json" || path == "/json/list" {
      serveDiscovery(fd, path: path)
      close(fd)
      return
    }

    // WebSocket upgrade — the only authenticated path.
    let isUpgrade = (headers["upgrade"]?.lowercased().contains("websocket") ?? false)
    guard isUpgrade, let key = headers["sec-websocket-key"], !key.isEmpty else {
      writeRaw(fd, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
      close(fd); return
    }
    guard tokenAcceptable(target, headers) else {
      dlog("[cef][relay] ws upgrade rejected: token absent or invalid")
      writeRaw(fd, "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
      close(fd); return
    }

    // CEF-2a: one active client per relay. Reject a second concurrent upgrade
    // (avoids any fd-replacement double-close race); the slot frees on disconnect.
    clientLock.lock()
    if clientFd >= 0 {
      clientLock.unlock()
      writeRaw(fd, "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
      close(fd); return
    }
    clientFd = fd
    clientLock.unlock()

    let accept = Data((key + CdpRelay.wsGUID).utf8)
    let digest = Insecure.SHA1.hash(data: accept)
    let acceptKey = Data(digest).base64EncodedString()
    writeRaw(fd, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(acceptKey)\r\n\r\n")
    dlog("[cef][relay] client attached")

    // Clear the handshake read timeout: the ws connection is persistent and idles
    // between agent commands.
    var zero = timeval(tv_sec: 0, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &zero, socklen_t(MemoryLayout<timeval>.size))
    frameLoop(fd)

    // Close exactly once. Whoever clears clientFd from `fd` owns the close: if stop()
    // already took the slot (clientFd != fd) it closes the fd, so closing here too
    // would be a double-close (and could hit a reused fd number).
    clientLock.lock()
    let owned = clientFd == fd
    if owned { clientFd = -1 }
    clientLock.unlock()
    if owned { close(fd) }
    dlog("[cef][relay] client detached")
  }

  private func serveDiscovery(_ fd: Int32, path: String) {
    // Token-free ws-url (see security model). The token is NOT advertised here — the
    // Campus-brokered agent presents it as an `Authorization: Bearer` header on the
    // upgrade, so a local port-scanner that reads this url still can't connect.
    let wsUrl = "ws://127.0.0.1:\(port)/devtools/browser"
    let body: String
    if path == "/json/list" {
      body = "[{\"type\":\"page\",\"webSocketDebuggerUrl\":\"\(wsUrl)\"}]"
    } else {
      body = "{\"Browser\":\"flutter_cef\",\"Protocol-Version\":\"1.3\",\"webSocketDebuggerUrl\":\"\(wsUrl)\"}"
    }
    let bytes = Array(body.utf8)
    writeRaw(fd, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n")
    _ = writeAll(fd, bytes)
  }

  /// True iff the connection presents the correct token — now REQUIRED (an absent
  /// OR wrong token is rejected). The token is minted per-grant and handed to
  /// Campus in-process; the Campus-brokered agent-browser presents it as an
  /// `Authorization: Bearer <token>` header (Playwright forwards request headers on
  /// the ws upgrade), with a `?token=` query as a fallback. Discovery (`/json/*`)
  /// stays token-free, so a local port-scanner learns the ws-url but can't upgrade
  /// without the token it never sees. Constant-time compared.
  func tokenAcceptable(_ target: String, _ headers: [String: String]) -> Bool {
    var supplied: String?
    // Preferred: Authorization: Bearer <token> — how the Campus-brokered agent
    // presents it (the token never lands in the url/argv/discovery response).
    if let auth = headers["authorization"] {
      let parts = auth.split(separator: " ", maxSplits: 1)
      if parts.count == 2, parts[0].lowercased() == "bearer" { supplied = String(parts[1]) }
    }
    // Fallback: ?token=<token> in the upgrade target (e.g. a token-bearing ws-url).
    if supplied == nil, let q = target.split(separator: "?", maxSplits: 1).dropFirst().first {
      for pair in q.split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1)
        if kv.first == "token" { supplied = kv.count > 1 ? String(kv[1]) : "" }
      }
    }
    guard let got = supplied, !got.isEmpty else { return false }  // absent → REJECT
    return constantTimeEquals(got, token)
  }

  private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    if x.count != y.count { return false }
    var diff: UInt8 = 0
    for i in x.indices { diff |= x[i] ^ y[i] }
    return diff == 0
  }

  /// Read the HTTP request head (request line + headers) up to CRLFCRLF. Returns
  /// (method, request-target, lowercased-header-map). Bounded to 16 KiB.
  private func readRequestHead(_ fd: Int32) -> (String, String, [String: String])? {
    var acc = [UInt8]()
    var byte: UInt8 = 0
    while acc.count < 16 << 10 {
      let n = read(fd, &byte, 1)
      if n <= 0 { return nil }
      acc.append(byte)
      if acc.count >= 4, acc[acc.count - 4] == 0x0d, acc[acc.count - 3] == 0x0a,
         acc[acc.count - 2] == 0x0d, acc[acc.count - 1] == 0x0a { break }
    }
    // Reject a head that hit the 16 KiB cap without a complete CRLFCRLF terminator —
    // a truncated head must not be parsed (and accepted) as if it were complete.
    guard acc.count >= 4, acc[acc.count - 4] == 0x0d, acc[acc.count - 3] == 0x0a,
          acc[acc.count - 2] == 0x0d, acc[acc.count - 1] == 0x0a else { return nil }
    guard let text = String(bytes: acc, encoding: .utf8) else { return nil }
    let lines = text.components(separatedBy: "\r\n")
    guard let reqLine = lines.first else { return nil }
    let parts = reqLine.split(separator: " ")
    guard parts.count >= 2 else { return nil }
    var headers = [String: String]()
    for line in lines.dropFirst() where !line.isEmpty {
      if let c = line.firstIndex(of: ":") {
        let k = line[..<c].trimmingCharacters(in: .whitespaces).lowercased()
        let v = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
        headers[k] = v
      }
    }
    return (String(parts[0]), String(parts[1]), headers)
  }

  // MARK: WebSocket framing (RFC 6455, server side)

  /// Read masked client frames, reassemble fragmented text messages, and forward
  /// each complete CDP message to the pipe. Handles ping/pong/close inline. Exits on
  /// EOF/error/close/protocol-violation.
  private func frameLoop(_ fd: Int32) {
    var msg = [UInt8]()         // accumulated payload of the current data message
    var assembling = false      // a fragmented data message is in progress
    var assemblingText = false  // ...and it's text (vs binary, whose payload we drop)
    while isRunning() {
      guard let h0 = readByte(fd), let h1 = readByte(fd) else { return }
      let fin = (h0 & 0x80) != 0
      let opcode = h0 & 0x0f
      let masked = (h1 & 0x80) != 0
      var len = UInt64(h1 & 0x7f)
      if len == 126 {
        guard let e = readN(fd, 2) else { return }
        len = (UInt64(e[0]) << 8) | UInt64(e[1])
      } else if len == 127 {
        guard let e = readN(fd, 8) else { return }
        len = e.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
      }
      if len > UInt64(CdpRelay.maxFrame) { dlog("[cef][relay] frame too large"); return }
      // RFC 6455 §5.5: control frames (close/ping/pong) carry <=125 bytes and are never
      // fragmented. Enforce so a hostile peer can't make us buffer + echo a huge ping.
      if opcode == 0x8 || opcode == 0x9 || opcode == 0xA {
        if len > 125 || !fin { dlog("[cef][relay] bad control frame"); return }
      }
      // Client→server frames MUST be masked (RFC 6455 §5.1).
      guard masked, let mask = readN(fd, 4) else { return }
      var payload = len > 0 ? (readN(fd, Int(len)) ?? []) : []
      if payload.count != Int(len) { return }
      for i in payload.indices { payload[i] ^= mask[i % 4] }

      // Control frames (0x8/0x9/0xA) may interleave a fragmented data message and are
      // themselves never fragmented, so they don't touch the assembly state. Data
      // frames (0x0/0x1/0x2) follow the RFC-6455 §5.4 fragmentation rules: a new data
      // frame is illegal mid-message, a continuation is illegal with no message.
      switch opcode {
      case 0x0, 0x1, 0x2:
        if opcode == 0x0 {
          guard assembling else { dlog("[cef][relay] continuation with no message"); return }
        } else {
          guard !assembling else { dlog("[cef][relay] new data frame mid-message"); return }
          assemblingText = (opcode == 0x1)  // 0x2 binary: framing tracked, payload dropped
        }
        if assemblingText {
          if msg.count + payload.count > CdpRelay.maxFrame { dlog("[cef][relay] message too large"); return }
          msg.append(contentsOf: payload)
        }
        assembling = !fin
        if fin {
          if assemblingText, let s = String(bytes: msg, encoding: .utf8) {
            if let out = filterClientToPipe(s) { sendToPipe(rewriteOutgoingId(out)) }  // CEF-2b scope filter + id remap
          }
          msg.removeAll(keepingCapacity: true)
          assemblingText = false
        }
      case 0x8:  // close
        writeFrame(fd, opcode: 0x8, payload: [])
        return
      case 0x9:  // ping → pong (control frames are never fragmented)
        writeFrame(fd, opcode: 0xA, payload: payload)
      case 0xA:  // pong — ignore
        break
      default:
        dlog("[cef][relay] unknown opcode \(opcode)"); return
      }
    }
  }

  /// Deliver a CDP message from the pipe to the connected client. Applies the CEF-2b
  /// multiplex demux + scope filter (drops sibling-tile traffic) before writing.
  /// Called off the CDP reader thread.
  func deliverToClient(_ json: String) {
    guard let out = demuxPipeToClient(json) else { return }  // dropped: not our tile
    sendRawToClient(out)
  }

  /// CEF-2b pure decision seam (no socket IO — unit-testable): map one inbound pipe
  /// message to the bytes this relay should hand its client, or nil to DROP it.
  ///
  /// Multiplex demux (scoped relays only): a pipe message with a top-level id and NO
  /// method is a command RESPONSE, owned by exactly the relay that issued that unique
  /// pipe id. Restore the client's original id, or drop if it's a sibling relay's
  /// response. Events (method present) + the CEF-2a passthrough fall through to the
  /// scope filter unchanged.
  func demuxPipeToClient(_ json: String) -> String? {
    if scopeTargetId != nil, let m = parseJson(json), m["method"] == nil,
       let pipeId = m["id"] as? Int {
      multiplexLock.lock(); let clientId = pipeIdToClientId.removeValue(forKey: pipeId); multiplexLock.unlock()
      guard let clientId = clientId else { return nil }  // sibling relay's response — drop
      var restored = m; restored["id"] = clientId
      return jsonString(restored)
    }
    return filterPipeToClient(json)  // events / browser-level / CEF-2a passthrough
  }

  /// Write a raw (already-filtered / self-originated) JSON text frame to the client.
  private func sendRawToClient(_ json: String) {
    clientLock.lock(); defer { clientLock.unlock() }
    guard clientFd >= 0 else { return }
    writeFrameLocked(clientFd, opcode: 0x1, payload: Array(json.utf8))
  }

  /// Write a server frame (unmasked). Takes clientLock itself (callers that already
  /// hold it use `writeFrameLocked`).
  private func writeFrame(_ fd: Int32, opcode: UInt8, payload: [UInt8]) {
    clientLock.lock(); defer { clientLock.unlock() }
    writeFrameLocked(fd, opcode: opcode, payload: payload)
  }

  private func writeFrameLocked(_ fd: Int32, opcode: UInt8, payload: [UInt8]) {
    var frame = [UInt8]()
    frame.append(0x80 | opcode)  // FIN + opcode
    let n = payload.count
    if n < 126 {
      frame.append(UInt8(n))     // no mask bit (server→client is never masked)
    } else if n <= 0xFFFF {
      frame.append(126)
      frame.append(UInt8((n >> 8) & 0xff)); frame.append(UInt8(n & 0xff))
    } else {
      frame.append(127)
      for s in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((UInt64(n) >> s) & 0xff)) }
    }
    frame.append(contentsOf: payload)
    if !writeAll(fd, frame) {
      // Write failed: EAGAIN (SO_SNDTIMEO on a stuck peer, possibly mid-frame → the
      // stream is now desynced) or EPIPE/EBADF on a dead one. Don't keep writing onto
      // a broken stream — shut the socket down so the handler's blocking read()
      // returns and it exits, closing the fd via the ownership protocol. We only
      // shutdown (not close/clear) here, leaving the single close-owner intact.
      shutdown(fd, SHUT_RDWR)
    }
  }

  // MARK: CEF-2b — per-tile Target-domain filter (deny-by-default, fail-closed)
  //
  // The CDP pipe is browser-wide, so this filter is THE per-tile security boundary —
  // built to be safe against a hostile client, not just to support Playwright:
  //  - FAIL CLOSED: a message we can't parse is dropped, never forwarded unfiltered
  //    (JSONSerialization is stricter than Chromium's parser, so "forward on parse
  //    fail" would be a filter bypass).
  //  - FLATTEN ONLY: the legacy non-flatten messaging path (sendMessageToTarget /
  //    receivedMessageFromTarget, non-flatten attach) is refused/dropped — it would
  //    otherwise let a client wrap commands to a SIBLING session.
  //  - DENY BY DEFAULT (C→R), for ALL domains, not just Target.*: forwarded are only
  //    (a) commands routed to an allowed session (page-scoped Page/Runtime/DOM/Input/
  //    Network-events/etc.), (b) the scoped Target.* allow-list, and (c) Browser.getVersion.
  //    Everything else is refused (attachToBrowserTarget, exposeDevToolsProtocol,
  //    createTarget, createBrowserContext, …).
  //  - BROWSER-CONTEXT-WIDE domains are denied REGARDLESS of session routing
  //    (isCrossTileMethod): tiles in a shared profile share ONE browser context, so
  //    Storage.*, Tracing.*, Memory.*, SystemInfo.*, Browser.* (except getVersion), and
  //    the Network cookie/cache methods operate on the whole shared jar/process even
  //    when sent with our page's sessionId. The page's own document.cookie (via
  //    Runtime.evaluate) stays available and is correctly origin-scoped.
  //    (Caveat: true per-tile isolation of these would require per-tile browser
  //    contexts, which would un-share the login the shared profile exists to share —
  //    so the denylist is the deliberate boundary here.)
  // Playwright drives in flatten mode: Target.setAutoAttach{flatten:true} (browser
  // level) → ONE Target.attachedToTarget for our page (sessionId learned here) → all
  // page work routed by that top-level sessionId (+ nested sub-target sessions).

  /// pipe → client. Returns the JSON to forward, or nil to drop. nil scope =
  /// passthrough (CEF-2a, dev only). (Internal, not private, so the standalone
  /// filter unit test — CdpRelayFilterTests.swift — can exercise it directly.)
  func filterPipeToClient(_ json: String) -> String? {
    guard let tid = scopeTargetId else { return json }
    guard let m = parseJson(json) else { return nil }  // fail closed
    let method = m["method"] as? String
    let sid = m["sessionId"] as? String
    let params = m["params"] as? [String: Any]

    filterLock.lock(); defer { filterLock.unlock() }

    switch method {
    case "Target.attachedToTarget":
      let attachedTid = (params?["targetInfo"] as? [String: Any])?["targetId"] as? String
      let childSession = params?["sessionId"] as? String
      if sid == nil {  // browser-level auto-attach of a top-level target (a tile)
        guard attachedTid == tid else { return nil }  // sibling tile — hide
        if let cs = childSession { allowedSessions.insert(cs); ourSessionId = cs }
        return json
      }
      guard let s = sid, allowedSessions.contains(s) else { return nil }  // sub-target of ours
      if let cs = childSession { allowedSessions.insert(cs) }
      return json
    case "Target.detachedFromTarget", "Target.targetDestroyed",
         "Target.targetCreated", "Target.targetInfoChanged":
      let evtTid = (params?["targetInfo"] as? [String: Any])?["targetId"] as? String
        ?? params?["targetId"] as? String
      if sid == nil { return evtTid == tid ? json : nil }
      return allowedSessions.contains(sid!) ? json : nil
    case "Target.receivedMessageFromTarget":
      // legacy non-flatten wrapper carrying a target's reply — forward only for our
      // sessions (we refuse non-flatten C→R, but drop defensively regardless).
      let s = params?["sessionId"] as? String
      return (s != nil && allowedSessions.contains(s!)) ? json : nil
    default:
      break
    }
    // Any message carrying a sessionId: forward only for our (allowed) sessions.
    if let s = sid { return allowedSessions.contains(s) ? json : nil }
    // Defensive: drop any stray target enumeration (we synthesize the only getTargets
    // reply ourselves, C→R — cef_host should never send one here).
    if let result = m["result"] as? [String: Any], result["targetInfos"] != nil { return nil }
    return json  // browser-level response / event, no session or foreign target ref
  }

  /// client → pipe. Returns the JSON to forward, or nil to drop. Drops are reported
  /// to the client as a CDP error — sent OUTSIDE filterLock (never block IO under it).
  /// (Internal, not private, for CdpRelayFilterTests.swift.)
  func filterClientToPipe(_ json: String) -> String? {
    guard scopeTargetId != nil else { return json }
    guard let m = parseJson(json) else { return nil }  // fail closed
    let method = m["method"] as? String
    let sid = m["sessionId"] as? String
    let params = m["params"] as? [String: Any]
    let id = m["id"] as? Int

    // Browser.setDownloadBehavior is sent by Playwright/connectOverCDP during connect
    // and is browser-context-wide (no per-tile scoping). NO-OP it: reply success
    // without forwarding, so the client proceeds but the shared download behavior is
    // not changed across tiles. (An agent drives the page, not browser-wide download
    // policy; if real per-tile download control is ever needed it requires per-tile
    // browser contexts.)
    if method == "Browser.setDownloadBehavior" { synthesizeOk(id); return nil }

    // Then: deny browser-context-wide / process-global methods REGARDLESS of session
    // routing. All tiles in a shared profile run in ONE browser context (cef_host
    // CreateBrowserSync with a null request context), so these domains operate on the
    // whole shared cookie jar / storage / process — NOT scoped to our tile — even when
    // sent with our page's sessionId. Routing them through a page session does not
    // confine them. The agent drives its tile's PAGE (Page/Runtime/DOM/Input/Network
    // events on its session); reading/clearing the shared jar or capturing the whole
    // process crosses the per-tile boundary the design exists to enforce.
    if let method = method, isCrossTileMethod(method) {
      sendClientError(id, "\(method) is not permitted (browser-context-wide; crosses the per-tile boundary)")
      return nil
    }

    // Session-routed command (flatten): allow only for our (allowed) sessions. The
    // brief lock is released before any error IO (H4).
    if let s = sid {
      filterLock.lock(); let allowed = allowedSessions.contains(s); filterLock.unlock()
      if allowed { return json }
      sendClientError(id, "Session with given id not found"); return nil
    }

    // Browser-level Target.* control: explicit allow-list, scoped to our target.
    if let method = method, method.hasPrefix("Target.") {
      let qTid = params?["targetId"] as? String
      switch method {
      case "Target.setDiscoverTargets":
        return json  // browser-wide; resulting events are filtered inbound
      case "Target.setAutoAttach":
        guard (params?["flatten"] as? Bool) == true else {
          sendClientError(id, "non-flatten setAutoAttach is not permitted"); return nil
        }
        return json
      case "Target.attachToTarget":
        guard qTid == scopeTargetId else { sendClientError(id, "No target with given id found"); return nil }
        guard (params?["flatten"] as? Bool) == true else {
          sendClientError(id, "non-flatten attachToTarget is not permitted"); return nil
        }
        return json
      case "Target.getTargetInfo", "Target.closeTarget", "Target.activateTarget":
        guard qTid == nil || qTid == scopeTargetId else {  // no id (browser/own) or ours
          sendClientError(id, "No target with given id found"); return nil
        }
        return json
      case "Target.getTargets":
        synthesizeGetTargets(id); return nil  // never enumerate the process to the client
      default:
        // createTarget, attachToBrowserTarget, exposeDevToolsProtocol, sendMessageToTarget,
        // setRemoteLocations, createBrowserContext, autoAttachRelated, … — DENY.
        sendClientError(id, "\(method) is not permitted"); return nil
      }
    }

    // Other browser-level (no sessionId, non-Target) command: DENY BY DEFAULT. Only a
    // tiny tile-agnostic read-only allow-list is forwarded; the cross-tile domains were
    // already denied above.
    if method == "Browser.getVersion" { return json }
    sendClientError(id, "\(method ?? "command") is not permitted at browser scope")
    return nil
  }

  /// Browser-context-wide / process-global CDP methods that are NOT scoped to a single
  /// tile even when sent with a page sessionId (tiles share one browser context). These
  /// are denied in both directions of routing — see filterClientToPipe.
  private func isCrossTileMethod(_ method: String) -> Bool {
    if method == "Browser.getVersion" { return false }  // benign read-only
    if method.hasPrefix("Storage.") || method.hasPrefix("Tracing.")
        || method.hasPrefix("Memory.") || method.hasPrefix("SystemInfo.")
        || method.hasPrefix("Browser.") { return true }
    // Cookie/cache methods operate on the shared browser context's jar, not the page's
    // origin. (The page's own document.cookie via Runtime.evaluate stays available and
    // is correctly origin-scoped.)
    switch method {
    case "Network.getAllCookies", "Network.getCookies", "Network.setCookie",
         "Network.setCookies", "Network.deleteCookies", "Network.clearBrowserCookies",
         "Network.clearBrowserCache":
      return true
    default:
      return false
    }
  }

  /// Reply to the client's Target.getTargets with ONLY our tile (never the process).
  private func synthesizeGetTargets(_ id: Int?) {
    guard let id = id, let tid = scopeTargetId else { return }
    let info: [String: Any] = ["targetId": tid, "type": "page", "title": "", "url": "",
                               "attached": true, "canAccessOpener": false, "browserContextId": ""]
    sendClientJson(["id": id, "result": ["targetInfos": [info]]])
  }

  /// Send a CDP error reply to the client. Built via JSONSerialization so the message
  /// can't break the frame. No-op without an id (a notification has nothing to error).
  private func sendClientError(_ id: Int?, _ message: String) {
    guard let id = id else { return }
    sendClientJson(["id": id, "error": ["code": -32000, "message": message]])
  }

  /// Reply success ({}) to a command we intentionally NO-OP (don't forward) — lets the
  /// client proceed without applying a cross-tile effect.
  private func synthesizeOk(_ id: Int?) {
    guard let id = id else { return }
    sendClientJson(["id": id, "result": [String: Any]()])
  }

  private func sendClientJson(_ obj: [String: Any]) {
    if let d = try? JSONSerialization.data(withJSONObject: obj),
       let s = String(data: d, encoding: .utf8) { sendRawToClient(s) }
  }

  private func parseJson(_ s: String) -> [String: Any]? {
    guard let d = s.data(using: .utf8),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
    return o
  }

  private func jsonString(_ obj: [String: Any]) -> String? {
    guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
    return String(data: d, encoding: .utf8)
  }

  // Rewrite an outgoing command's top-level id to a globally-unique pipe id and
  // record the mapping. No-op for the CEF-2a passthrough (nil scope) and for
  // messages without a top-level Int id (none, in practice clients only send
  // commands). Called for client->pipe traffic only. Internal (not private) so the
  // standalone filter tests can drive the rewrite↔demux round-trip directly.
  func rewriteOutgoingId(_ json: String) -> String {
    guard scopeTargetId != nil else { return json }
    guard var m = parseJson(json), let clientId = m["id"] as? Int else { return json }
    multiplexLock.lock()
    let pipeId = (relayId << 21) | (nextLocalId & 0x1FFFFF)
    nextLocalId &+= 1
    pipeIdToClientId[pipeId] = clientId
    multiplexLock.unlock()
    m["id"] = pipeId
    return jsonString(m) ?? json
  }

  // MARK: Blocking IO helpers

  private func readByte(_ fd: Int32) -> UInt8? {
    var b: UInt8 = 0
    return read(fd, &b, 1) == 1 ? b : nil
  }

  private func readN(_ fd: Int32, _ count: Int) -> [UInt8]? {
    var buf = [UInt8](repeating: 0, count: count)
    var got = 0
    while got < count {
      let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: got), count - got) }
      if n <= 0 { return nil }
      got += n
    }
    return buf
  }

  @discardableResult
  private func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var off = 0
    while off < bytes.count {
      let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: off), bytes.count - off) }
      if n <= 0 { return false }  // EPIPE/EBADF (SO_NOSIGPIPE keeps it from signaling)
      off += n
    }
    return true
  }

  private func writeRaw(_ fd: Int32, _ s: String) { _ = writeAll(fd, Array(s.utf8)) }
}
