import Cocoa
import FlutterMacOS

/// macOS plugin entry point. Channel `flutter_cef`. The host->native verbs (the
/// `case` labels in `handle(_:result:)`) and the native->Dart events (the
/// `emit(...)` calls in `create`) together form the cross-platform method-channel
/// protocol — see PORTING.md for the authoritative list. Each verb carries a
/// `sessionId`; `create` returns `{textureId, width, height, cdpPort}`. The Swift
/// side only relays: it spawns and talks to a per-PROFILE `cef_host` subprocess
/// (see `CefProfileHost`), which multiplexes N per-view `CefWebSession` browsers
/// over one IPC pipe. Views sharing a non-empty `profile` share one host -> one
/// cookie jar -> one login.
public class FlutterCefPlugin: NSObject, FlutterPlugin {
  private weak var textureRegistry: FlutterTextureRegistry?
  private var channel: FlutterMethodChannel?
  // Two-level registry: one host per profile, many sessions per host.
  private var profiles: [String: CefProfileHost] = [:]   // key: profile name OR "~ephemeral~"+sessionId
  private var sessions: [String: CefWebSession] = [:]     // sessionId -> session (verb routing)
  private var sessionHost: [String: CefProfileHost] = [:] // sessionId -> its host
  private var sessionKey: [String: String] = [:]          // sessionId -> profiles[] key, for teardown

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = FlutterCefPlugin()
    instance.textureRegistry = registrar.textures
    let channel = FlutterMethodChannel(
      name: "flutter_cef", binaryMessenger: registrar.messenger)
    instance.channel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "create": create(args, result)
    case "navigate": navigate(args, result)
    case "loadTrusted": loadTrusted(args, result)
    case "resize": resize(args, result)
    case "dispose": destroy(args, result)
    case "pointer": pointer(args, result)
    case "key": key(args, result)
    case "reload": withSession(args) { $0.reload() }; result(nil)
    case "stop": withSession(args) { $0.stopLoad() }; result(nil)
    case "goBack": withSession(args) { $0.goBack() }; result(nil)
    case "goForward": withSession(args) { $0.goForward() }; result(nil)
    case "executeJavaScript":
      if let code = args["code"] as? String {
        withSession(args) { $0.executeJavaScript(code) }
      }
      result(nil)
    case "setZoomLevel":
      withSession(args) { $0.setZoomLevel(args["level"] as? Double ?? 0) }
      result(nil)
    case "setVisible":
      withSession(args) { $0.setVisible(args["visible"] as? Bool ?? true) }
      result(nil)
    case "find":
      if let text = args["text"] as? String {
        withSession(args) {
          $0.find(text, forward: args["forward"] as? Bool ?? true,
                  matchCase: args["matchCase"] as? Bool ?? false,
                  findNext: args["findNext"] as? Bool ?? false)
        }
      }
      result(nil)
    case "stopFind":
      withSession(args) { $0.stopFind(args["clearSelection"] as? Bool ?? true) }
      result(nil)
    case "respondJsDialog":
      withSession(args) {
        $0.respondJsDialog(id: args["id"] as? Int ?? 0,
                           ok: args["ok"] as? Bool ?? true,
                           text: args["text"] as? String ?? "")
      }
      result(nil)
    case "evalReturning":
      if let code = args["code"] as? String {
        withSession(args) {
          $0.evalReturning(id: args["id"] as? Int ?? 0, code: code)
        }
      }
      result(nil)
    case "addJavaScriptChannel":
      if let name = args["name"] as? String {
        withSession(args) { $0.addChannel(name) }
      }
      result(nil)
    case "setCookie":
      withSession(args) {
        $0.setCookie(url: args["url"] as? String ?? "",
                     name: args["name"] as? String ?? "",
                     value: args["value"] as? String ?? "",
                     domain: args["domain"] as? String ?? "",
                     path: args["path"] as? String ?? "/")
      }
      result(nil)
    case "clearCookies":
      withSession(args) { $0.clearCookies() }
      result(nil)
    case "visitCookies":
      withSession(args) {
        $0.visitCookies(id: args["id"] as? Int ?? 0,
                        url: args["url"] as? String ?? "")
      }
      result(nil)
    case "deleteCookie":
      withSession(args) {
        $0.deleteCookie(url: args["url"] as? String ?? "",
                        name: args["name"] as? String ?? "")
      }
      result(nil)
    case "showDevTools":
      withSession(args) { $0.showDevTools() }
      result(nil)
    case "showEmojiPicker":
      // The Character Viewer targets the current first responder's input
      // context — Flutter's text-input plugin while the CefWebView is focused.
      NSApplication.shared.orderFrontCharacterPalette(nil)
      result(nil)
    case "imeSetComposition":
      withSession(args) { $0.imeSetComposition(args["text"] as? String ?? "") }
      result(nil)
    case "imeCommitText":
      withSession(args) { $0.imeCommitText(args["text"] as? String ?? "") }
      result(nil)
    case "imeCancelComposition":
      withSession(args) { $0.imeCancelComposition() }
      result(nil)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func withSession(_ a: [String: Any], _ body: (CefWebSession) -> Void) {
    if let id = a["sessionId"] as? String, let s = sessions[id] { body(s) }
  }

  /// Relay an event from a session (any thread) to Dart on the main thread.
  private func emit(_ method: String, _ args: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      self?.channel?.invokeMethod(method, arguments: args)
    }
  }

  private func create(_ a: [String: Any], _ result: @escaping FlutterResult) {
    guard let sessionId = a["sessionId"] as? String,
          let registry = textureRegistry else {
      result(FlutterError(code: "bad_args", message: "missing sessionId/registry",
                          details: nil))
      return
    }
    guard let cefHost = resolveCefHostPath() else {
      result(FlutterError(code: "no_cef_host",
                          message: "cef_host not found (set FLUTTER_CEF_HOST)",
                          details: nil))
      return
    }
    let url = a["url"] as? String ?? "about:blank"
    let width = a["width"] as? Int ?? 800
    let height = a["height"] as? Int ?? 600
    let dpr = (a["dpr"] as? Double).map { CGFloat($0) } ?? 1.0
    let allowedSchemes = a["allowedSchemes"] as? String ?? ""
    let enableCdp = a["enableCdp"] as? Bool ?? false
    // A non-empty `profile` => a persistent, shared host; absent/empty => an
    // ephemeral throwaway host. Backward-compat is structural: no `profile`
    // behaves exactly as before.
    let profile = a["profile"] as? String
    let namedProfile = profile != nil && !profile!.isEmpty

    // Dispose any prior session with this id first (route teardown through its
    // host), so re-creating the same id is idempotent and doesn't trip the
    // single-view guard below on itself.
    disposeSession(sessionId)

    // Safety rail (a): CDP is an unauthenticated localhost port that could read
    // the shared cookie jar, so it's incompatible with a named profile. Reject
    // before spawn, so --cdp-port and --profile-dir never co-arrive at cef_host.
    if enableCdp && namedProfile {
      result(FlutterError(
        code: "cdp_with_profile",
        message: "enableCdp cannot be combined with a named profile: CDP exposes "
          + "an unauthenticated localhost port that could read the profile's "
          + "shared cookie jar.",
        details: nil))
      return
    }
    // Safety rail (c) — P1 single-view guard: only one live browser per named
    // profile for now (multi-view sharing lands in P2). An ephemeral host is
    // per-session, so this only applies to named profiles.
    if namedProfile, let existing = profiles[profile!], existing.hasLiveBrowser {
      result(FlutterError(
        code: "profile_in_use",
        message: "profile '\(profile!)' is already in use by another view "
          + "(single-view per profile in this build).",
        details: nil))
      return
    }

    let (profileDir, isEphemeral) = resolveProfileDir(namedProfile ? profile : nil)
    let key = namedProfile ? profile! : "~ephemeral~" + sessionId

    guard let host = resolveOrSpawnHost(
      key: key, profileDir: profileDir, isEphemeral: isEphemeral,
      cefHostPath: cefHost, enableCdp: enableCdp, allowedSchemes: allowedSchemes)
    else {
      result(FlutterError(code: "spawn_failed",
                          message: "failed to spawn cef_host", details: nil))
      return
    }

    // F.5 dev safety-rail: an ad-hoc (mock-keychain) host refuses a named
    // persistent profile at opReady (nothing's been written, so no creds leak).
    // When that fires, tear the host down and respawn an EPHEMERAL host for this
    // same session, then re-issue createBrowser. Wired only for named profiles;
    // an already-ephemeral host never refuses.
    if namedProfile {
      host.onInsecureProfileRefused = { [weak self] in
        DispatchQueue.main.async {
          self?.respawnEphemeral(sessionId: sessionId, url: url,
                                 allowedSchemes: allowedSchemes)
        }
      }
    }

    let session = CefWebSession(
      sessionId: sessionId, width: width, height: height, dpr: dpr,
      registry: registry)
    session.onCursor = { [weak self] cursor in
      self?.emit("cursor", ["sessionId": sessionId, "cursor": cursor])
    }
    session.onLoadState = { [weak self] loading, back, forward in
      self?.emit("loadingState", [
        "sessionId": sessionId, "isLoading": loading,
        "canGoBack": back, "canGoForward": forward,
      ])
    }
    session.onTitle = { [weak self] t in
      self?.emit("title", ["sessionId": sessionId, "title": t])
    }
    session.onUrl = { [weak self] u in
      self?.emit("url", ["sessionId": sessionId, "url": u])
    }
    session.onLoadError = { [weak self] code, url, text in
      self?.emit("loadError", [
        "sessionId": sessionId, "code": code, "url": url, "text": text,
      ])
    }
    session.onConsole = { [weak self] level, message in
      self?.emit("consoleMessage", [
        "sessionId": sessionId, "level": level, "message": message,
      ])
    }
    session.onPageStarted = { [weak self] u in
      self?.emit("pageStarted", ["sessionId": sessionId, "url": u])
    }
    session.onPageFinished = { [weak self] u in
      self?.emit("pageFinished", ["sessionId": sessionId, "url": u])
    }
    session.onProgress = { [weak self] p in
      self?.emit("progress", ["sessionId": sessionId, "progress": p])
    }
    session.onNewWindow = { [weak self] u in
      self?.emit("newWindow", ["sessionId": sessionId, "url": u])
    }
    session.onFindResult = { [weak self] count, ordinal, isFinal in
      self?.emit("findResult", [
        "sessionId": sessionId, "count": count,
        "activeMatchOrdinal": ordinal, "isFinal": isFinal,
      ])
    }
    session.onJsDialog = { [weak self] id, type, message, defaultText in
      self?.emit("jsDialog", [
        "sessionId": sessionId, "id": id, "type": type,
        "message": message, "defaultText": defaultText,
      ])
    }
    session.onEvalResult = { [weak self] payload in
      self?.emit("evalResult", ["sessionId": sessionId, "payload": payload])
    }
    session.onChannelMsg = { [weak self] payload in
      self?.emit("channelMessage", ["sessionId": sessionId, "payload": payload])
    }
    session.onDownload = { [weak self] name in
      self?.emit("download", ["sessionId": sessionId, "suggestedName": name])
    }
    session.onImeBounds = { [weak self] x, y, w, h in
      self?.emit("imeCompositionBounds", [
        "sessionId": sessionId, "x": x, "y": y, "w": w, "h": h,
      ])
    }
    session.onCookies = { [weak self] id, json in
      self?.emit("cookies", ["sessionId": sessionId, "id": id, "json": json])
    }
    // Allocate the wire browserId + (when ready) issue opCreateBrowser. The
    // process arg --allowed-schemes is shared by every browser in the profile;
    // it's taken from the first browser that triggered the spawn.
    _ = host.createBrowser(session, url: url, allowedSchemes: allowedSchemes)
    sessions[sessionId] = session
    sessionHost[sessionId] = host
    sessionKey[sessionId] = key
    result([
      "textureId": session.textureId, "width": width, "height": height,
      "cdpPort": host.cdpPort,
    ])
  }

  /// Resolve an existing host for `key`, or spawn a fresh one. Returns nil if the
  /// spawn fails.
  private func resolveOrSpawnHost(
    key: String, profileDir: String, isEphemeral: Bool, cefHostPath: String,
    enableCdp: Bool, allowedSchemes: String
  ) -> CefProfileHost? {
    if let existing = profiles[key] { return existing }
    let host = CefProfileHost(
      profileId: key, profileDir: profileDir, isEphemeral: isEphemeral)
    guard host.spawn(cefHostPath: cefHostPath, enableCdp: enableCdp,
                     allowedSchemes: allowedSchemes) else {
      return nil
    }
    profiles[key] = host
    return host
  }

  /// F.5: the running cef_host turned out to be an ad-hoc (mock-keychain) build
  /// and refused the named profile. Tear that host down and recreate this session
  /// on a fresh EPHEMERAL host (recomputing dir/key), then re-issue createBrowser
  /// with the original url/allowedSchemes. Because nothing was written to the
  /// persistent dir, no creds leak.
  private func respawnEphemeral(sessionId: String, url: String,
                                allowedSchemes: String) {
    guard let session = sessions[sessionId],
          let cefHost = resolveCefHostPath() else { return }
    // Tear down the refused (named) host and forget it.
    if let oldKey = sessionKey[sessionId], let oldHost = profiles[oldKey] {
      oldHost.shutdown()
      profiles[oldKey] = nil
    }
    // The slimmed session keeps its texture/buffers; just re-bind it to a fresh
    // ephemeral host. CDP is never enabled here (a named profile rejects CDP, so
    // a refused-then-downgraded session had none).
    let (profileDir, isEphemeral) = resolveProfileDir(nil)
    let key = "~ephemeral~" + sessionId
    let host = CefProfileHost(
      profileId: key, profileDir: profileDir, isEphemeral: isEphemeral)
    guard host.spawn(cefHostPath: cefHost, enableCdp: false,
                     allowedSchemes: allowedSchemes) else {
      NSLog("[cef] respawn ephemeral host failed for \(sessionId)")
      return
    }
    profiles[key] = host
    _ = host.createBrowser(session, url: url, allowedSchemes: allowedSchemes)
    sessionHost[sessionId] = host
    sessionKey[sessionId] = key
  }

  private func navigate(_ a: [String: Any], _ result: @escaping FlutterResult) {
    if let id = a["sessionId"] as? String, let url = a["url"] as? String {
      sessions[id]?.navigate(url)
    }
    result(nil)
  }

  /// Host content-injection load (loadHtmlString/loadFile) — bypasses the
  /// navigation scheme allowlist in cef_host.
  private func loadTrusted(_ a: [String: Any], _ result: @escaping FlutterResult) {
    if let id = a["sessionId"] as? String, let url = a["url"] as? String {
      sessions[id]?.loadTrusted(url)
    }
    result(nil)
  }

  private func resize(_ a: [String: Any], _ result: @escaping FlutterResult) {
    if let id = a["sessionId"] as? String, let s = sessions[id] {
      s.resize(width: a["width"] as? Int ?? 800, height: a["height"] as? Int ?? 600)
      result(["textureId": s.textureId])
    } else {
      result(nil)
    }
  }

  private func destroy(_ a: [String: Any], _ result: @escaping FlutterResult) {
    if let id = a["sessionId"] as? String { disposeSession(id) }
    result(nil)
  }

  /// Tear down one session: close its browser on the shared host, then dispose
  /// the session. ORDERING (binding, F.3): if this was the host's last browser,
  /// `host.shutdown()` (which joins the reader, so no more inbound) runs BEFORE
  /// `session.dispose()` and the profile is dropped. Otherwise `removeBrowser`
  /// has already unregistered this browser under lock, so `session.dispose()`
  /// runs safely while the shared reader keeps serving the siblings.
  private func disposeSession(_ id: String) {
    guard let session = sessions[id] else { return }
    let host = sessionHost[id]
    let key = sessionKey[id]
    sessions[id] = nil
    sessionHost[id] = nil
    sessionKey[id] = nil
    guard let host = host else {
      // No host on record (shouldn't happen) — just release the session.
      session.dispose()
      return
    }
    let remaining = host.removeBrowser(session.browserId)
    if remaining == 0 {
      host.shutdown()
      session.dispose()
      if let key = key { profiles[key] = nil }
    } else {
      session.dispose()
    }
  }

  /// Resolve the on-disk cache dir for a profile. F.4: a null/empty profile gets
  /// a unique throwaway temp dir (ephemeral, removed on host shutdown); a named
  /// profile gets a stable 0700 dir under Application Support that survives
  /// relaunch. Both go through one downstream code path: the host always receives
  /// --profile-dir=<dir>.
  private func resolveProfileDir(_ profile: String?) -> (dir: String, ephemeral: Bool) {
    let fm = FileManager.default
    guard let profile = profile, !profile.isEmpty else {
      let dir = NSTemporaryDirectory() + "flutter_cef_ephem_" + UUID().uuidString
      try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                              attributes: [.posixPermissions: 0o700])
      return (dir, true)
    }
    // Sanitize to a filesystem-safe leaf; anything outside [A-Za-z0-9._-] -> '_'.
    let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
    let safe = String(profile.map { allowed.contains($0) ? $0 : "_" })
    let bundleId = Bundle.main.bundleIdentifier ?? "flutter_cef"
    let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    let base = (appSupport?.path ?? NSTemporaryDirectory())
    let dir = base + "/" + bundleId + "/flutter_cef/profiles/" + safe
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                            attributes: [.posixPermissions: 0o700])
    // Re-chmod the leaf: createDirectory's attributes apply only to dirs it
    // creates, and an existing leaf from a prior run keeps its old mode.
    try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
    return (dir, false)
  }

  private func pointer(_ a: [String: Any], _ result: @escaping FlutterResult) {
    if let id = a["sessionId"] as? String, let s = sessions[id] {
      s.sendPointer(
        type: a["type"] as? Int ?? 0, button: a["button"] as? Int ?? 0,
        clickCount: a["clickCount"] as? Int ?? 1,
        modifiers: UInt32(truncatingIfNeeded: a["modifiers"] as? Int ?? 0),
        x: a["x"] as? Double ?? 0, y: a["y"] as? Double ?? 0,
        dx: a["dx"] as? Double ?? 0, dy: a["dy"] as? Double ?? 0)
    }
    result(nil)
  }

  private func key(_ a: [String: Any], _ result: @escaping FlutterResult) {
    if let id = a["sessionId"] as? String, let s = sessions[id] {
      s.sendKey(
        type: a["type"] as? Int ?? 0,
        modifiers: UInt32(truncatingIfNeeded: a["modifiers"] as? Int ?? 0),
        windowsKeyCode: Int32(truncatingIfNeeded: a["windowsKeyCode"] as? Int ?? 0),
        nativeKeyCode: Int32(truncatingIfNeeded: a["nativeKeyCode"] as? Int ?? 0),
        character: UInt32(truncatingIfNeeded: a["character"] as? Int ?? 0))
    }
    result(nil)
  }

  /// FLUTTER_CEF_HOST env override -> bundled in the app -> nil.
  private func resolveCefHostPath() -> String? {
    let fm = FileManager.default
    if let env = ProcessInfo.processInfo.environment["FLUTTER_CEF_HOST"],
       !env.isEmpty, fm.fileExists(atPath: env) {
      return env
    }
    let inner = "/cef_host.app/Contents/MacOS/cef_host"
    for base in [
      Bundle(for: FlutterCefPlugin.self).resourceURL?.path,
      Bundle.main.bundlePath + "/Contents/Frameworks",
      Bundle.main.bundlePath + "/Contents/Helpers",
    ] {
      if let b = base, fm.fileExists(atPath: b + inner) { return b + inner }
    }
    return nil
  }
}
