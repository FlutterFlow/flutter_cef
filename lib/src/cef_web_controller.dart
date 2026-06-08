import 'dart:async';
import 'dart:convert';

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
      : sessionId = sessionId ?? 'cef-${_counter++}' {
    // Register + install the host->Dart handler at construction (not in create),
    // so callbacks wired before create() can't miss early events.
    _bySession[this.sessionId] = this;
    _installHandler();
  }

  static const MethodChannel _channel = MethodChannel('flutter_cef');
  static int _counter = 0;
  bool _disposed = false;

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

  /// Called when the main frame begins loading [url].
  void Function(String url)? onPageStarted;

  /// Called when the main frame finishes loading [url].
  void Function(String url)? onPageFinished;

  /// Load progress for the current navigation, 0–100.
  void Function(int progress)? onProgress;

  /// Called when the main-frame URL changes (navigation or SPA `pushState`).
  void Function(String url)? onUrlChange;

  /// Called when the page requests a new window (`window.open`,
  /// `target="_blank"`). The native popup is suppressed; you decide what to do —
  /// commonly [navigate] to load it in the same view, or hand it elsewhere.
  void Function(String url)? onCreateWindow;

  /// Called with each find-in-page result update (see [find]).
  void Function(CefFindResult result)? onFindResult;

  /// Called when a download begins. The user is shown a native Save panel; this
  /// is informational (e.g. to surface a toast).
  void Function(String suggestedName)? onDownload;

  /// The caret rect (view-local logical px) of the active IME composition.
  /// Wired by [CefWebView] to position the OS candidate window under the text;
  /// you generally don't set this yourself.
  void Function(Rect caretRect)? onImeCompositionBounds;

  /// Handle a page `alert(...)`. Show your UI, then return to dismiss it. If
  /// unset, alerts are auto-dismissed.
  Future<void> Function(CefJsDialogRequest request)? onJavaScriptAlertDialog;

  /// Handle a page `confirm(...)`. Return true for OK, false for Cancel. If
  /// unset, confirms default to OK.
  Future<bool> Function(CefJsDialogRequest request)? onJavaScriptConfirmDialog;

  /// Handle a page `prompt(...)`. Return the entered text, or null to cancel. If
  /// unset, prompts return their default value.
  Future<String?> Function(CefJsDialogRequest request)?
      onJavaScriptTextInputDialog;

  static final Map<String, CefWebController> _bySession =
      <String, CefWebController>{};
  static bool _handlerInstalled = false;
  static final RegExp _channelNameRe = RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$');

  // runJavaScriptReturningResult: pending evals keyed by id, resolved by the
  // 'evalResult' event. JS channels: name -> message handler.
  final Map<int, Completer<Object?>> _evalPending = <int, Completer<Object?>>{};
  int _evalNextId = 1;
  final Map<String, void Function(String message)> _channels =
      <String, void Function(String)>{};

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
    if (_disposed) return;
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
        onUrlChange?.call(a['url'] as String? ?? '');
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
      case 'pageStarted':
        // A new main-frame load means any in-flight eval result won't arrive —
        // fail those completers instead of leaking them on a long-lived view.
        _failPendingEvals('navigated before the JavaScript result returned');
        onPageStarted?.call(a['url'] as String? ?? '');
        break;
      case 'pageFinished':
        onPageFinished?.call(a['url'] as String? ?? '');
        break;
      case 'progress':
        onProgress?.call(a['progress'] as int? ?? 0);
        break;
      case 'newWindow':
        onCreateWindow?.call(a['url'] as String? ?? '');
        break;
      case 'findResult':
        onFindResult?.call(CefFindResult(
          numberOfMatches: a['count'] as int? ?? 0,
          activeMatchOrdinal: a['activeMatchOrdinal'] as int? ?? 0,
          isFinalUpdate: a['isFinal'] as bool? ?? false,
        ));
        break;
      case 'jsDialog':
        _handleJsDialog(a);
        break;
      case 'evalResult':
        _handleEvalResult(a['payload'] as String? ?? '');
        break;
      case 'channelMessage':
        _handleChannelMessage(a['payload'] as String? ?? '');
        break;
      case 'download':
        onDownload?.call(a['suggestedName'] as String? ?? '');
        break;
      case 'imeCompositionBounds':
        onImeCompositionBounds?.call(Rect.fromLTWH(
          (a['x'] as num? ?? 0).toDouble(),
          (a['y'] as num? ?? 0).toDouble(),
          (a['w'] as num? ?? 0).toDouble(),
          (a['h'] as num? ?? 0).toDouble(),
        ));
        break;
    }
  }

  /// Resolve a pending [runJavaScriptReturningResult]. Payload is `"id:json"`
  /// where json is `{ok: bool, v: <value or error string>}`.
  void _handleEvalResult(String payload) {
    final i = payload.indexOf(':');
    if (i < 0) return;
    final completer =
        _evalPending.remove(int.tryParse(payload.substring(0, i)));
    if (completer == null || completer.isCompleted) return;
    try {
      final decoded = jsonDecode(payload.substring(i + 1)) as Map;
      if (decoded['ok'] == true) {
        completer.complete(decoded['v']);
      } else {
        completer.completeError(Exception('${decoded['v']}'));
      }
    } catch (e) {
      completer.completeError(e);
    }
  }

  /// Fail every pending [runJavaScriptReturningResult] (called on navigation and
  /// on dispose) so a result that can never arrive doesn't leak the completer.
  void _failPendingEvals(String reason) {
    if (_evalPending.isEmpty) return;
    final pending = _evalPending.values.toList();
    _evalPending.clear();
    for (final c in pending) {
      if (!c.isCompleted) c.completeError(StateError(reason));
    }
  }

  /// Deliver a JS-channel post. Payload is `"name:message"`.
  void _handleChannelMessage(String payload) {
    final i = payload.indexOf(':');
    if (i < 0) return;
    _channels[payload.substring(0, i)]?.call(payload.substring(i + 1));
  }

  /// Dispatch a JS dialog to the right callback, then send the result back so
  /// the page's `alert`/`confirm`/`prompt` call can return. type: 0=alert,
  /// 1=confirm, 2=prompt.
  Future<void> _handleJsDialog(Map<String, dynamic> a) async {
    final id = a['id'] as int? ?? 0;
    final req = CefJsDialogRequest(
      message: a['message'] as String? ?? '',
      defaultText: a['defaultText'] as String? ?? '',
    );
    var ok = true;
    var text = '';
    try {
      switch (a['type'] as int? ?? 0) {
        case 1:
          ok = (await onJavaScriptConfirmDialog?.call(req)) ?? true;
          break;
        case 2:
          final r = onJavaScriptTextInputDialog == null
              ? req.defaultText
              : await onJavaScriptTextInputDialog!(req);
          ok = r != null;
          text = r ?? '';
          break;
        default:
          await onJavaScriptAlertDialog?.call(req);
      }
    } catch (_) {
      ok = false;
    }
    if (_disposed) return; // controller torn down while the callback awaited
    await _channel.invokeMethod('respondJsDialog',
        {'sessionId': sessionId, 'id': id, 'ok': ok, 'text': text});
  }

  /// Spawn the renderer for [url] at [width]×[height] logical px. Returns the
  /// [Texture] id to display, or null on failure.
  Future<int?> create({
    required String url,
    required int width,
    required int height,
    double dpr = 1.0,
  }) async {
    final res = await _channel.invokeMapMethod<String, dynamic>('create', {
      'sessionId': sessionId,
      'url': url,
      'width': width,
      'height': height,
      'dpr': dpr,
    });
    textureId = res?['textureId'] as int?;
    // Re-register any JS channels added before the session existed, so call
    // order (addJavaScriptChannel before the widget mounts) doesn't matter.
    for (final name in _channels.keys) {
      _channel.invokeMethod(
          'addJavaScriptChannel', {'sessionId': sessionId, 'name': name});
    }
    return textureId;
  }

  /// Navigate the main frame to [url].
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
  Future<void> executeJavaScript(String code) => _channel.invokeMethod(
      'executeJavaScript', {'sessionId': sessionId, 'code': code});

  /// Evaluate [code] in the main frame and return its value (decoded from JSON,
  /// so primitives, lists and maps all round-trip). Completes with an error if
  /// the script throws.
  Future<Object?> runJavaScriptReturningResult(String code) {
    final id = _evalNextId++;
    final completer = Completer<Object?>();
    _evalPending[id] = completer;
    _channel.invokeMethod(
        'evalReturning', {'sessionId': sessionId, 'id': id, 'code': code});
    return completer.future;
  }

  /// Register a JavaScript channel: the page can call `window.<name>.postMessage`
  /// (string arg) to deliver a message to [onMessageReceived]. Re-injected on
  /// every page load. Names should be unique JS identifiers.
  Future<void> addJavaScriptChannel(String name,
      {required void Function(String message) onMessageReceived}) {
    if (!_channelNameRe.hasMatch(name)) {
      throw ArgumentError.value(name, 'name', 'must be a JS identifier');
    }
    _channels[name] = onMessageReceived;
    return _channel.invokeMethod(
        'addJavaScriptChannel', {'sessionId': sessionId, 'name': name});
  }

  /// Scroll the page to an absolute pixel position.
  Future<void> scrollTo(int x, int y) =>
      executeJavaScript('window.scrollTo($x, $y)');

  /// Scroll the page by a pixel delta.
  Future<void> scrollBy(int x, int y) =>
      executeJavaScript('window.scrollBy($x, $y)');

  /// The current scroll offset from the top-left.
  Future<Offset> getScrollPosition() async {
    final r =
        await runJavaScriptReturningResult('[window.scrollX,window.scrollY]');
    if (r is List && r.length >= 2 && r[0] is num && r[1] is num) {
      return Offset((r[0] as num).toDouble(), (r[1] as num).toDouble());
    }
    return Offset.zero;
  }

  /// The current document title (live from the page).
  Future<String?> getTitle() async =>
      (await runJavaScriptReturningResult('document.title'))?.toString();

  /// The page's user-agent string.
  Future<String?> getUserAgent() async =>
      (await runJavaScriptReturningResult('navigator.userAgent'))?.toString();

  /// Clear the page's `localStorage`.
  Future<void> clearLocalStorage() => executeJavaScript('localStorage.clear()');

  /// Set a cookie in the global (process-wide) cookie store. [url] scopes the
  /// cookie; [domain] defaults to the url's host.
  Future<void> setCookie({
    required String url,
    required String name,
    required String value,
    String domain = '',
    String path = '/',
  }) =>
      _channel.invokeMethod('setCookie', {
        'sessionId': sessionId,
        'url': url,
        'name': name,
        'value': value,
        'domain': domain,
        'path': path,
      });

  /// Delete all cookies from the global cookie store.
  Future<void> clearCookies() =>
      _channel.invokeMethod('clearCookies', {'sessionId': sessionId});

  /// Update the active IME composition with [text] (the in-progress, underlined
  /// text). Driven by [CefWebView]'s text-input integration for CJK/emoji
  /// composition; rarely called directly.
  Future<void> imeSetComposition(String text) => _channel.invokeMethod(
      'imeSetComposition', {'sessionId': sessionId, 'text': text});

  /// Commit [text] to the focused input, ending any composition.
  Future<void> imeCommitText(String text) => _channel
      .invokeMethod('imeCommitText', {'sessionId': sessionId, 'text': text});

  /// Cancel the active IME composition.
  Future<void> imeCancelComposition() =>
      _channel.invokeMethod('imeCancelComposition', {'sessionId': sessionId});

  /// Load an HTML string. (`baseUrl` is accepted for API familiarity but not yet
  /// honoured — relative URLs resolve against the `data:` document.)
  Future<void> loadHtmlString(String html, {String? baseUrl}) {
    final encoded = base64Encode(const Utf8Encoder().convert(html));
    return navigate('data:text/html;charset=utf-8;base64,$encoded');
  }

  /// Load a local file by absolute path.
  Future<void> loadFile(String absolutePath) =>
      navigate('file://$absolutePath');

  /// Set the page content zoom. `level` is a Chromium zoom *level*; the zoom
  /// *factor* is `1.2^level` (0 = 100%, 1 ≈ 120%, -1 ≈ 83%).
  Future<void> setZoomLevel(double level) => _channel
      .invokeMethod('setZoomLevel', {'sessionId': sessionId, 'level': level});

  /// Start (or advance) a find-in-page search for [text]. Results arrive on
  /// [onFindResult]. Pass `findNext: true` to move to the next/previous match of
  /// the same query; toggle [forward] for direction.
  Future<void> find(String text,
          {bool forward = true,
          bool matchCase = false,
          bool findNext = false}) =>
      _channel.invokeMethod('find', {
        'sessionId': sessionId,
        'text': text,
        'forward': forward,
        'matchCase': matchCase,
        'findNext': findNext,
      });

  /// Stop the current find-in-page search and (by default) clear the selection.
  Future<void> stopFind({bool clearSelection = true}) => _channel.invokeMethod(
      'stopFind', {'sessionId': sessionId, 'clearSelection': clearSelection});

  Future<void> _send(String method) =>
      _channel.invokeMethod(method, {'sessionId': sessionId});

  /// Resize the off-screen surface to [width]x[height] logical px at [dpr].
  /// Driven automatically by [CefWebView]; rarely called directly.
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
    _disposed = true;
    _bySession.remove(sessionId);
    _failPendingEvals('controller disposed');
    _channels.clear();
    cursor.dispose();
    isLoading.dispose();
    canGoBack.dispose();
    canGoForward.dispose();
    title.dispose();
    url.dispose();
    await _channel.invokeMethod('dispose', {'sessionId': sessionId});
  }
}
