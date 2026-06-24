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
  private static let opLog: UInt8 = 0x04
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
  private static let opInvalidate: UInt8 = 0x37  // us -> cef_host: force a repaint (re-kick a stuck resize)
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
  // JS-channel names registered for this session. Buffered here so a registration
  // that arrives BEFORE attach() assigns the wire browserId — which happens on a
  // shared host, where createBrowser is queued (pendingCreates) — is flushed with
  // a VALID browserId once attached (and re-sent on a re-home to a new host).
  // Without this the addChannel op would go out with browserId=0 and the host
  // couldn't bind it to this browser, so the window.<name> shim was never injected.
  private var channels: Set<String> = []
  // C1: set once when this browser delivers its first present frame. Owned/guarded by
  // CefProfileHost under its browsersLock (the reader flips it there) — a cheap per-frame
  // first-paint check that avoids a second lock on the hot paint path.
  var firstPresentSeen = false

  private weak var registry: FlutterTextureRegistry?
  private var width: Int
  private var height: Int
  private let dpr: CGFloat

  private var ioSurface: IOSurfaceRef?
  private var pixelBuffer: CVPixelBuffer?
  // Resize-flash fix: on resize we point cef_host at a fresh (zero-filled) surface but
  // keep SERVING the old `pixelBuffer` to Flutter until cef_host has actually painted
  // the new one — otherwise Flutter composites the blank surface for the frames before
  // the async cross-process repaint lands. `pendingBuffer` is the new buffer, promoted
  // to `pixelBuffer` in handleFrame(opPresent) when a present arrives tagged with
  // `pendingSurfaceId` (the new surface's id). All under bufferLock.
  private var pendingBuffer: CVPixelBuffer?
  private var pendingSurfaceId: UInt32 = 0
  // Resize flow-control: keep at most ONE resize in flight (sent, not yet promoted by its
  // present). cef_host coalesces rapid resizes and only paints the latest, so sending at the
  // full drag rate left every present tagged with an already-superseded surface id → the
  // texture promoted only at drag pauses (~1-2s). Instead send one resize, wait for its
  // present, then send the latest size requested since — so every paint promotes and the page
  // reflows at cef_host's actual rate. All guarded by bufferLock.
  private var resizeInFlight = false
  private var pendingRequestedW = 0
  private var pendingRequestedH = 0
  private var resizeSentAtNs: UInt64 = 0
  // Bumped on every sendResize. The resize watchdog captures it and bails if a newer resize
  // has since gone out — so during a smoothly-advancing drag the watchdog is a no-op, and it
  // only acts when a resize wedges (generation stops advancing because no present came).
  private var resizeGen: UInt64 = 0
  private let bufferLock = NSLock()

  /// The live IOSurface id this session's buffer is backed by, or 0 before
  /// allocation. The host reads this to build the opCreateBrowser payload.
  var surfaceId: UInt32 {
    bufferLock.lock(); defer { bufferLock.unlock() }
    return ioSurface.map { IOSurfaceGetID($0) } ?? 0
  }
  // Geometry, exposed for the host's opCreateBrowser payload. width/height are
  // mutated by resize() on the main thread and read by the host on its reader
  // thread, so guard them with bufferLock (dpr is immutable, so scale needn't).
  var w: Int { bufferLock.lock(); defer { bufferLock.unlock() }; return width }
  var h: Int { bufferLock.lock(); defer { bufferLock.unlock() }; return height }
  var scale: CGFloat { dpr }

  init(sessionId: String, width: Int, height: Int, dpr: CGFloat,
       registry: FlutterTextureRegistry) {
    self.sessionId = sessionId
    self.width = max(1, width)
    self.height = max(1, height)
    self.dpr = dpr
    self.registry = registry
    super.init()
    if let (surf, buffer) = makeBuffers(self.width, self.height) {
      publishBuffers(surf, buffer, self.width, self.height)
    }
    self.textureId = registry.register(self)
  }

  /// Bind this session to its host + wire browserId (called by
  /// CefProfileHost.createBrowser). All sendFrame calls route through the host
  /// after this.
  func attach(host: CefProfileHost, browserId: UInt32) {
    self.host = host
    self.browserId = browserId
    // Flush channels registered before the wire id existed (and re-send them on a
    // re-home to a new host) now that sendFrame can route with a valid browserId.
    for name in channels { sendFrame(Self.opAddChannel, Array(name.utf8)) }
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
    bufferLock.lock()
    // Always record the latest requested size; it's what maybeSendNextResize sends when the
    // in-flight resize promotes.
    pendingRequestedW = w
    pendingRequestedH = h
    let blocked = resizeInFlight
    let same = (w == width && h == height)
    bufferLock.unlock()
    // While a resize is still painting, just record the latest size (above). Its present sends
    // the next one (maybeSendNextResize); if cef_host drops that paint, the resizeWatchdog
    // re-kicks it. This one-in-flight pacing keeps the page reflowing at cef_host's actual rate
    // instead of racing ahead (which tagged every present with an already-superseded surface id
    // → froze mid-drag). NOTE: no inline timeout here — racing ahead on a slow/heavy page is
    // exactly what desynced the presents and left the page stuck; the watchdog handles wedges.
    if blocked || same { return }
    sendResize(w, h)
  }

  /// Allocate the new surface, point cef_host at it, and send the resize — marking it
  /// in-flight so the next size waits for this one's present (see resize()/maybeSendNextResize).
  /// Only ever called on the main thread (resize / maybeSendNextResize), so sendFrame stays
  /// serialized.
  private func sendResize(_ w: Int, _ h: Int) {
    // Create the new surface OUTSIDE the lock (expensive). H4: publish surface id + new
    // dims ATOMICALLY in one bufferLock section so a concurrent host read (createSnapshot
    // on the reader thread) can't see new dims with the old surface id.
    guard let (surf, buffer) = makeBuffers(w, h) else { return }
    let sid = IOSurfaceGetID(surf)
    guard sid != 0 else { return }
    // Resize-flash fix: point the host at the NEW surface (ioSurface drives surfaceId /
    // createSnapshot → cef_host paints into it) and adopt the new dims, but DON'T swap
    // the live `pixelBuffer` — keep serving the OLD surface to Flutter (the old
    // CVPixelBuffer retains its IOSurface, so it stays valid) until cef_host paints the
    // new one. The new buffer is promoted in handleFrame(opPresent) on the matching present.
    bufferLock.lock()
    ioSurface = surf
    pendingBuffer = buffer
    pendingSurfaceId = sid
    width = w
    height = h
    resizeInFlight = true
    resizeSentAtNs = nowNs()
    resizeGen &+= 1
    let gen = resizeGen
    bufferLock.unlock()
    var payload = [UInt8]()
    appendU32(&payload, UInt32(w))
    appendU32(&payload, UInt32(h))
    appendU32(&payload, sid)
    sendFrame(Self.opResize, payload)
    // Re-kick this resize if its present never lands (see resizeWatchdog). During a smoothly
    // advancing drag gen keeps moving and this no-ops; it only bites a genuine wedge.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
      self?.resizeWatchdog(gen)
    }
  }

  /// Re-kick a wedged resize. Bails immediately if a newer resize has gone out (gen advanced)
  /// or this one already promoted (not in flight). Otherwise the post-resize present never
  /// matched — nudge cef_host to repaint the pending surface (opInvalidate), retrying every
  /// ~80ms. After ~0.3s of failed re-kicks, FORCE-promote the pending surface: cef_host's
  /// begin-frame pump has been painting into it the whole time, so it holds the correct new-size
  /// content — a single dropped/mis-tagged present (the failure mode on a STATIC page like
  /// flutter.dev, which produces exactly one frame per resize) can't leave the tile wedged.
  /// Main-thread only, so sendFrame / textureFrameAvailable stay serialized.
  private func resizeWatchdog(_ gen: UInt64) {
    bufferLock.lock()
    let active = resizeInFlight && gen == resizeGen
    let givenUp = active && (nowNs() &- resizeSentAtNs) > 300_000_000
    var promotedTid: Int64 = 0
    if givenUp {
      if let pending = pendingBuffer {
        pixelBuffer = pending
        pendingBuffer = nil
        pendingSurfaceId = 0
        promotedTid = textureId
      }
      resizeInFlight = false
    }
    bufferLock.unlock()
    if givenUp {
      if promotedTid != 0 { registry?.textureFrameAvailable(promotedTid) }
      maybeSendNextResize()
      return
    }
    guard active else { return }
    sendFrame(Self.opInvalidate, [])
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
      self?.resizeWatchdog(gen)
    }
  }

  /// Main-thread follow-up after a present promotes: if the page was resized again while the
  /// last resize painted, send the newest size now so the reflow keeps pace with the drag.
  private func maybeSendNextResize() {
    bufferLock.lock()
    let w = pendingRequestedW, h = pendingRequestedH
    let need = !resizeInFlight && w > 0 && (w != width || h != height)
    bufferLock.unlock()
    if need { sendResize(w, h) }
  }

  private func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

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
    channels.insert(name)
    // Ship now only if we already have a wire id; otherwise attach() flushes it.
    if browserId != 0 { sendFrame(Self.opAddChannel, Array(name.utf8)) }
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
    // Zero textureId under bufferLock so a reader-thread opPresent can't read it
    // torn or schedule a frame for an id we're about to unregister (it re-reads
    // under the lock on main). unregisterTexture itself runs on the main thread.
    bufferLock.lock()
    let tid = textureId
    textureId = 0
    pixelBuffer = nil
    ioSurface = nil
    pendingBuffer = nil  // drop any un-promoted resized surface
    pendingSurfaceId = 0
    resizeInFlight = false
    pendingRequestedW = 0
    pendingRequestedH = 0
    bufferLock.unlock()
    if tid != 0 { registry?.unregisterTexture(tid) }
  }

  // MARK: Buffers

  /// H4: CREATE an IOSurface + CVPixelBuffer for (w,h) but do NOT publish them — the
  /// caller publishes surface + geometry atomically via publishBuffers so a concurrent
  /// createSnapshot()/copyPixelBuffer never sees a surface and dims out of sync.
  private func makeBuffers(_ w: Int, _ h: Int) -> (IOSurfaceRef, CVPixelBuffer)? {
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
      return nil
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
      return nil
    }
    // NOTE: no success log here — makeBuffers runs once PER resize step (~60/s during a drag),
    // and a synchronous NSLog on that hot path measurably hurts resize smoothness.
    return (surf, buffer)
  }

  /// H4: publish a new (surface, buffer, width, height) as ONE atomic update, so a
  /// concurrent createSnapshot()/copyPixelBuffer never observes the new surface with
  /// the old dims (or vice-versa). Returns the new surface id. The old IOSurface/
  /// CVPixelBuffer are released by the overwrite.
  @discardableResult
  private func publishBuffers(_ surf: IOSurfaceRef, _ buffer: CVPixelBuffer,
                              _ w: Int, _ h: Int) -> UInt32 {
    bufferLock.lock(); defer { bufferLock.unlock() }
    ioSurface = surf
    pixelBuffer = buffer
    width = w
    height = h
    return IOSurfaceGetID(surf)
  }

  /// H4: read (w, h, dpr, surfaceId) as ONE consistent tuple under a single bufferLock
  /// acquisition — the host builds opCreateBrowser from this so its payload can't
  /// capture a torn mix of stale dims + a freshly-reallocated surface id.
  func createSnapshot() -> (w: Int, h: Int, dpr: CGFloat, sid: UInt32) {
    bufferLock.lock(); defer { bufferLock.unlock() }
    return (width, height, dpr, ioSurface.map { IOSurfaceGetID($0) } ?? 0)
  }

  // MARK: Inbound frames

  /// Handle one inbound frame routed to this browser by the host. `payload` has
  /// already had the [bodyLen][browserId][op] header stripped, so all offsets
  /// start at 0 (the old per-view switch read from offset 1, after the op byte).
  func handleFrame(_ op: UInt8, _ payload: [UInt8]) {
    switch op {
    case Self.opPresent:
      // Read textureId under bufferLock — dispose() writes it under the same
      // lock on the main thread, so this avoids a data race on the Int64.
      bufferLock.lock()
      // Resize-flash fix: the present is tagged with the surface id cef_host painted
      // (BE u32). If it's our pending (resized) surface, promote it to live now — we
      // kept serving the old surface until this exact frame so Flutter never sampled the
      // blank new one. A present for the old/current surface just advances the frame.
      if payload.count >= 4 {
        let psid = (UInt32(payload[0]) << 24) | (UInt32(payload[1]) << 16)
          | (UInt32(payload[2]) << 8) | UInt32(payload[3])
        if let pending = pendingBuffer, psid != 0, psid == pendingSurfaceId {
          pixelBuffer = pending
          pendingBuffer = nil
          pendingSurfaceId = 0
          resizeInFlight = false  // its paint landed; free to send the next size
        }
      }
      let tid = textureId
      bufferLock.unlock()
      if tid != 0 {
        DispatchQueue.main.async { [weak self] in
          // Re-read on main (serialized with dispose()): the texture may have
          // been unregistered between the reader capturing tid and here, so
          // don't poke a stale id into the registry.
          guard let self = self else { return }
          self.bufferLock.lock()
          let live = self.textureId
          self.bufferLock.unlock()
          if live != 0 { self.registry?.textureFrameAvailable(live) }
          // A resize may have promoted above — send the newest requested size now so the
          // reflow advances at cef_host's paint rate (on main, so sendFrame stays serialized).
          self.maybeSendNextResize()
        }
      }
    case Self.opLog:
      // Per-browser diagnostic from cef_host (paint/renderer/resize/etc.). Surface
      // it with this session's context (process-level logs go via the host).
      NSLog("[cef_host:\(sessionId)] \(String(bytes: payload, encoding: .utf8) ?? "")")
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
