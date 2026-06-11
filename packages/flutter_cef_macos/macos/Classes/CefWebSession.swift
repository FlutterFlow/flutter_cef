// One live CEF webview, rendered off-screen by a cef_host.app subprocess into a
// shared IOSurface and surfaced to Flutter as a FlutterTexture.
//
// Mirrors the flutter_embed transport (macos/Runner/FlutterEmbed): the host
// allocates a global IOSurface + CVPixelBuffer, registers a FlutterTexture, and
// spawns the renderer with the IOSurface id + a Unix-socket path. cef_host paints
// the page into the IOSurface and sends a "present" frame; we then poke the
// engine to re-sample the texture. Because the page renders off-screen, it keeps
// updating even when the tile isn't engaged — the whole point of the CEF path.
//
// See native/cef_host/main.mm for the renderer and the IPC opcode definitions.

import Cocoa
import CoreVideo
import FlutterMacOS
import IOSurface

final class CefWebSession: NSObject, FlutterTexture {
  // IPC opcodes (must match native/cef_host/main.mm).
  private static let opPresent: UInt8 = 0x01
  private static let opReady: UInt8 = 0x02
  private static let opCursor: UInt8 = 0x03
  private static let opLog: UInt8 = 0x04
  private static let opLoadState: UInt8 = 0x05
  private static let opTitle: UInt8 = 0x06
  private static let opUrl: UInt8 = 0x07
  private static let opLoadErr: UInt8 = 0x08
  private static let opConsole: UInt8 = 0x09
  private static let opPageStart: UInt8 = 0x0a
  private static let opPageFinish: UInt8 = 0x0b
  private static let opProgress: UInt8 = 0x0c
  private static let opNewWindow: UInt8 = 0x0d
  private static let opPointer: UInt8 = 0x10
  private static let opResize: UInt8 = 0x11
  private static let opKey: UInt8 = 0x12
  private static let opShutdown: UInt8 = 0x14
  private static let opFindResult: UInt8 = 0x0e
  private static let opJsDialog: UInt8 = 0x0f
  private static let opEvalResult: UInt8 = 0x16
  private static let opChannelMsg: UInt8 = 0x17
  private static let opDownload: UInt8 = 0x18
  private static let opImeBounds: UInt8 = 0x19
  private static let opCookies: UInt8 = 0x1a
  private static let opNavigate: UInt8 = 0x20
  private static let opReload: UInt8 = 0x21
  private static let opStop: UInt8 = 0x22
  private static let opBack: UInt8 = 0x23
  private static let opForward: UInt8 = 0x24
  private static let opExecuteJs: UInt8 = 0x25
  private static let opSetZoom: UInt8 = 0x26
  private static let opFind: UInt8 = 0x27
  private static let opStopFind: UInt8 = 0x28
  private static let opJsDialogResp: UInt8 = 0x29
  private static let opEvalReturning: UInt8 = 0x2a
  private static let opAddChannel: UInt8 = 0x2b
  private static let opSetCookie: UInt8 = 0x2c
  private static let opClearCookies: UInt8 = 0x2d
  private static let opVisitCookies: UInt8 = 0x2e
  private static let opDeleteCookie: UInt8 = 0x2f
  private static let opImeSetComp: UInt8 = 0x30
  private static let opImeCommit: UInt8 = 0x31
  private static let opImeCancel: UInt8 = 0x32
  private static let opShowDevTools: UInt8 = 0x33
  private static let opLoadTrusted: UInt8 = 0x34
  private static let opSetVisible: UInt8 = 0x35

  // Event callbacks (fired off the main thread). The registrar relays each to a
  // Dart channel message.
  var onCursor: ((Int) -> Void)?
  var onLoadState: ((Bool, Bool, Bool) -> Void)?  // loading, back, forward
  var onTitle: ((String) -> Void)?
  var onUrl: ((String) -> Void)?
  var onLoadError: ((Int, String, String) -> Void)?  // code, url, text
  var onConsole: ((Int, String) -> Void)?  // level, "source:line\tmsg"
  var onPageStarted: ((String) -> Void)?  // url
  var onPageFinished: ((String) -> Void)?  // url
  var onProgress: ((Int) -> Void)?  // 0-100
  var onNewWindow: ((String) -> Void)?  // popup/target=_blank url
  var onFindResult: ((Int, Int, Bool) -> Void)?  // count, activeOrdinal, isFinal
  var onJsDialog: ((Int, Int, String, String) -> Void)?  // id, type, msg, default
  var onEvalResult: ((String) -> Void)?  // "id:json"
  var onChannelMsg: ((String) -> Void)?  // "name:message"
  var onDownload: ((String) -> Void)?  // suggested name
  var onImeBounds: ((Int, Int, Int, Int) -> Void)?  // caret rect x,y,w,h (DIP)
  var onCookies: ((Int, String) -> Void)?  // request id, json array

  let sessionId: String
  private(set) var textureId: Int64 = 0
  // The 127.0.0.1 port CEF's DevTools (CDP) server bound for this session, or 0
  // when CDP wasn't requested. Chosen here (free-port pick) and reported back to
  // Dart in the create() result.
  private(set) var cdpPort: Int = 0

  private weak var registry: FlutterTextureRegistry?
  private let cefHostPath: String
  private let allowedSchemes: String  // CSV; "" = allow all
  private let enableCdp: Bool
  private var width: Int
  private var height: Int
  private let dpr: CGFloat

  private var ioSurface: IOSurfaceRef?
  private var pixelBuffer: CVPixelBuffer?
  private let bufferLock = NSLock()

  private var process: Process?
  private var listenFd: Int32 = -1
  private var connFd: Int32 = -1
  private var socketPath = ""
  private let writeLock = NSLock()
  private var pendingFrames: [[UInt8]] = []  // queued until the pipe connects
  private var running = false
  private var readerStarted = false
  private let readerDone = DispatchSemaphore(value: 0)  // signaled when the
  // acceptAndRead thread exits, so dispose() can join it before freeing state.

  init(sessionId: String, url: String, width: Int, height: Int, dpr: CGFloat,
       allowedSchemes: String = "", enableCdp: Bool = false,
       registry: FlutterTextureRegistry, cefHostPath: String) {
    self.sessionId = sessionId
    self.width = max(1, width)
    self.height = max(1, height)
    self.dpr = dpr
    self.allowedSchemes = allowedSchemes
    self.enableCdp = enableCdp
    self.registry = registry
    self.cefHostPath = cefHostPath
    super.init()
    _ = allocateBuffers(self.width, self.height)
    self.textureId = registry.register(self)
    running = true
    setupSocketAndSpawn(url: url)
  }

  // MARK: FlutterTexture

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    bufferLock.lock()
    defer { bufferLock.unlock() }
    guard let pb = pixelBuffer else { return nil }
    return Unmanaged.passRetained(pb)
  }

  // MARK: Public control

  func resize(width newW: Int, height newH: Int) {
    let w = max(1, newW), h = max(1, newH)
    if w == width && h == height { return }
    guard allocateBuffers(w, h) else { return }
    width = w
    height = h
    guard let surf = ioSurface else { return }
    let sid = IOSurfaceGetID(surf)
    var payload = [UInt8]()
    appendU32(&payload, UInt32(w))
    appendU32(&payload, UInt32(h))
    appendU32(&payload, sid)
    sendFrame(Self.opResize, payload)
  }

  func navigate(_ url: String) {
    sendFrame(Self.opNavigate, Array(url.utf8))
  }

  /// A host content-injection load (loadHtmlString -> data:, loadFile -> file:):
  /// exempt from the navigation scheme allowlist, unlike `navigate`.
  func loadTrusted(_ url: String) {
    sendFrame(Self.opLoadTrusted, Array(url.utf8))
  }

  func reload() { sendFrame(Self.opReload) }
  func stopLoad() { sendFrame(Self.opStop) }
  func goBack() { sendFrame(Self.opBack) }
  func goForward() { sendFrame(Self.opForward) }
  func executeJavaScript(_ code: String) {
    sendFrame(Self.opExecuteJs, Array(code.utf8))
  }

  func setZoomLevel(_ level: Double) {
    var p = [UInt8]()
    appendF64(&p, level)
    sendFrame(Self.opSetZoom, p)
  }

  /// Pause/resume frame production in the cef_host subprocess. `false` calls
  /// CefBrowserHost::WasHidden(true) so an off-screen tile stops rendering; the
  /// session and browser stay alive, so it's a cheap toggle, not a teardown.
  func setVisible(_ visible: Bool) {
    sendFrame(Self.opSetVisible, [visible ? 1 : 0])
  }

  func find(_ text: String, forward: Bool, matchCase: Bool, findNext: Bool) {
    var p: [UInt8] = [forward ? 1 : 0, matchCase ? 1 : 0, findNext ? 1 : 0]
    p.append(contentsOf: Array(text.utf8))
    sendFrame(Self.opFind, p)
  }

  func stopFind(_ clearSelection: Bool) {
    sendFrame(Self.opStopFind, [clearSelection ? 1 : 0])
  }

  func respondJsDialog(id: Int, ok: Bool, text: String) {
    var p = [UInt8]()
    appendU32(&p, UInt32(truncatingIfNeeded: id))
    p.append(ok ? 1 : 0)
    p.append(contentsOf: Array(text.utf8))
    sendFrame(Self.opJsDialogResp, p)
  }

  func evalReturning(id: Int, code: String) {
    var p = [UInt8]()
    appendU32(&p, UInt32(truncatingIfNeeded: id))
    p.append(contentsOf: Array(code.utf8))
    sendFrame(Self.opEvalReturning, p)
  }

  func addChannel(_ name: String) {
    sendFrame(Self.opAddChannel, Array(name.utf8))
  }

  func setCookie(url: String, name: String, value: String, domain: String,
                 path: String) {
    let payload = [url, name, value, domain, path].joined(separator: "\u{0}")
    sendFrame(Self.opSetCookie, Array(payload.utf8))
  }

  func clearCookies() { sendFrame(Self.opClearCookies) }

  func visitCookies(id: Int, url: String) {
    var payload = [UInt8]()
    appendU32(&payload, UInt32(truncatingIfNeeded: id))
    payload.append(contentsOf: Array(url.utf8))
    sendFrame(Self.opVisitCookies, payload)
  }

  func deleteCookie(url: String, name: String) {
    sendFrame(Self.opDeleteCookie, Array((url + "\u{0}" + name).utf8))
  }

  func showDevTools() { sendFrame(Self.opShowDevTools) }

  func imeSetComposition(_ text: String) {
    sendFrame(Self.opImeSetComp, Array(text.utf8))
  }

  func imeCommitText(_ text: String) {
    sendFrame(Self.opImeCommit, Array(text.utf8))
  }

  func imeCancelComposition() { sendFrame(Self.opImeCancel) }

  // type: 0=move 1=down 2=up 3=wheel; button: 0=left 1=middle 2=right.
  func sendPointer(type: Int, button: Int, clickCount: Int, modifiers: UInt32,
                   x: Double, y: Double, dx: Double, dy: Double) {
    var p = [UInt8]()
    p.append(UInt8(truncatingIfNeeded: type))
    p.append(UInt8(truncatingIfNeeded: button))
    p.append(UInt8(truncatingIfNeeded: clickCount))
    p.append(0)
    appendU32(&p, modifiers)
    appendF64(&p, x); appendF64(&p, y); appendF64(&p, dx); appendF64(&p, dy)
    sendFrame(Self.opPointer, p)
  }

  // type: 0=rawkeydown 2=keyup 3=char.
  func sendKey(type: Int, modifiers: UInt32, windowsKeyCode: Int32,
               nativeKeyCode: Int32, character: UInt32) {
    var p = [UInt8]()
    p.append(UInt8(truncatingIfNeeded: type))
    p.append(0); p.append(0); p.append(0)
    appendU32(&p, modifiers)
    appendU32(&p, UInt32(bitPattern: windowsKeyCode))
    appendU32(&p, UInt32(bitPattern: nativeKeyCode))
    appendU32(&p, character)
    sendFrame(Self.opKey, p)
  }

  func dispose() {
    // Tell the host to quit (best-effort), then stop the reader thread *first*:
    // flag it, wake its blocking accept()/read() by shutting down the fds, and
    // wait for it to exit before freeing anything it touches. Closing an fd a
    // thread is blocked on, or freeing buffers/texture under the reader, is a
    // use-after-free — this join makes teardown deterministic.
    sendFrame(Self.opShutdown)
    writeLock.lock()
    let wasRunning = running
    running = false
    let c = connFd, l = listenFd
    writeLock.unlock()
    if c >= 0 { shutdown(c, SHUT_RDWR) }
    if l >= 0 { shutdown(l, SHUT_RDWR) }
    if readerStarted && wasRunning { _ = readerDone.wait(timeout: .now() + 2) }
    writeLock.lock()
    if connFd >= 0 { close(connFd); connFd = -1 }
    if listenFd >= 0 { close(listenFd); listenFd = -1 }
    writeLock.unlock()
    if !socketPath.isEmpty { unlink(socketPath); socketPath = "" }
    terminateProcess()
    if textureId != 0 { registry?.unregisterTexture(textureId); textureId = 0 }
    bufferLock.lock(); pixelBuffer = nil; ioSurface = nil; bufferLock.unlock()
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
    // Safety net if the session is dropped without dispose() (e.g. setup failed
    // partway). dispose() zeroes the fds, so this is a no-op after a clean dispose.
    if process?.isRunning == true { process?.terminate() }
    if connFd >= 0 { close(connFd) }
    if listenFd >= 0 { close(listenFd) }
    if !socketPath.isEmpty { unlink(socketPath) }
  }

  // MARK: Buffers

  private func allocateBuffers(_ w: Int, _ h: Int) -> Bool {
    // Allocate at PHYSICAL (Retina) resolution = logical * dpr, so the texture
    // is crisp on HiDPI displays; cef_host renders the OSR buffer at the same
    // scale (via GetScreenInfo.device_scale_factor). 64-byte-aligned stride keeps
    // the IOSurface Metal/CVPixelBuffer-compatible.
    let pw = max(1, Int((Double(w) * Double(dpr)).rounded()))
    let ph = max(1, Int((Double(h) * Double(dpr)).rounded()))
    let bytesPerRow = ((pw * 4) + 63) & ~63
    let props: [CFString: Any] = [
      kIOSurfaceWidth: pw,
      kIOSurfaceHeight: ph,
      kIOSurfaceBytesPerElement: 4,
      kIOSurfaceBytesPerRow: bytesPerRow,
      kIOSurfaceAllocSize: bytesPerRow * ph,
      kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA,
      "IOSurfaceIsGlobal" as CFString: true,  // resolvable cross-process by id
    ]
    guard let surf = IOSurfaceCreate(props as CFDictionary) else {
      NSLog("[cef] IOSurfaceCreate failed \(w)x\(h)")
      return false
    }
    var pbOut: Unmanaged<CVPixelBuffer>?
    let attrs: [CFString: Any] = [
      kCVPixelBufferMetalCompatibilityKey: true,
      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ]
    let rc = CVPixelBufferCreateWithIOSurface(
      kCFAllocatorDefault, surf, attrs as CFDictionary, &pbOut)
    guard rc == kCVReturnSuccess, let buffer = pbOut?.takeRetainedValue() else {
      NSLog("[cef] CVPixelBufferCreateWithIOSurface failed rc=\(rc)")
      return false
    }
    bufferLock.lock()
    ioSurface = surf
    pixelBuffer = buffer
    bufferLock.unlock()
    NSLog("[cef] allocated IOSurface id=\(IOSurfaceGetID(surf)) \(pw)x\(ph) (logical \(w)x\(h) @\(dpr)x) stride=\(bytesPerRow)")
    return true
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

  private func setupSocketAndSpawn(url: String) {
    // Randomized name (not just the predictable sequential sessionId) in the
    // per-user 0700 temp dir, so another same-UID process can't pre-bind it.
    let rnd = String(format: "%08x", UInt32.random(in: 0 ... UInt32.max))
    socketPath = NSTemporaryDirectory() + "wccef-\(sessionId)-\(rnd).sock"
    guard socketPath.utf8CString.count <= 104 else {
      NSLog("[cef] socket path exceeds sun_path (104); aborting")
      return
    }
    unlink(socketPath)
    listenFd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listenFd >= 0 else { NSLog("[cef] socket() failed"); return }
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
    guard bound == 0 else { NSLog("[cef] bind() failed: \(errno)"); return }
    listen(listenFd, 1)

    let surfaceId = ioSurface.map { IOSurfaceGetID($0) } ?? 0
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cefHostPath)
    var args = [
      "--url=\(url)",
      "--width=\(width)",
      "--height=\(height)",
      "--dpr=\(dpr)",
      "--iosurface-id=\(surfaceId)",
      "--ipc=\(socketPath)",
    ]
    if !allowedSchemes.isEmpty {
      args.append("--allowed-schemes=\(allowedSchemes)")
    }
    // Chrome DevTools Protocol (CDP): when enabled for this session, pick a free
    // 127.0.0.1 port and pass it via --cdp-port; cef_host sets
    // CefSettings.remote_debugging_port and CEF binds it (localhost-only, M113+).
    // UNAUTHENTICATED — any local client that reaches the port fully drives the
    // page — so this is opt-in, never on by default. The port is reported back
    // to Dart in the create() result.
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
      return
    }
    readerStarted = true
    Thread.detachNewThread { [weak self] in self?.acceptAndRead() }
  }

  private func acceptAndRead() {
    defer { readerDone.signal() }  // let dispose() join us on every exit path
    let fd = accept(listenFd, nil, nil)
    guard fd >= 0 else { NSLog("[cef] accept() failed"); return }
    // Bring the pipe up and drain anything queued before it connected — all under
    // writeLock so a concurrent sendFrame can't interleave with the flush.
    bufferLock.lock()
    let surf = ioSurface
    bufferLock.unlock()
    let w = width, h = height
    writeLock.lock()
    connFd = fd
    // 1. Re-sync geometry from the live surface. A resize() that fired before the
    //    pipe connected was intentionally dropped (replaying it could reference a
    //    since-freed / recycled IOSurface id); the current surface is always
    //    valid. Without this the view stays blank until a manual window resize.
    if let surf = surf {
      var p = [UInt8]()
      appendU32(&p, UInt32(w))
      appendU32(&p, UInt32(h))
      appendU32(&p, IOSurfaceGetID(surf))
      let frame = frameBytes(Self.opResize, p)
      _ = frame.withUnsafeBytes { writeAll(fd, $0.baseAddress!, frame.count) }
    }
    // 2. Flush queued non-resize frames (early navigate / executeJavaScript / …).
    for f in pendingFrames {
      _ = f.withUnsafeBytes { writeAll(fd, $0.baseAddress!, f.count) }
    }
    pendingFrames.removeAll()
    writeLock.unlock()
    while running {
      var hdr = [UInt8](repeating: 0, count: 4)
      if !readAll(fd, &hdr, 4) { break }
      let bodyLen = (Int(hdr[0]) << 24) | (Int(hdr[1]) << 16) | (Int(hdr[2]) << 8) | Int(hdr[3])
      if bodyLen <= 0 || bodyLen > (64 << 20) { break }
      var body = [UInt8](repeating: 0, count: bodyLen)
      if !readAll(fd, &body, bodyLen) { break }
      switch body[0] {
      case Self.opPresent:
        let tid = textureId
        if tid != 0 {
          DispatchQueue.main.async { [weak self] in
            self?.registry?.textureFrameAvailable(tid)
          }
        }
      case Self.opCursor:
        if body.count >= 5 {
          let c = (Int(body[1]) << 24) | (Int(body[2]) << 16)
            | (Int(body[3]) << 8) | Int(body[4])
          onCursor?(c)
        }
      case Self.opLog:
        let msg = String(bytes: body[1...], encoding: .utf8) ?? ""
        NSLog("[cef_host:\(sessionId)] \(msg)")
      case Self.opLoadState:
        if body.count >= 4 {
          onLoadState?(body[1] != 0, body[2] != 0, body[3] != 0)
        }
      case Self.opTitle:
        onTitle?(String(bytes: body[1...], encoding: .utf8) ?? "")
      case Self.opUrl:
        onUrl?(String(bytes: body[1...], encoding: .utf8) ?? "")
      case Self.opLoadErr:
        if body.count >= 5 {
          let code = readU32(body, 1)
          let s = String(bytes: body[5...], encoding: .utf8) ?? ""
          let parts = s.split(separator: "\n", maxSplits: 1,
                              omittingEmptySubsequences: false)
          onLoadError?(code, parts.count > 0 ? String(parts[0]) : "",
                       parts.count > 1 ? String(parts[1]) : "")
        }
      case Self.opConsole:
        if body.count >= 5 {
          onConsole?(readU32(body, 1),
                     String(bytes: body[5...], encoding: .utf8) ?? "")
        }
      case Self.opPageStart:
        onPageStarted?(String(bytes: body[1...], encoding: .utf8) ?? "")
      case Self.opPageFinish:
        onPageFinished?(String(bytes: body[1...], encoding: .utf8) ?? "")
      case Self.opProgress:
        if body.count >= 5 { onProgress?(readU32(body, 1)) }
      case Self.opNewWindow:
        onNewWindow?(String(bytes: body[1...], encoding: .utf8) ?? "")
      case Self.opFindResult:
        if body.count >= 10 {
          onFindResult?(readU32(body, 1), readU32(body, 5), body[9] != 0)
        }
      case Self.opJsDialog:
        if body.count >= 13 {
          let type = readU32(body, 5)
          let msgLen = readU32(body, 9)
          let msgEnd = min(13 + msgLen, body.count)
          let msg = String(bytes: body[13..<msgEnd], encoding: .utf8) ?? ""
          let def = msgEnd < body.count
              ? (String(bytes: body[msgEnd...], encoding: .utf8) ?? "")
              : ""
          onJsDialog?(readU32(body, 1), type, msg, def)
        }
      case Self.opEvalResult:
        onEvalResult?(String(bytes: body[1...], encoding: .utf8) ?? "")
      case Self.opChannelMsg:
        onChannelMsg?(String(bytes: body[1...], encoding: .utf8) ?? "")
      case Self.opDownload:
        onDownload?(String(bytes: body[1...], encoding: .utf8) ?? "")
      case Self.opImeBounds:
        if body.count >= 17 {
          onImeBounds?(readU32(body, 1), readU32(body, 5),
                       readU32(body, 9), readU32(body, 13))
        }
      case Self.opCookies:
        if body.count >= 5 {
          onCookies?(readU32(body, 1),
                     String(bytes: body[5...], encoding: .utf8) ?? "[]")
        }
      default:
        break
      }
    }
  }

  // MARK: Wire helpers

  // Length-prefixed wire frame: [u32 bodyLen][op][payload]. Pure — no lock.
  private func frameBytes(_ op: UInt8, _ payload: [UInt8]) -> [UInt8] {
    var frame = [UInt8]()
    frame.reserveCapacity(5 + payload.count)
    appendU32(&frame, UInt32(1 + payload.count))
    frame.append(op)
    frame.append(contentsOf: payload)
    return frame
  }

  private func sendFrame(_ op: UInt8, _ payload: [UInt8] = []) {
    let frame = frameBytes(op, payload)
    writeLock.lock()
    defer { writeLock.unlock() }
    if connFd < 0 {
      // Pipe not up yet. A pre-connect resize is re-synced from live geometry on
      // connect (see acceptAndRead), so dropping it is correct — and avoids
      // replaying a since-freed/recycled IOSurface id. Queue everything else
      // (early navigate / executeJavaScript / …) so it isn't silently lost.
      if op != Self.opResize { pendingFrames.append(frame) }
      return
    }
    _ = frame.withUnsafeBytes { writeAll(connFd, $0.baseAddress!, frame.count) }
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

  private func readU32(_ b: [UInt8], _ o: Int) -> Int {
    return (Int(b[o]) << 24) | (Int(b[o + 1]) << 16) | (Int(b[o + 2]) << 8)
      | Int(b[o + 3])
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
