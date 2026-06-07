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
// See packages/cef_host/ for the renderer and the IPC opcode definitions.

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
  private static let opPointer: UInt8 = 0x10
  private static let opResize: UInt8 = 0x11
  private static let opKey: UInt8 = 0x12
  private static let opShutdown: UInt8 = 0x14
  private static let opNavigate: UInt8 = 0x20
  private static let opReload: UInt8 = 0x21
  private static let opStop: UInt8 = 0x22
  private static let opBack: UInt8 = 0x23
  private static let opForward: UInt8 = 0x24
  private static let opExecuteJs: UInt8 = 0x25

  // Event callbacks (fired off the main thread). The registrar relays each to a
  // Dart channel message.
  var onCursor: ((Int) -> Void)?
  var onLoadState: ((Bool, Bool, Bool) -> Void)?  // loading, back, forward
  var onTitle: ((String) -> Void)?
  var onUrl: ((String) -> Void)?
  var onLoadError: ((Int, String, String) -> Void)?  // code, url, text
  var onConsole: ((Int, String) -> Void)?  // level, "source:line\tmsg"

  let sessionId: String
  private(set) var textureId: Int64 = 0

  private weak var registry: FlutterTextureRegistry?
  private let cefHostPath: String
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
  private var running = false

  init(sessionId: String, url: String, width: Int, height: Int, dpr: CGFloat,
       registry: FlutterTextureRegistry, cefHostPath: String) {
    self.sessionId = sessionId
    self.width = max(1, width)
    self.height = max(1, height)
    self.dpr = dpr
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

  func reload() { sendFrame(Self.opReload) }
  func stopLoad() { sendFrame(Self.opStop) }
  func goBack() { sendFrame(Self.opBack) }
  func goForward() { sendFrame(Self.opForward) }
  func executeJavaScript(_ code: String) {
    sendFrame(Self.opExecuteJs, Array(code.utf8))
  }

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
    running = false
    sendFrame(Self.opShutdown)
    if connFd >= 0 { shutdown(connFd, SHUT_RDWR); close(connFd); connFd = -1 }
    if listenFd >= 0 { close(listenFd); listenFd = -1 }
    if !socketPath.isEmpty { unlink(socketPath) }
    process?.terminate()
    process = nil
    if textureId != 0 { registry?.unregisterTexture(textureId); textureId = 0 }
    bufferLock.lock(); pixelBuffer = nil; ioSurface = nil; bufferLock.unlock()
  }

  // MARK: Buffers

  private func allocateBuffers(_ w: Int, _ h: Int) -> Bool {
    // 64-byte-aligned stride so the IOSurface is compatible with the Metal /
    // CVPixelBuffer the FlutterTexture samples. cef_host copies row-by-row using
    // IOSurfaceGetBytesPerRow, so a padded stride is fine on the renderer side.
    let bytesPerRow = ((w * 4) + 63) & ~63
    let props: [CFString: Any] = [
      kIOSurfaceWidth: w,
      kIOSurfaceHeight: h,
      kIOSurfaceBytesPerElement: 4,
      kIOSurfaceBytesPerRow: bytesPerRow,
      kIOSurfaceAllocSize: bytesPerRow * h,
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
    NSLog("[cef] allocated IOSurface id=\(IOSurfaceGetID(surf)) \(w)x\(h) stride=\(bytesPerRow)")
    return true
  }

  // MARK: Subprocess + IPC

  private func setupSocketAndSpawn(url: String) {
    socketPath = NSTemporaryDirectory() + "wccef-\(sessionId).sock"
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
    p.arguments = [
      "--url=\(url)",
      "--width=\(width)",
      "--height=\(height)",
      "--iosurface-id=\(surfaceId)",
      "--ipc=\(socketPath)",
    ]
    do {
      try p.run()
      process = p
    } catch {
      NSLog("[cef] failed to spawn cef_host at \(cefHostPath): \(error)")
      return
    }
    Thread.detachNewThread { [weak self] in self?.acceptAndRead() }
  }

  private func acceptAndRead() {
    let fd = accept(listenFd, nil, nil)
    guard fd >= 0 else { NSLog("[cef] accept() failed"); return }
    connFd = fd
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
      default:
        break
      }
    }
  }

  // MARK: Wire helpers

  private func sendFrame(_ op: UInt8, _ payload: [UInt8] = []) {
    writeLock.lock()
    defer { writeLock.unlock() }
    guard connFd >= 0 else { return }
    let bodyLen = 1 + payload.count
    var frame = [UInt8]()
    frame.reserveCapacity(4 + bodyLen)
    appendU32(&frame, UInt32(bodyLen))
    frame.append(op)
    frame.append(contentsOf: payload)
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
