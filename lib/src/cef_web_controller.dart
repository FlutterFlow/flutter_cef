import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'cef_input.dart';

/// Controls one CEF browser session: navigate, resize, forward input, and
/// observe the page cursor. Backed by a host-side `cef_host` subprocess that
/// renders the page off-screen into a [Texture].
///
/// Usually you don't create this directly — [CefWebView] manages one for you.
/// Use it when you need to script a view (navigate, send synthetic input).
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

  static final Map<String, CefWebController> _bySession =
      <String, CefWebController>{};
  static bool _handlerInstalled = false;

  static void _installHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'cursor') {
        final a = (call.arguments as Map).cast<String, dynamic>();
        final id = a['sessionId'] as String?;
        if (id != null) {
          _bySession[id]?.cursor.value = cefCursorForType(a['cursor'] as int? ?? 0);
        }
      }
      return null;
    });
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
    await _channel.invokeMethod('dispose', {'sessionId': sessionId});
  }
}
