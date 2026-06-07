import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'cef_events.dart';
import 'cef_input.dart';

/// Controls one CEF browser session: navigate, drive history, run JavaScript,
/// forward input, and observe page state (loading, title, url, cursor). Backed
/// by a host-side `cef_host` subprocess that renders the page off-screen into a
/// [Texture].
///
/// Usually you don't create this directly — [CefWebView] manages one for you.
/// Use it when you need to script a view.
class CefWebController {
  CefWebController({String? sessionId})
      : sessionId = sessionId ?? 'cef-${_counter++}';

  static const MethodChannel _channel = MethodChannel('flutter_cef');
  static int _counter = 0;

  /// Stable id for this session, echoed in every host message.
  final String sessionId;

  /// The registered [Texture] id once [create] has resolved, else null.
  int? textureId;

  /// The page's current cursor (I-beam over text, hand over links, …), driven
  /// by host cursor events. Feed it to a [MouseRegion].
  final ValueNotifier<MouseCursor> cursor =
      ValueNotifier<MouseCursor>(SystemMouseCursors.basic);

  /// Whether a navigation is in progress (drives a spinner).
  final ValueNotifier<bool> isLoading = ValueNotifier<bool>(false);

  /// Whether [goBack] / [goForward] would do anything.
  final ValueNotifier<bool> canGoBack = ValueNotifier<bool>(false);
  final ValueNotifier<bool> canGoForward = ValueNotifier<bool>(false);

  /// The current document title and main-frame URL.
  final ValueNotifier<String> title = ValueNotifier<String>('');
  final ValueNotifier<String> url = ValueNotifier<String>('');

  /// Called when a navigation fails (DNS failure, offline, blocked, …).
  void Function(CefLoadError error)? onLoadError;

  /// Called for each `console.*` message the page emits.
  void Function(CefConsoleMessage message)? onConsoleMessage;

  static final Map<String, CefWebController> _bySession =
      <String, CefWebController>{};
  static bool _handlerInstalled = false;

  static void _installHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      final a = (call.arguments as Map?)?.cast<String, dynamic>();
      final id = a?['sessionId'] as String?;
      if (id != null) _bySession[id]?._onEvent(call.method, a!);
      return null;
    });
  }

  void _onEvent(String method, Map<String, dynamic> a) {
    switch (method) {
      case 'cursor':
        cursor.value = cefCursorForType(a['cursor'] as int? ?? 0);
        break;
      case 'loadingState':
        isLoading.value = a['isLoading'] as bool? ?? false;
        canGoBack.value = a['canGoBack'] as bool? ?? false;
        canGoForward.value = a['canGoForward'] as bool? ?? false;
        break;
      case 'title':
        title.value = a['title'] as String? ?? '';
        break;
      case 'url':
        url.value = a['url'] as String? ?? '';
        break;
      case 'loadError':
        onLoadError?.call(CefLoadError(
          errorCode: a['code'] as int? ?? 0,
          url: a['url'] as String? ?? '',
          errorText: a['text'] as String? ?? '',
        ));
        break;
      case 'consoleMessage':
        onConsoleMessage?.call(CefConsoleMessage(
          level: a['level'] as int? ?? 0,
          message: a['message'] as String? ?? '',
        ));
        break;
    }
  }

  /// Spawn the renderer for [url] at [width]×[height] logical px. Returns the
  /// [Texture] id to display, or null on failure.
  Future<int?> create({
    required String url,
    required int width,
    required int height,
    double dpr = 1.0,
  }) async {
    _bySession[sessionId] = this;
    _installHandler();
    final res = await _channel.invokeMapMethod<String, dynamic>('create', {
      'sessionId': sessionId,
      'url': url,
      'width': width,
      'height': height,
      'dpr': dpr,
    });
    textureId = res?['textureId'] as int?;
    return textureId;
  }

  Future<void> navigate(String url) =>
      _channel.invokeMethod('navigate', {'sessionId': sessionId, 'url': url});

  /// Reload the current page.
  Future<void> reload() => _send('reload');

  /// Stop the in-progress load.
  Future<void> stop() => _send('stop');

  /// Go back / forward in history (no-op at the ends — gate on [canGoBack] /
  /// [canGoForward]).
  Future<void> goBack() => _send('goBack');
  Future<void> goForward() => _send('goForward');

  /// Run [code] in the main frame (fire-and-forget; no return value).
  Future<void> executeJavaScript(String code) => _channel
      .invokeMethod('executeJavaScript', {'sessionId': sessionId, 'code': code});

  Future<void> _send(String method) =>
      _channel.invokeMethod(method, {'sessionId': sessionId});

  Future<void> resize(int width, int height, {double dpr = 1.0}) =>
      _channel.invokeMethod('resize', {
        'sessionId': sessionId,
        'width': width,
        'height': height,
        'dpr': dpr,
      });

  /// type: 0=move 1=down 2=up 3=wheel; button: 0=left 1=middle 2=right.
  void sendPointer({
    required int type,
    required double x,
    required double y,
    int button = 0,
    int clickCount = 1,
    int modifiers = 0,
    double dx = 0,
    double dy = 0,
  }) {
    _channel.invokeMethod('pointer', {
      'sessionId': sessionId,
      'type': type,
      'button': button,
      'clickCount': clampCefClickCount(clickCount),
      'modifiers': modifiers,
      'x': x,
      'y': y,
      'dx': dx,
      'dy': dy,
    });
  }

  /// type: 0=rawkeydown 2=keyup 3=char.
  void sendKey({
    required int type,
    int modifiers = 0,
    int windowsKeyCode = 0,
    int nativeKeyCode = 0,
    int character = 0,
  }) {
    _channel.invokeMethod('key', {
      'sessionId': sessionId,
      'type': type,
      'modifiers': modifiers,
      'windowsKeyCode': windowsKeyCode,
      'nativeKeyCode': nativeKeyCode,
      'character': character,
    });
  }

  Future<void> dispose() async {
    _bySession.remove(sessionId);
    cursor.dispose();
    isLoading.dispose();
    canGoBack.dispose();
    canGoForward.dispose();
    title.dispose();
    url.dispose();
    await _channel.invokeMethod('dispose', {'sessionId': sessionId});
  }
}
