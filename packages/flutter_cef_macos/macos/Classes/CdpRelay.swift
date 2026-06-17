import Foundation
import CryptoKit
import Security

/// CEF-2a — the token-gated localhost CDP relay (transport only; no target filter
/// yet, that is CEF-2b). It re-exposes the CEF-1 CDP-over-pipe to a standard CDP
/// client (`agent-browser`) as a loopback HTTP+WebSocket endpoint, so the only
/// thing that can drive the tile is a client Campus hands the per-grant token to.
///
/// Why a hand-rolled server (no SwiftNIO/Starscream): the security review demanded
/// a minimal supply-chain surface, and the codebase already speaks raw BSD sockets
/// with dedicated blocking reader threads (`CefProfileHost.acceptAndRead`/
/// `readCdpLoop`) — this matches that style: a loopback `socket()`/`bind()`/
/// `listen()` on `127.0.0.1:0`, an accept thread, and per-connection handler
/// threads doing RFC-6455 framing by hand.
///
/// Security model (CEF-2a). agent-browser v0.6.0 connects via a bare `--cdp <port>`
/// and cannot attach any secret (query or header) to the CDP connection, so a
/// client-supplied token cannot be the gate for it. The achievable controls are:
/// - **Loopback only** (`127.0.0.1`) — never reachable off-box.
/// - **Exists only during a grant** — the relay is created by enableAgentControl()
///   and torn down by disableAgentControl()/toggle-off/dispose. No standing port.
/// - **Ephemeral, unadvertised port** — random per grant; `/json/version` discovery
///   reveals only a token-free ws-url, never the port out-of-band.
/// - **Single active client** — a second concurrent ws upgrade is rejected (503), so
///   once the agent's connection is established it holds the slot for the session.
/// Net: an attacker must win a sub-second race on a random loopback port in the gap
/// between enable and the agent connecting — narrow, same-UID only. Strictly better
/// than raw Chrome's fixed, always-open, multi-client `--remote-debugging-port`.
/// The TOKEN is kept as validated-if-present defense-in-depth: a token-capable
/// client (Campus's own CDP client, or a Campus-side forwarder that injects it)
/// that passes `?token=` gets it constant-time-checked, upgrading to real auth; an
/// absent token is allowed (so vanilla agent-browser works).
///
/// CEF-2a passes CDP through whole (browser-level). Per-tile isolation (the Target
/// filter) is CEF-2b; until then the relay is dev-validation-only and must not ship
/// enabled, since a connected client could reach sibling tiles in the process.
final class CdpRelay {
  /// Forwards a CDP message (one JSON line) to cef_host over the pipe. Captures the
  /// host weakly so the host↔relay ownership (host strongly holds the relay) is not
  /// a cycle.
  private let sendToPipe: (String) -> Void
  /// Per-grant capability secret, required as `?token=` on the ws upgrade.
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

  init(sendToPipe: @escaping (String) -> Void) {
    self.sendToPipe = sendToPipe
    self.token = CdpRelay.randomToken()
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
    guard fd >= 0 else { NSLog("[cef][relay] socket() failed"); return false }
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
      NSLog("[cef][relay] bind/listen failed: \(String(cString: strerror(errno)))")
      close(fd); return false
    }

    // Read back the assigned port.
    var bound = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameOK = withUnsafeMutablePointer(to: &bound) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
    }
    guard nameOK == 0 else { NSLog("[cef][relay] getsockname failed"); close(fd); return false }
    port = UInt16(bigEndian: bound.sin_port)

    stateLock.lock(); listenFd = fd; running = true; stateLock.unlock()
    Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
    NSLog("[cef][relay] listening on 127.0.0.1:\(port)")
    return true
  }

  /// Stop the listener, drop any client, and refuse further connections. Idempotent.
  func stop() {
    stateLock.lock()
    running = false
    let lfd = listenFd; listenFd = -1
    stateLock.unlock()
    if lfd >= 0 { close(lfd) }  // unblocks accept() with EBADF
    clientLock.lock()
    let cfd = clientFd; clientFd = -1
    clientLock.unlock()
    if cfd >= 0 { close(cfd) }  // unblocks the frame loop's read()
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
    guard tokenAcceptable(target) else {
      NSLog("[cef][relay] ws upgrade rejected: token present but invalid")
      writeRaw(fd, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
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
    NSLog("[cef][relay] client attached")

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
    NSLog("[cef][relay] client detached")
  }

  private func serveDiscovery(_ fd: Int32, path: String) {
    // Token-free ws-url (see security model). agent-browser rewrites host/port and
    // appends its ?token= query before connecting.
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

  /// True unless a `?token=` is present AND wrong. An absent token is accepted —
  /// agent-browser can't attach one to a bare `--cdp <port>` connection, so for it
  /// the gate is the ephemeral port + lifecycle + single-client slot (see the type
  /// doc). A client that DOES pass `?token=` gets it constant-time-validated.
  private func tokenAcceptable(_ target: String) -> Bool {
    guard let q = target.split(separator: "?", maxSplits: 1).dropFirst().first else { return true }
    var supplied: String?
    for pair in q.split(separator: "&") {
      let kv = pair.split(separator: "=", maxSplits: 1)
      if kv.first == "token" { supplied = kv.count > 1 ? String(kv[1]) : "" }
    }
    guard let got = supplied else { return true }  // no token param → allowed
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
      if len > UInt64(CdpRelay.maxFrame) { NSLog("[cef][relay] frame too large"); return }
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
          guard assembling else { NSLog("[cef][relay] continuation with no message"); return }
        } else {
          guard !assembling else { NSLog("[cef][relay] new data frame mid-message"); return }
          assemblingText = (opcode == 0x1)  // 0x2 binary: framing tracked, payload dropped
        }
        if assemblingText {
          if msg.count + payload.count > CdpRelay.maxFrame { NSLog("[cef][relay] message too large"); return }
          msg.append(contentsOf: payload)
        }
        assembling = !fin
        if fin {
          if assemblingText, let s = String(bytes: msg, encoding: .utf8) { sendToPipe(s) }
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
        NSLog("[cef][relay] unknown opcode \(opcode)"); return
      }
    }
  }

  /// Deliver a CDP message from the pipe to the connected client as a text frame.
  /// No-op when no client is attached. Called off the CDP reader thread.
  func deliverToClient(_ json: String) {
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
