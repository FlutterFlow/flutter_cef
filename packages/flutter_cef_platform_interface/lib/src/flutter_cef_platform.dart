import 'package:flutter/services.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'cef_events.dart';
import 'method_channel_flutter_cef.dart';

/// Receives an event the native side sent for [sessionId]: the [event] name
/// (`url`, `processGone`, …) and its arguments.
typedef CefEventHandler = void Function(
    String sessionId, String event, Map<String, dynamic> args);

/// The interface that platform-specific implementations of `flutter_cef` must
/// implement to be endorsed (macOS and Windows today).
///
/// The cross-platform contract is the **method-channel protocol**: every
/// platform exposes a [MethodChannel] named [channelName] over which the
/// app-facing `CefWebController` drives a `cef_host` session (create /
/// navigate / input / dispose) and receives page events. The typed methods
/// below are that protocol, written once: each sends one method-channel call,
/// and [setEventHandler] receives the events. The native side of each platform
/// plugin implements it; the Dart side is usually just the endorsement of the
/// default [MethodChannelFlutterCef].
///
/// A platform plugin registers by setting [instance] from its `registerWith`
/// (wired via `dartPluginClass` in the implementation package's pubspec).
abstract class FlutterCefPlatform extends PlatformInterface {
  /// Constructs a [FlutterCefPlatform].
  FlutterCefPlatform() : super(token: _token);

  static final Object _token = Object();

  static FlutterCefPlatform _instance = MethodChannelFlutterCef();

  /// The default instance to use — the method-channel implementation, which
  /// works for any platform whose native plugin speaks the [channelName]
  /// protocol (all of them today).
  static FlutterCefPlatform get instance => _instance;

  /// Platform implementations set this in their `registerWith`. The setter
  /// verifies the [PlatformInterface] token to discourage implementations that
  /// `implements` rather than `extends` this class.
  static set instance(FlutterCefPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// The name of the method channel the app-facing code and the native plugin
  /// communicate over. See `PORTING.md` for the full method + event + IPC
  /// protocol.
  static const String channelName = 'flutter_cef';

  /// The channel the protocol runs over. The default returns
  /// `MethodChannel(channelName)`; a platform only overrides this if it needs a
  /// non-standard transport (none do today).
  MethodChannel get channel =>
      throw UnimplementedError('channel has not been implemented.');

  Future<void> _call(String method, String sessionId,
          [Map<String, Object?> args = const {}]) =>
      channel.invokeMethod<void>(method, {'sessionId': sessionId, ...args});

  Future<Map<String, dynamic>?> _callMap(String method, String sessionId,
          [Map<String, Object?> args = const {}]) =>
      channel.invokeMapMethod<String, dynamic>(
          method, {'sessionId': sessionId, ...args});

  // ── Events ──────────────────────────────────────────────────────────────

  /// Route every native event to [handler]. Replaces any earlier handler.
  void setEventHandler(CefEventHandler handler) {
    channel.setMethodCallHandler((call) async {
      final args = (call.arguments as Map?)?.cast<String, dynamic>();
      final sessionId = args?['sessionId'] as String?;
      if (sessionId != null) handler(sessionId, call.method, args!);
      return null;
    });
  }

  // ── Lifecycle ───────────────────────────────────────────────────────────

  /// Start a session: spawn (or join) a `cef_host` and create the browser.
  /// Returns `textureId` and, with [enableCdp], `cdpPort`.
  Future<Map<String, dynamic>?> create(
    String sessionId, {
    required String url,
    required int width,
    required int height,
    required double dpr,
    String? authoredHtml,
    String? allowedSchemes,
    bool enableCdp = false,
    bool agentControl = false,
    String? profile,
    String? hostGroup,
    List<String> documentStartScripts = const [],
    List<String> channels = const [],
  }) =>
      _callMap('create', sessionId, {
        'url': url,
        if (authoredHtml != null) 'authoredHtml': authoredHtml,
        'width': width,
        'height': height,
        'dpr': dpr,
        if (allowedSchemes != null) 'allowedSchemes': allowedSchemes,
        if (enableCdp) 'enableCdp': true,
        if (agentControl) 'agentControl': true,
        if (profile != null) 'profile': profile,
        if (hostGroup != null) 'hostGroup': hostGroup,
        if (documentStartScripts.isNotEmpty)
          'documentStartScripts': documentStartScripts,
        if (channels.isNotEmpty) 'channels': channels,
      });

  /// End the session and free its texture.
  Future<void> dispose(String sessionId) => _call('dispose', sessionId);

  /// Tear down the browser but keep the texture's last frame. True when there
  /// was a browser to freeze.
  Future<bool> freezeSession(String sessionId) async =>
      await channel
          .invokeMethod<bool>('freezeSession', {'sessionId': sessionId}) ==
      true;

  /// Recreate a frozen session's browser on the same texture, loading [url]
  /// (the original create URL when null). Null when it wasn't frozen.
  Future<Map<String, dynamic>?> thawSession(String sessionId, {String? url}) =>
      _callMap('thawSession', sessionId, {if (url != null) 'url': url});

  /// Pause (`false`) or resume frame production.
  Future<void> setVisible(String sessionId, bool visible) =>
      _call('setVisible', sessionId, {'visible': visible});

  /// Resize the frame surface to [width]x[height] logical px at [dpr].
  Future<void> resize(String sessionId, int width, int height, double dpr) =>
      _call(
          'resize', sessionId, {'width': width, 'height': height, 'dpr': dpr});

  /// Milliseconds between visible begin-frames.
  Future<void> setFrameInterval(String sessionId, int milliseconds) =>
      _call('setFrameInterval', sessionId, {'ms': milliseconds});

  Future<void> setAudioMuted(String sessionId, bool muted) =>
      _call('setAudioMuted', sessionId, {'muted': muted});

  /// Pixel-liveness counters, or null when there is no such session.
  Future<CefSessionStats?> sessionStats(String sessionId) async {
    final raw = await _callMap('sessionStats', sessionId);
    if (raw == null) return null;
    return CefSessionStats(
      presentCount: (raw['presentCount'] as num?)?.toInt() ?? 0,
      lastPresentAgoMs: (raw['lastPresentAgoMs'] as num?)?.toInt(),
      firstPresentSeen: raw['firstPresentSeen'] as bool? ?? false,
      frozen: raw['frozen'] as bool? ?? false,
    );
  }

  /// The current frame surface, or null when there is no such session.
  Future<CefSurfaceInfo?> getFrameSurface(String sessionId) async {
    final res = await _callMap('getFrameSurface', sessionId);
    if (res == null) return null;
    return CefSurfaceInfo(
      surfaceId: res['surfaceId'] as int? ?? 0,
      width: res['width'] as int? ?? 0,
      height: res['height'] as int? ?? 0,
    );
  }

  // ── Navigation and content ──────────────────────────────────────────────

  /// Navigate, subject to the session's scheme allowlist.
  Future<void> navigate(String sessionId, String url) =>
      _call('navigate', sessionId, {'url': url});

  /// Load [url] as embedder content, exempt from the scheme allowlist.
  Future<void> loadTrusted(String sessionId, String url) =>
      _call('loadTrusted', sessionId, {'url': url});

  /// Serve [html] as the main-frame response for exactly [url] and load it.
  Future<void> loadAuthored(String sessionId, String url, String html) =>
      _call('loadAuthored', sessionId, {'url': url, 'html': html});

  Future<void> reload(String sessionId) => _call('reload', sessionId);
  Future<void> stop(String sessionId) => _call('stop', sessionId);
  Future<void> goBack(String sessionId) => _call('goBack', sessionId);
  Future<void> goForward(String sessionId) => _call('goForward', sessionId);

  Future<void> setZoomLevel(String sessionId, double level) =>
      _call('setZoomLevel', sessionId, {'level': level});

  Future<void> find(
    String sessionId,
    String text, {
    required bool forward,
    required bool matchCase,
    required bool findNext,
  }) =>
      _call('find', sessionId, {
        'text': text,
        'forward': forward,
        'matchCase': matchCase,
        'findNext': findNext,
      });

  Future<void> stopFind(String sessionId, {required bool clearSelection}) =>
      _call('stopFind', sessionId, {'clearSelection': clearSelection});

  /// Open a windowed browser at [url] for a WebAuthn ceremony (macOS).
  Future<void> openAuthWindow(String sessionId, String url) =>
      _call('openAuthWindow', sessionId, {'url': url});

  Future<void> showDevTools(String sessionId, {int? inspectX, int? inspectY}) =>
      _call('showDevTools', sessionId, {
        if (inspectX != null) 'inspectX': inspectX,
        if (inspectY != null) 'inspectY': inspectY,
      });

  // ── JavaScript ──────────────────────────────────────────────────────────

  Future<void> executeJavaScript(String sessionId, String code) =>
      _call('executeJavaScript', sessionId, {'code': code});

  /// Evaluate [code]; the result arrives as an `evalResult` event for [id].
  Future<void> evalReturning(String sessionId, int id, String code) =>
      _call('evalReturning', sessionId, {'id': id, 'code': code});

  Future<void> addJavaScriptChannel(String sessionId, String name) =>
      _call('addJavaScriptChannel', sessionId, {'name': name});

  /// Answer the `jsDialog` event [id].
  Future<void> respondJsDialog(
          String sessionId, int id, bool ok, String text) =>
      _call('respondJsDialog', sessionId, {'id': id, 'ok': ok, 'text': text});

  /// Answer the `contextMenu` event [id]; [commandId] 0 dismisses.
  Future<void> chooseContextMenu(String sessionId, int id, int commandId) =>
      _call('chooseContextMenu', sessionId, {'id': id, 'commandId': commandId});

  /// Answer the `mediaRequest` event [id].
  Future<void> respondMediaRequest(String sessionId, int id,
          {required bool allow, required bool remember}) =>
      _call('respondMediaRequest', sessionId,
          {'id': id, 'allow': allow, 'remember': remember});

  Future<void> setMediaSetting(String sessionId, CefMediaSetting setting) =>
      _call('setMediaSetting', sessionId, {
        'value': switch (setting) {
          CefMediaSetting.ask => 0,
          CefMediaSetting.allow => 1,
          CefMediaSetting.block => 2,
        },
      });

  // ── Cookies ─────────────────────────────────────────────────────────────

  Future<void> setCookie(
    String sessionId, {
    required String url,
    required String name,
    required String value,
    required String domain,
    required String path,
    required bool secure,
    required bool httpOnly,
    required CefCookieSameSite sameSite,
  }) =>
      _call('setCookie', sessionId, {
        'url': url,
        'name': name,
        'value': value,
        'domain': domain,
        'path': path,
        'secure': secure,
        'httpOnly': httpOnly,
        'sameSite': sameSite.name,
      });

  Future<void> clearCookies(String sessionId) =>
      _call('clearCookies', sessionId);

  /// Enumerate cookies for [url] (all when empty); the result arrives as a
  /// `cookies` event for [id].
  Future<void> visitCookies(String sessionId, int id, String url) =>
      _call('visitCookies', sessionId, {'id': id, 'url': url});

  Future<void> deleteCookie(String sessionId, String url, String name) =>
      _call('deleteCookie', sessionId, {'url': url, 'name': name});

  // ── Input ───────────────────────────────────────────────────────────────

  /// type: 0=move 1=down 2=up 3=wheel 4=leave; button: 0=left 1=middle 2=right.
  Future<void> pointer(
    String sessionId, {
    required int type,
    required int button,
    required int clickCount,
    required int modifiers,
    required double x,
    required double y,
    required double dx,
    required double dy,
  }) =>
      _call('pointer', sessionId, {
        'type': type,
        'button': button,
        'clickCount': clickCount,
        'modifiers': modifiers,
        'x': x,
        'y': y,
        'dx': dx,
        'dy': dy,
      });

  /// type: 0=rawkeydown 2=keyup 3=char.
  Future<void> key(
    String sessionId, {
    required int type,
    required int modifiers,
    required int windowsKeyCode,
    required int nativeKeyCode,
    required int character,
  }) =>
      _call('key', sessionId, {
        'type': type,
        'modifiers': modifiers,
        'windowsKeyCode': windowsKeyCode,
        'nativeKeyCode': nativeKeyCode,
        'character': character,
      });

  /// 0=copy 1=cut 2=paste 3=selectAll 4=undo 5=redo, in the focused frame.
  Future<void> editCommand(String sessionId, int command) =>
      _call('editCommand', sessionId, {'command': command});

  Future<void> imeSetComposition(String sessionId, String text) =>
      _call('imeSetComposition', sessionId, {'text': text});

  Future<void> imeCommitText(String sessionId, String text) =>
      _call('imeCommitText', sessionId, {'text': text});

  Future<void> imeCancelComposition(String sessionId) =>
      _call('imeCancelComposition', sessionId);

  /// Open the macOS Character Viewer for the session.
  Future<void> showEmojiPicker(String sessionId) =>
      _call('showEmojiPicker', sessionId);

  // ── Agent control ───────────────────────────────────────────────────────

  /// Start the session's token-gated CDP relay; returns `wsUrl`, `token`,
  /// `port`.
  Future<Map<String, dynamic>?> enableAgentControl(String sessionId) =>
      _callMap('enableAgentControl', sessionId);

  Future<void> disableAgentControl(String sessionId) =>
      _call('disableAgentControl', sessionId);
}
