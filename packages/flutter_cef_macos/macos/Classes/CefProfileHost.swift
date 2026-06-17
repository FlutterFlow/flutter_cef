// One cef_host.app subprocess per profile. Owns the process, the Unix-socket
// listen/conn fds, the write lock + pending-frame queue, and the reader thread;
// multiplexes N CefWebSession browsers over that single IPC pipe, each keyed by
// a Swift-assigned wire browserId (monotonic from 1).
//
// Wire frame (both directions): [u32 bodyLen BE][u32 browserId BE][u8 op][payload],
// where bodyLen = 4 + 1 + payloadLen. browserId 0 is process/profile-level
// (opReady, process logs, opShutdown). See native/cef_host/main.mm.
//
// Split out of CefWebSession: the session keeps only its texture/IOSurface and
// per-view verbs; everything process/socket/reader-shaped lives here, so several
// views sharing one `profile:` share one host -> one cookie jar -> one login.

import Foundation
import IOSurface

final class CefProfileHost {
  // IPC opcodes this host layer needs to NAME (process-level + control). The
  // full per-view opcode table lives on CefWebSession; these must match
  // native/cef_host/main.mm.
  static let opCreateBrowser: UInt8 = 0x13
  static let opDisposeBrowser: UInt8 = 0x15
  static let opShutdown: UInt8 = 0x14
  static let opReady: UInt8 = 0x02
  static let opLog: UInt8 = 0x04
  static let opResize: UInt8 = 0x11

  // Profile identity / config.
  let profileId: String
  let profileDir: String
  let isEphemeral: Bool
  // The 127.0.0.1 port CEF's DevTools (CDP) server bound for this host, or 0
  // when CDP wasn't requested. Chosen here (free-port pick); CDP is only ever
  // requested for ephemeral hosts (named+CDP is rejected upstream). Reported
  // back to Dart in each create() result.
  private(set) var cdpPort: Int = 0

  // Process + IPC machinery (hoisted from CefWebSession).
  private var process: Process?
  private var listenFd: Int32 = -1
  private var connFd: Int32 = -1
  private var socketPath = ""
  private let writeLock = NSLock()
  private var pendingFrames: [[UInt8]] = []  // queued until the pipe connects
  private var running = false
  private var readerStarted = false
  private let readerDone = DispatchSemaphore(value: 0)  // signaled when the
  // acceptAndRead thread exits, so shutdown() can join it before freeing state.

  // Browser multiplexing. `browsers`/`nextBrowserId` are guarded by
  // `browsersLock`; `createEnqueued`/`pendingCreates`/`ready`/`adhocHost` are
  // guarded by `writeLock` (they gate the send path).
  private let browsersLock = NSLock()
  private var browsers: [UInt32: CefWebSession] = [:]
  private var nextBrowserId: UInt32 = 1
  private var ready = false
  private var pendingCreates: [() -> Void] = []  // createBrowser closures queued until ready
  private var adhocHost = false  // host reported a mock-keychain (ad-hoc) build
  private var createEnqueued: Set<UInt32> = []  // browserIds whose create has been sent

  // Invoked (off the reader thread) when an ad-hoc host refuses to load a named
  // profile (no creds were written — see F.5). The plugin tears this host down
  // and respawns an ephemeral one for the same session.
  var onInsecureProfileRefused: (() -> Void)?

  init(profileId: String, profileDir: String, isEphemeral: Bool) {
    self.profileId = profileId
    self.profileDir = profileDir
    self.isEphemeral = isEphemeral
  }

  // MARK: Spawn

  /// Bind the Unix socket and launch cef_host for this profile. Argv always
  /// carries `--ipc` and `--profile-dir=<profileDir>`; `--cdp-port=<port>` is
  /// added only when `enableCdp` (port picked here). `--allowed-schemes` is a
  /// process arg shared by every browser in the profile — it's taken from the
  /// first browser that triggered this spawn. Returns false on failure.
  func spawn(cefHostPath: String, enableCdp: Bool, allowedSchemes: String) -> Bool {
    // Randomized name (not just the predictable profileId) in the per-user 0700
    // temp dir, so another same-UID process can't pre-bind it.
    let rnd = String(format: "%08x", UInt32.random(in: 0 ... UInt32.max))
    socketPath = NSTemporaryDirectory() + "wccef-\(sanitizedSocketTag())-\(rnd).sock"
    guard socketPath.utf8CString.count <= 104 else {
      NSLog("[cef] socket path exceeds sun_path (104); aborting")
      return false
    }
    unlink(socketPath)
    listenFd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listenFd >= 0 else { NSLog("[cef] socket() failed"); return false }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathC = socketPath.utf8CString
    withUnsafeMutablePointer(to: &addr.sun_path) { raw in
      raw.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
        pathC.withUnsafeBufferPointer { src in
          dst.update(from: src.baseAddress!, count: min(pathC.count, 104))
        }
      }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listenFd, $0, len) }
    }
    guard bound == 0 else { NSLog("[cef] bind() failed: \(errno)"); return false }
    listen(listenFd, 1)

    let p = Process()
    p.executableURL = URL(fileURLWithPath: cefHostPath)
    // Per-process args only: per-view geometry/url now ride opCreateBrowser. The
    // cache path is always the resolved --profile-dir (ephemeral = throwaway temp).
    var args = [
      "--ipc=\(socketPath)",
      "--profile-dir=\(profileDir)",
    ]
    if !allowedSchemes.isEmpty {
      args.append("--allowed-schemes=\(allowedSchemes)")
    }
    // Chrome DevTools Protocol (CDP): when enabled, pick a free 127.0.0.1 port
    // and pass it via --cdp-port; cef_host sets CefSettings.remote_debugging_port
    // and CEF binds it (localhost-only, M113+). UNAUTHENTICATED — any local client
    // that reaches the port fully drives the page — so this is opt-in, never on by
    // default, and rejected for named profiles (it could read the shared jar). The
    // port is reported back to Dart in the create() result.
    if enableCdp {
      let port = Self.pickFreeTcpPort()
      if port >= 1024 {
        cdpPort = port
        args.append("--cdp-port=\(port)")
      }
    }
    p.arguments = args
    do {
      try p.run()
      process = p
    } catch {
      NSLog("[cef] failed to spawn cef_host at \(cefHostPath): \(error)")
      return false
    }
    running = true
    readerStarted = true
    Thread.detachNewThread { [weak self] in self?.acceptAndRead() }
    return true
  }

  // MARK: Browser multiplexing

  /// Allocate a wire browserId for `session`, register it, and (if the host is
  /// ready) send the opCreateBrowser; otherwise queue it until opReady. Returns
  /// the assigned browserId. `allowedSchemes` is accepted for call-site symmetry
  /// but NOT used here — it's a process arg fixed at spawn (shared by every
  /// browser in the profile), not part of the opCreateBrowser payload (A.4).
  func createBrowser(_ session: CefWebSession, url: String, allowedSchemes: String) -> UInt32 {
    browsersLock.lock()
    let id = nextBrowserId
    nextBrowserId += 1
    browsers[id] = session
    browsersLock.unlock()
    session.attach(host: self, browserId: id)

    // opCreateBrowser payload: {u32 w}{u32 h}{f64 dpr}{u32 iosurfaceId}{utf8 url}.
    // allowedSchemes is NOT here — it's a process arg (see spawn).
    var payload = [UInt8]()
    appendU32(&payload, UInt32(session.w))
    appendU32(&payload, UInt32(session.h))
    appendF64(&payload, Double(session.scale))
    appendU32(&payload, session.surfaceId)
    payload.append(contentsOf: Array(url.utf8))

    writeLock.lock()
    let isReady = ready
    if !isReady {
      // Queue until opReady; the safety-rail (F.5) may refuse to flush these.
      pendingCreates.append { [weak self] in
        self?.sendCreate(id, payload)
      }
    }
    writeLock.unlock()
    if isReady { sendCreate(id, payload) }
    return id
  }

  /// Send an opCreateBrowser frame and mark the browserId as enqueued so its
  /// pre-connect resizes are no longer dropped.
  private func sendCreate(_ id: UInt32, _ payload: [UInt8]) {
    writeLock.lock()
    createEnqueued.insert(id)
    writeLock.unlock()
    send(id, Self.opCreateBrowser, payload)
  }

  /// Frame `[u32 bodyLen=4+1+payload.count][u32 browserId][op][payload]` and
  /// write it, or queue it if the pipe isn't up yet. A pre-connect opResize whose
  /// browserId hasn't had its create enqueued is DROPPED — that create carries
  /// the current geometry, so replaying the resize could reference a since-freed
  /// IOSurface id.
  func send(_ browserId: UInt32, _ op: UInt8, _ payload: [UInt8]) {
    let frame = frameBytes(browserId, op, payload)
    writeLock.lock()
    defer { writeLock.unlock() }
    if connFd < 0 {
      if op == Self.opResize && !createEnqueued.contains(browserId) { return }
      pendingFrames.append(frame)
      return
    }
    _ = frame.withUnsafeBytes { writeAll(connFd, $0.baseAddress!, frame.count) }
  }

  /// Whether this host currently has any registered browser. Used by the P1
  /// single-view-per-named-profile guard.
  var hasLiveBrowser: Bool {
    browsersLock.lock(); defer { browsersLock.unlock() }
    return !browsers.isEmpty
  }

  /// Close ONE browser (opDisposeBrowser) and unregister it under lock. Returns
  /// the number of browsers still registered on this host afterward.
  func removeBrowser(_ browserId: UInt32) -> Int {
    send(browserId, Self.opDisposeBrowser, [])
    browsersLock.lock()
    browsers[browserId] = nil
    let remaining = browsers.count
    browsersLock.unlock()
    writeLock.lock()
    createEnqueued.remove(browserId)
    writeLock.unlock()
    return remaining
  }

  // MARK: Teardown

  /// Tear down the WHOLE process: opShutdown(0), stop the reader thread (flag it,
  /// wake its blocking accept()/read() by shutting down the fds, wait for it to
  /// exit), close the fds, unlink the socket, drop an ephemeral profile dir, and
  /// terminate cef_host. Closing an fd a thread is blocked on, or freeing state
  /// under the reader, is a use-after-free — the join makes teardown deterministic.
  func shutdown() {
    send(0, Self.opShutdown, [])
    writeLock.lock()
    let wasRunning = running
    running = false
    let c = connFd, l = listenFd
    writeLock.unlock()
    // Darwin.shutdown — disambiguate from this class's own shutdown() method,
    // which Swift would otherwise resolve these unqualified calls to.
    if c >= 0 { Darwin.shutdown(c, SHUT_RDWR) }
    if l >= 0 { Darwin.shutdown(l, SHUT_RDWR) }
    if readerStarted && wasRunning { _ = readerDone.wait(timeout: .now() + 2) }
    writeLock.lock()
    if connFd >= 0 { close(connFd); connFd = -1 }
    if listenFd >= 0 { close(listenFd); listenFd = -1 }
    writeLock.unlock()
    if !socketPath.isEmpty { unlink(socketPath); socketPath = "" }
    if isEphemeral && !profileDir.isEmpty {
      try? FileManager.default.removeItem(atPath: profileDir)
    }
    terminateProcess()
  }

  private func terminateProcess() {
    guard let p = process else { return }
    process = nil
    p.terminate()  // SIGTERM
    // Escalate to SIGKILL if the host is wedged and ignores SIGTERM.
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
      if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }
  }

  deinit {
    // Minimal net for a partial-spawn failure (host dropped without shutdown()).
    // shutdown() zeroes the fds, so this is a no-op after a clean teardown.
    if process?.isRunning == true { process?.terminate() }
    if connFd >= 0 { close(connFd) }
    if listenFd >= 0 { close(listenFd) }
    if !socketPath.isEmpty { unlink(socketPath) }
  }

  // MARK: Subprocess + IPC

  /// Ask the OS for a free TCP port on 127.0.0.1 (bind :0, read it back, close).
  /// Brief TOCTOU window until cef_host's CEF binds it — acceptable on loopback.
  /// Returns 0 on failure.
  private static func pickFreeTcpPort() -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return 0 }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0 else { return 0 }
    var assigned = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let got = withUnsafeMutablePointer(to: &assigned) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(fd, $0, &len)
      }
    }
    guard got == 0 else { return 0 }
    return Int(UInt16(bigEndian: assigned.sin_port))
  }

  private func acceptAndRead() {
    defer { readerDone.signal() }  // let shutdown() join us on every exit path
    let fd = accept(listenFd, nil, nil)
    guard fd >= 0 else { NSLog("[cef] accept() failed"); return }
    // Bring the pipe up and drain anything queued before it connected — all under
    // writeLock so a concurrent send can't interleave with the flush. Unlike the
    // old per-view path, geometry is NOT re-synced here: each browser's
    // opCreateBrowser carries its current geometry, and pre-create resizes were
    // dropped in send(); the queued frames are early control ops + the creates
    // that fall through after opReady.
    writeLock.lock()
    connFd = fd
    for f in pendingFrames {
      _ = f.withUnsafeBytes { writeAll(fd, $0.baseAddress!, f.count) }
    }
    pendingFrames.removeAll()
    writeLock.unlock()
    while running {
      var hdr = [UInt8](repeating: 0, count: 4)
      if !readAll(fd, &hdr, 4) { break }
      let bodyLen = (Int(hdr[0]) << 24) | (Int(hdr[1]) << 16) | (Int(hdr[2]) << 8) | Int(hdr[3])
      // Minimum valid body is 5 bytes (4 browserId + 1 op + 0 payload).
      if bodyLen <= 4 || bodyLen > (64 << 20) { break }
      var body = [UInt8](repeating: 0, count: bodyLen)
      if !readAll(fd, &body, bodyLen) { break }
      let bid = beU32(body, 0)
      let op = body[4]
      let payload = Array(body[5...])  // empty slice when bodyLen == 5 (no payload)
      if bid == 0 {
        handleProcessFrame(op, payload)
      } else {
        browsersLock.lock()
        let session = browsers[bid]
        browsersLock.unlock()
        session?.handleFrame(op, payload)
      }
    }
  }

  /// Process/profile-level inbound frames (browserId 0): opReady (carries the
  /// ad-hoc build flag, gates the create flush) and process logs.
  private func handleProcessFrame(_ op: UInt8, _ payload: [UInt8]) {
    switch op {
    case Self.opReady:
      let flags = payload.first ?? 0
      let adhoc = (flags & 0x01) != 0
      // F.5 dev safety-rail: an ad-hoc (mock-keychain) host must NOT load a named
      // persistent profile unless explicitly allowed, because at-rest creds
      // wouldn't be protected. Nothing has been written yet (no browser was
      // created), so refusing here leaks nothing. The plugin respawns an
      // ephemeral host for the session and re-issues createBrowser.
      let allowInsecure =
        ProcessInfo.processInfo.environment["FLUTTER_CEF_ALLOW_INSECURE_PROFILE"] == "1"
      writeLock.lock()
      adhocHost = adhoc
      ready = true
      let refuse = adhoc && !isEphemeral && !allowInsecure
      let creates = refuse ? [] : pendingCreates
      pendingCreates.removeAll()
      writeLock.unlock()
      if refuse {
        NSLog("[cef] refusing persistent profile '\(profileId)' under an ad-hoc " +
              "(mock-keychain) cef_host build; downgrading to ephemeral. Set " +
              "FLUTTER_CEF_ALLOW_INSECURE_PROFILE=1 to override.")
        onInsecureProfileRefused?()
        return
      }
      for c in creates { c() }
    case Self.opLog:
      let msg = String(bytes: payload, encoding: .utf8) ?? ""
      NSLog("[cef_host:\(profileId)] \(msg)")
    default:
      break
    }
  }

  // MARK: Wire helpers

  // Length-prefixed wire frame: [u32 bodyLen][u32 browserId][op][payload], where
  // bodyLen = 4 + 1 + payload.count. Pure — no lock.
  private func frameBytes(_ browserId: UInt32, _ op: UInt8, _ payload: [UInt8]) -> [UInt8] {
    var frame = [UInt8]()
    frame.reserveCapacity(9 + payload.count)
    appendU32(&frame, UInt32(4 + 1 + payload.count))
    appendU32(&frame, browserId)
    frame.append(op)
    frame.append(contentsOf: payload)
    return frame
  }

  private func appendU32(_ a: inout [UInt8], _ v: UInt32) {
    a.append(UInt8((v >> 24) & 0xff))
    a.append(UInt8((v >> 16) & 0xff))
    a.append(UInt8((v >> 8) & 0xff))
    a.append(UInt8(v & 0xff))
  }

  private func appendF64(_ a: inout [UInt8], _ v: Double) {
    let bits = v.bitPattern
    for shift in stride(from: 56, through: 0, by: -8) {
      a.append(UInt8((bits >> UInt64(shift)) & 0xff))
    }
  }

  private func beU32(_ b: [UInt8], _ o: Int) -> UInt32 {
    return (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16)
      | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
  }

  // A filesystem-safe tag for the socket name derived from the profileId (which
  // for ephemeral hosts is "~ephemeral~"+sessionId — chars not in sun_path-safe
  // set get collapsed).
  private func sanitizedSocketTag() -> String {
    let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
    return String(profileId.map { allowed.contains($0) ? $0 : "_" })
  }

  private func readAll(_ fd: Int32, _ buf: inout [UInt8], _ len: Int) -> Bool {
    var off = 0
    while off < len {
      let n = buf.withUnsafeMutableBytes { ptr -> Int in
        read(fd, ptr.baseAddress!.advanced(by: off), len - off)
      }
      if n <= 0 { return false }
      off += n
    }
    return true
  }

  private func writeAll(_ fd: Int32, _ buf: UnsafeRawPointer, _ len: Int) -> Bool {
    var off = 0
    while off < len {
      let n = write(fd, buf.advanced(by: off), len - off)
      if n <= 0 { return false }
      off += n
    }
    return true
  }
}
