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
    default: result(FlutterMethodNotImplemented)
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
      DispatchQueue.main.async {
        self?.channel?.invokeMethod(
          "cursor", arguments: ["sessionId": sessionId, "cursor": cursor])
      }
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
