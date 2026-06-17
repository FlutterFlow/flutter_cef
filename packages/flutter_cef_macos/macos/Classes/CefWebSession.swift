// One live CEF webview, rendered off-screen by a cef_host.app subprocess into a
// shared IOSurface and surfaced to Flutter as a FlutterTexture.
//
// Mirrors the flutter_embed transport (macos/Runner/FlutterEmbed): the host
// allocates a global IOSurface + CVPixelBuffer, registers a FlutterTexture, and
// the owning CefProfileHost tells cef_host (via opCreateBrowser) to bind a
// browser to that IOSurface id. cef_host paints the page into the IOSurface and
// sends a "present" frame; we then poke the engine to re-sample the texture.
// Because the page renders off-screen, it keeps updating even when the tile isn't
// engaged — the whole point of the CEF path.
//
// This is just the per-VIEW half: a session owns its texture/IOSurface/geometry
// and the per-view verbs. The process/socket/reader layer (one subprocess per
// `profile:`, multiplexing N of these by browserId) lives on CefProfileHost.
// sendFrame delegates to host.send(browserId, ...); the host routes inbound
// frames back via handleFrame(). See native/cef_host/main.mm for the renderer and
// the IPC opcode definitions.

import Cocoa
import CoreVideo
import FlutterMacOS
import IOSurface

final class CefWebSession: NSObject, FlutterTexture {
  // IPC opcodes (must match native/cef_host/main.mm). Process-level + control
  // ops (ready/log/create/dispose/shutdown) live on CefProfileHost; this list is
  // the per-view ops a session names directly.
  private static let opPresent: UInt8 = 0x01
  private static let opCursor: UInt8 = 0x03
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

  // Wire binding to the owning host: the host this session is multiplexed on and
  // the Swift-assigned browserId it routes by. Set once via attach() right after
  // CefProfileHost.createBrowser() allocates the id.
  private weak var host: CefProfileHost?
  private(set) var browserId: UInt32 = 0

  private weak var registry: FlutterTextureRegistry?
  private var width: Int
  private var height: Int
  private let dpr: CGFloat

  private var ioSurface: IOSurfaceRef?
  private var pixelBuffer: CVPixelBuffer?
  private let bufferLock = NSLock()

  /// The live IOSurface id this session's buffer is backed by, or 0 before
  /// allocation. The host reads this to build the opCreateBrowser payload.
  var surfaceId: UInt32 {
    bufferLock.lock(); defer { bufferLock.unlock() }
    return ioSurface.map { IOSurfaceGetID($0) } ?? 0
  }
  // Geometry, exposed for the host's opCreateBrowser payload.
  var w: Int { width }
  var h: Int { height }
  var scale: CGFloat { dpr }

  init(sessionId: String, width: Int, height: Int, dpr: CGFloat,
       registry: FlutterTextureRegistry) {
    self.sessionId = sessionId
    self.width = max(1, width)
    self.height = max(1, height)
    self.dpr = dpr
    self.registry = registry
    super.init()
    _ = allocateBuffers(self.width, self.height)
    self.textureId = registry.register(self)
  }

  /// Bind this session to its host + wire browserId (called by
  /// CefProfileHost.createBrowser). All sendFrame calls route through the host
  /// after this.
  func attach(host: CefProfileHost, browserId: UInt32) {
    self.host = host
    self.browserId = browserId
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

  /// Release the texture + buffers. The process/socket teardown (and the
  /// opDisposeBrowser/opShutdown signalling + reader join) is the owning
  /// CefProfileHost's job — by the time this runs the host has already
  /// unregistered this browser, so there's no reader racing the free.
  func dispose() {
    if textureId != 0 { registry?.unregisterTexture(textureId); textureId = 0 }
    bufferLock.lock(); pixelBuffer = nil; ioSurface = nil; bufferLock.unlock()
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

  // MARK: Inbound frames

  /// Handle one inbound frame routed to this browser by the host. `payload` has
  /// already had the [bodyLen][browserId][op] header stripped, so all offsets
  /// start at 0 (the old per-view switch read from offset 1, after the op byte).
  func handleFrame(_ op: UInt8, _ payload: [UInt8]) {
    switch op {
    case Self.opPresent:
      let tid = textureId
      if tid != 0 {
        DispatchQueue.main.async { [weak self] in
          self?.registry?.textureFrameAvailable(tid)
        }
      }
    case Self.opCursor:
      if payload.count >= 4 {
        let c = (Int(payload[0]) << 24) | (Int(payload[1]) << 16)
          | (Int(payload[2]) << 8) | Int(payload[3])
        onCursor?(c)
      }
    case Self.opLoadState:
      if payload.count >= 3 {
        onLoadState?(payload[0] != 0, payload[1] != 0, payload[2] != 0)
      }
    case Self.opTitle:
      onTitle?(String(bytes: payload, encoding: .utf8) ?? "")
    case Self.opUrl:
      onUrl?(String(bytes: payload, encoding: .utf8) ?? "")
    case Self.opLoadErr:
      if payload.count >= 4 {
        let code = readU32(payload, 0)
        let s = String(bytes: payload[4...], encoding: .utf8) ?? ""
        let parts = s.split(separator: "\n", maxSplits: 1,
                            omittingEmptySubsequences: false)
        onLoadError?(code, parts.count > 0 ? String(parts[0]) : "",
                     parts.count > 1 ? String(parts[1]) : "")
      }
    case Self.opConsole:
      if payload.count >= 4 {
        onConsole?(readU32(payload, 0),
                   String(bytes: payload[4...], encoding: .utf8) ?? "")
      }
    case Self.opPageStart:
      onPageStarted?(String(bytes: payload, encoding: .utf8) ?? "")
    case Self.opPageFinish:
      onPageFinished?(String(bytes: payload, encoding: .utf8) ?? "")
    case Self.opProgress:
      if payload.count >= 4 { onProgress?(readU32(payload, 0)) }
    case Self.opNewWindow:
      onNewWindow?(String(bytes: payload, encoding: .utf8) ?? "")
    case Self.opFindResult:
      if payload.count >= 9 {
        onFindResult?(readU32(payload, 0), readU32(payload, 4), payload[8] != 0)
      }
    case Self.opJsDialog:
      if payload.count >= 12 {
        let type = readU32(payload, 4)
        let msgLen = readU32(payload, 8)
        let msgEnd = min(12 + msgLen, payload.count)
        let msg = String(bytes: payload[12..<msgEnd], encoding: .utf8) ?? ""
        let def = msgEnd < payload.count
            ? (String(bytes: payload[msgEnd...], encoding: .utf8) ?? "")
            : ""
        onJsDialog?(readU32(payload, 0), type, msg, def)
      }
    case Self.opEvalResult:
      onEvalResult?(String(bytes: payload, encoding: .utf8) ?? "")
    case Self.opChannelMsg:
      onChannelMsg?(String(bytes: payload, encoding: .utf8) ?? "")
    case Self.opDownload:
      onDownload?(String(bytes: payload, encoding: .utf8) ?? "")
    case Self.opImeBounds:
      if payload.count >= 16 {
        onImeBounds?(readU32(payload, 0), readU32(payload, 4),
                     readU32(payload, 8), readU32(payload, 12))
      }
    case Self.opCookies:
      if payload.count >= 4 {
        onCookies?(readU32(payload, 0),
                   String(bytes: payload[4...], encoding: .utf8) ?? "[]")
      }
    default:
      break
    }
  }

  // MARK: Wire helpers

  /// Send a per-view frame: delegates to the owning host, which prepends the
  /// browserId and length and routes it over the shared pipe.
  private func sendFrame(_ op: UInt8, _ payload: [UInt8] = []) {
    host?.send(browserId, op, payload)
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
}
