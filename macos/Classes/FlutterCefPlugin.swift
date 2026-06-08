import Cocoa
import FlutterMacOS

/// macOS plugin entry point. Channel `flutter_cef`. Verbs:
///   create  {sessionId, url, width, height, dpr} -> {textureId, width, height}
///   navigate{sessionId, url}
///   resize  {sessionId, width, height, dpr}
///   dispose {sessionId}
///   pointer {sessionId, type, button, clickCount, modifiers, x, y, dx, dy}
///   key     {sessionId, type, modifiers, windowsKeyCode, nativeKeyCode, character}
/// Host -> Dart: invokeMethod("cursor", {sessionId, cursor}).
public class FlutterCefPlugin: NSObject, FlutterPlugin {
  private weak var textureRegistry: FlutterTextureRegistry?
  private var channel: FlutterMethodChannel?
  private var sessions: [String: CefWebSession] = [:]

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
    sessions[sessionId]?.dispose()
    let session = CefWebSession(
      sessionId: sessionId, url: url, width: width, height: height, dpr: dpr,
      registry: registry, cefHostPath: cefHost)
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
    sessions[sessionId] = session
    result(["textureId": session.textureId, "width": width, "height": height])
  }

  private func navigate(_ a: [String: Any], _ result: @escaping FlutterResult) {
    if let id = a["sessionId"] as? String, let url = a["url"] as? String {
      sessions[id]?.navigate(url)
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
    if let id = a["sessionId"] as? String {
      sessions[id]?.dispose()
      sessions[id] = nil
    }
    result(nil)
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
