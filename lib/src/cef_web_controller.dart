import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show TargetPlatform, ValueListenable, defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:meta/meta.dart';

import 'package:flutter_cef_platform_interface/flutter_cef_platform_interface.dart';

/// Where a [CefWebController]'s native session is in its life.
///
/// ```text
/// idle ──create──▶ creating ──▶ live ◀──thaw── frozen
///                     │  ▲       │  └──freeze──▶  │
///                     │  └──┐    │                │
///                     ▼     │    ▼                ▼
///                   idle    └── gone ◀────────────┘
/// ```
///
/// Any state but [disposed] can move to [disposed].
enum CefSessionState {
  /// No session: never created, or a [CefWebController.create] that failed.
  idle,

  /// [CefWebController.create] is spawning the host and the browser.
  creating,

  /// The browser is up; [CefWebController.textureId] shows it.
  live,

  /// [CefWebController.freeze] tore down the browser; the texture keeps its
  /// last frame until [CefWebController.thaw].
  frozen,

  /// The session ended without [CefWebController.dispose]: `cef_host` crashed,
  /// lost the profile's lock, or the browser never came up (see
  /// [CefWebController.onProcessGone]). [CefWebController.create] starts a new
  /// one.
  gone,

  /// [CefWebController.dispose] ran. Final.
  disposed,
}

/// Controls one CEF browser session: navigate, drive history, run JavaScript,
/// forward input, and observe page state (loading, title, url, cursor). Backed
/// by a host-side `cef_host` subprocess that renders the page off-screen into a
/// [Texture].
///
/// Usually you don't create this directly — [CefWebView] manages one for you.
/// Use it when you need to script a view.
class CefWebController {
  CefWebController({
    String? sessionId,
    this.profile,
    this.hostGroup,
    List<String> documentStartScripts = const <String>[],
  })  : sessionId = sessionId ?? 'cef-${_counter++}',
        documentStartScripts = List<String>.unmodifiable(documentStartScripts) {
    // Register + install the host->Dart handler at construction (not in create),
    // so callbacks wired before create() can't miss early events. A controller
    // given the id of one that is still alive takes the id over: events go to
    // the newest one, and the native session is its own once it creates (see
    // [dispose]).
    _bySession[this.sessionId] = this;
    _installHandler();
  }

  // The method channel of the endorsed platform implementation (the default
  // MethodChannelFlutterCef on macOS). A platform plugin may swap the instance
  // in its registerWith; this reflects whatever is current.
  static FlutterCefPlatform get _platform => FlutterCefPlatform.instance;
  static int _counter = 0;

  final ValueNotifier<CefSessionState> _state =
      ValueNotifier<CefSessionState>(CefSessionState.idle);

  /// Where the native session is in its life; see [CefSessionState].
  ValueListenable<CefSessionState> get state => _state;

  static const _transitions = <CefSessionState, Set<CefSessionState>>{
    CefSessionState.idle: {CefSessionState.creating, CefSessionState.disposed},
    CefSessionState.creating: {
      CefSessionState.live,
      CefSessionState.idle,
      CefSessionState.gone,
      CefSessionState.disposed,
    },
    CefSessionState.live: {
      CefSessionState.frozen,
      CefSessionState.gone,
      CefSessionState.disposed,
    },
    CefSessionState.frozen: {
      CefSessionState.live,
      CefSessionState.gone,
      CefSessionState.disposed,
    },
    CefSessionState.gone: {CefSessionState.creating, CefSessionState.disposed},
    CefSessionState.disposed: {},
  };

  void _moveTo(CefSessionState next) {
    assert(_transitions[_state.value]!.contains(next),
        'CefWebController: ${_state.value.name} -> ${next.name}');
    _state.value = next;
  }

  bool get _disposed => _state.value == CefSessionState.disposed;

  // Last visibility the consumer requested, and whether it was ever set
  // explicitly. Re-sent once create() returns (see [_createSession]): a
  // `setVisible` made before the platform had a session for this id was
  // dropped there, so this is what hands the new session the consumer's
  // choice (the platform then re-applies it when cef_host binds the browser).
  // Only sent when explicitly set: a never-set slot keeps CEF's default-shown,
  // so a fresh/recovered OFF-screen slot isn't briefly forced visible (which
  // would pump it at 60fps until its cull edge lands).
  bool _lastVisible = true;
  bool _visibilityExplicitlySet = false;

  /// Stable id for this session, echoed in every host message.
  final String sessionId;

  /// The persistent, shared profile this view's login lives in, or null for an
  /// ephemeral (in-memory, throwaway) session. Views constructed with the same
  /// non-null [profile] share one host process → one cookie jar → one login,
  /// and that login survives cef_host/host-app relaunch. Null (the default) is
  /// today's behaviour.
  final String? profile;

  /// Views constructed with the same non-null [hostGroup] share ONE ephemeral
  /// `cef_host` process tree (browser, GPU and network processes; each view
  /// still gets its own renderer) instead of one tree per view. The shared host
  /// keeps an in-memory cookie jar and storage that live exactly as long as the
  /// group has a view, so nothing is written to disk — use it for a family of
  /// views that don't need a persistent login (editors, previews of
  /// host-authored pages) to pay the Chromium baseline once. A host crash takes
  /// down every view in the group. Ignored when [profile] is set (a named
  /// profile is already one shared host).
  final String? hostGroup;

  /// Scripts run in the main frame of every document this view loads, at the
  /// moment its JavaScript context is created — BEFORE any of the page's own
  /// scripts. JS channels registered (with [addJavaScriptChannel]) before
  /// [create] are installed at the same point, so the page can call
  /// `window.<name>.postMessage` from its very first script. Fixed for the
  /// controller's lifetime; applies to the browser [create] (and [thaw]) make.
  /// A script that throws is reported to the page console and skipped.
  final List<String> documentStartScripts;

  /// Called when the native session can't be created — `cef_host` is missing
  /// or failed to spawn (the [PlatformException] [create] throws), exited
  /// before it was ready, or couldn't dispatch the browser (these two are
  /// reported as [onProcessGone] with reason `"createFailed"` too). Lets a
  /// consumer that embeds a [CefWebView] fall back to another engine; the view
  /// itself shows its placeholder and stops retrying. When unset, [CefWebView]
  /// reports the error through [FlutterError.reportError].
  void Function(Object error)? onCreateFailed;

  /// The registered [Texture] id while the session is [CefSessionState.live]
  /// or [CefSessionState.frozen], else null.
  int? get textureId => _textureId;
  int? _textureId;

  /// Whether a session exists ([CefSessionState.live] or
  /// [CefSessionState.frozen]). Lets a host pre-create a controller (e.g.
  /// eager-spawn) and have the [CefWebView] adopt it instead of calling
  /// [create] again.
  bool get isCreated => _textureId != null;

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

  /// The 127.0.0.1 port CEF's DevTools (CDP) server bound for this session when
  /// [create] was called with `enableCdp: true`, else 0. Connect a CDP client to
  /// `http://127.0.0.1:<port>` (e.g. `/json/list` for the page target's
  /// `webSocketDebuggerUrl`). UNAUTHENTICATED — anyone local who reaches the
  /// port fully drives the page — so only enable it deliberately.
  final ValueNotifier<int> cdpPort = ValueNotifier<int>(0);

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

  /// Called when the backing `cef_host` process is gone — it died unexpectedly
  /// (crash), stopped being able to paint, or lost the profile's cross-process
  /// cache lock. The session and its texture are gone: [isCreated] turns false,
  /// calls answered by the page fail, and a later [create] (or a new view on
  /// this controller) starts a new session. [reason] is `"locked"` when the
  /// profile is already open in another process (show "already open
  /// elsewhere"), `"createFailed"` when the browser never came up (including a
  /// `cef_host` that exited before it was ready; [onCreateFailed] is called
  /// too), `"protocolMismatch(host=vN)"` when `cef_host` speaks another wire
  /// protocol, `"respawnFailed"` when moving the session to a new host failed,
  /// or `"crashed"` otherwise.
  void Function(String reason)? onProcessGone;

  /// The browser was created but still hasn't painted its first frame after the
  /// native host's grace window (~10s, env-tunable via `FLUTTER_CEF_FIRSTPAINT_MS`),
  /// so the texture is (still) blank. The consumer can recover by recreating the view.
  ///
  /// REPEATING signal: this fires again roughly every grace window for as long as the
  /// view stays blank, and stops only once it paints (or the controller is disposed).
  /// So any DESTRUCTIVE recovery (recreate) MUST be bounded/debounced — keep a per-view
  /// attempt counter or backoff rather than recreating on every call (recreating a
  /// merely-slow heavy page on each tick just restarts its load and churns). See
  /// `example/lib/stress_probe.dart` (`_recreateCount` / `kMaxRecreates`) for the pattern.
  VoidCallback? onPaintStalled;

  /// The caret rect (view-local logical px) of the active IME composition.
  /// Wired by [CefWebView] to position the OS candidate window under the text;
  /// you generally don't set this yourself.
  void Function(Rect caretRect)? onImeCompositionBounds;

  /// Called whenever the off-screen frame surface is (re)allocated — once at
  /// session create and again on every resize (which frees the old IOSurface
  /// and allocs a new one). Carries the new global IOSurface id and its
  /// PHYSICAL (Retina) pixel dims. A consumer that mirrors the live page pixels
  /// off-Flutter (e.g. a WebRTC capturer) resolves the surface by id and must
  /// re-read on every fire — never cache the surface across frames. Pull the
  /// current surface on demand with [getFrameSurface].
  void Function(CefSurfaceInfo info)? onSurface;

  /// Handle a page `alert(...)`. Show your UI, then return to dismiss it. If
  /// unset, alerts are auto-dismissed.
  Future<void> Function(CefJsDialogRequest request)? onJavaScriptAlertDialog;

  /// Handle a page `confirm(...)`. Return true for OK, false for Cancel.
  ///
  /// If unset, confirms default to OK, so a page that asks before acting (a
  /// "Discard changes?" behind the user's own click) still works in an app
  /// that shows no dialog UI. Set a handler to show the question to the user.
  /// This is not a permission gate: the page asking `confirm()` is the page
  /// that acts on the answer. A handler that throws answers Cancel.
  Future<bool> Function(CefJsDialogRequest request)? onJavaScriptConfirmDialog;

  /// Handle a page `prompt(...)`. Return the entered text, or null to cancel.
  /// If unset, prompts return their default value, for the same reason as
  /// [onJavaScriptConfirmDialog]. A handler that throws cancels.
  Future<String?> Function(CefJsDialogRequest request)?
      onJavaScriptTextInputDialog;

  /// Handle a page's request for the camera/microphone (`getUserMedia`). Show
  /// your permission UI and return the user's answer:
  ///
  /// * `true` — allow, and REMEMBER it for the requesting origin.
  /// * `false` — block, and REMEMBER it.
  /// * `null` — deny this one request WITHOUT remembering, for when no human
  ///   actually chose (your UI was dismissed by a navigation, the tile went
  ///   away, a request arrived while another prompt was open). Returning
  ///   `false` there would persist a site-wide block the user never asked for,
  ///   and since a remembered block is applied without asking, that silently
  ///   kills camera/mic for the site with no prompt left to undo it.
  ///
  /// Fires only when the site has no stored decision. **If unset, requests are
  /// denied** (transiently), so a page can never reach the camera without a
  /// host that deliberately handles this.
  Future<bool?> Function(CefMediaPermissionRequest request)?
      onMediaPermissionRequest;

  /// A right-click landed in the page. Return the `commandId` of the chosen
  /// item, or null to dismiss.
  ///
  /// Chromium has already built the menu (and decided each item's enabled /
  /// checked state); the host only DRAWS it, because an OSR browser has no
  /// window for a native menu. Whatever id comes back is executed by Chromium,
  /// so copy/paste/back/view-source/spellcheck behave exactly as in Chrome.
  ///
  /// If unset, the menu is dismissed — right-click then does nothing, which is
  /// the behaviour before this callback existed.
  Future<int?> Function(CefContextMenuRequest request)? onContextMenu;

  /// Live camera/mic status for the current page: what is actually capturing
  /// right now, plus the site's remembered decision. Drives an "in use" or
  /// "blocked" indicator; pair with [setMediaSetting] to change the decision.
  final ValueNotifier<CefMediaState> mediaState =
      ValueNotifier<CefMediaState>(const CefMediaState());

  static final Map<String, CefWebController> _bySession =
      <String, CefWebController>{};
  static bool _handlerInstalled = false;
  static final RegExp _channelNameRe = RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$');

  // runJavaScriptReturningResult: pending evals keyed by id, resolved by the
  // 'evalResult' event. JS channels: name -> message handler.
  final Map<int, Completer<Object?>> _evalPending = <int, Completer<Object?>>{};
  int _evalNextId = 1;
  // getCookies: pending requests keyed by id, resolved by the 'cookies' event.
  final Map<int, Completer<List<CefCookie>>> _cookiePending =
      <int, Completer<List<CefCookie>>>{};
  int _cookieNextId = 1;
  final Map<String, void Function(String message)> _channels =
      <String, void Function(String)>{};

  static void _installHandler() {
    // Process-global, installed once on the first controller and never torn
    // down; it fans events out to live controllers by sessionId and is a no-op
    // for disposed ones. It binds the channel of whatever FlutterCefPlatform
    // instance is current at first install (one channel in practice).
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _platform.setEventHandler((id, event, a) {
      try {
        _bySession[id]?._onEvent(event, a);
      } catch (e, st) {
        // A consumer callback threw. Report it: thrown from here it would only
        // reach the platform side, which ignores the reply.
        _reportCallbackError(e, st, 'while handling the $event event');
      }
    });
  }

  static void _reportCallbackError(Object e, StackTrace st, String context) {
    FlutterError.reportError(FlutterErrorDetails(
      exception: e,
      stack: st,
      library: 'flutter_cef',
      context: ErrorDescription(context),
    ));
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
      case 'mediaRequest':
        _handleMediaRequest(a);
        break;
      case 'contextMenu':
        _handleContextMenu(a);
        break;
      case 'mediaState':
        mediaState.value = CefMediaState(
          videoActive: a['videoActive'] as bool? ?? false,
          audioActive: a['audioActive'] as bool? ?? false,
          setting: switch (a['setting'] as int? ?? 0) {
            1 => CefMediaSetting.allow,
            2 => CefMediaSetting.block,
            _ => CefMediaSetting.ask,
          },
        );
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
      case 'cookies':
        _handleCookies(a['id'] as int? ?? 0, a['json'] as String? ?? '[]');
        break;
      case 'imeCompositionBounds':
        onImeCompositionBounds?.call(Rect.fromLTWH(
          (a['x'] as num? ?? 0).toDouble(),
          (a['y'] as num? ?? 0).toDouble(),
          (a['w'] as num? ?? 0).toDouble(),
          (a['h'] as num? ?? 0).toDouble(),
        ));
        break;
      case 'onSurface':
        onSurface?.call(CefSurfaceInfo(
          surfaceId: a['surfaceId'] as int? ?? 0,
          width: a['width'] as int? ?? 0,
          height: a['height'] as int? ?? 0,
        ));
        break;
      case 'processGone':
        // The native host dropped this session (crash, cache-lock loss, or a
        // create that failed — reason 'createFailed'). The texture is dead. Fail
        // any in-flight eval/cookie round-trips FIRST — there is no host left to
        // answer them, so they would otherwise hang forever (this is the single
        // most likely failure) — then let the consumer react (reload / recreate).
        _failPendingEvals('the cef_host process is gone');
        _failPendingCookies('the cef_host process is gone');
        // The native session and its texture are gone: this controller is no
        // longer created, and a later create() starts a new session. (A stale
        // event for a session that never started changes nothing.)
        _textureId = null;
        if (_state.value == CefSessionState.creating ||
            _state.value == CefSessionState.live ||
            _state.value == CefSessionState.frozen) {
          _moveTo(CefSessionState.gone);
        }
        isLoading.value = false;
        mediaState.value = const CefMediaState();
        final reason = a['reason'] as String? ?? 'crashed';
        // The browser never came up (dispatch failed, or the host speaks another
        // wire protocol): the same "can't create" signal create() throws for.
        // A throwing onCreateFailed must not keep onProcessGone from running,
        // and each one's error is reported on its own.
        if (reason == 'createFailed' || reason.startsWith('protocolMismatch')) {
          try {
            onCreateFailed?.call(StateError('cef_host: $reason'));
          } catch (e, st) {
            _reportCallbackError(e, st, 'while calling onCreateFailed');
          }
        }
        onProcessGone?.call(reason);
        break;
      case 'paintStalled':
        // C1: the browser came up but never delivered its first frame even after a
        // re-kick — the texture is (still) blank with no other signal. Surface it so
        // the consumer can recover (e.g. recreate the view) instead of a silent blank.
        onPaintStalled?.call();
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

  void _failPendingCookies(String reason) {
    if (_cookiePending.isEmpty) return;
    final pending = _cookiePending.values.toList();
    _cookiePending.clear();
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
          // No handler: OK (see onJavaScriptConfirmDialog).
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
    } catch (e, st) {
      // Fail closed (dismiss the dialog), but DON'T swallow the error — a throwing
      // app dialog handler is a consumer bug they should see, not a silent dismiss.
      ok = false;
      FlutterError.reportError(FlutterErrorDetails(
        exception: e,
        stack: st,
        library: 'flutter_cef',
        context: ErrorDescription('handling a JavaScript dialog from the page'),
      ));
    }
    if (_disposed) return; // controller torn down while the callback awaited
    await _platform.respondJsDialog(sessionId, id, ok, text);
  }

  /// A right-click landed in the page: ask [onContextMenu] which item to run.
  Future<void> _handleContextMenu(Map<String, dynamic> a) async {
    final id = a['id'] as int? ?? 0;
    // Answer EXACTLY ONCE, whatever happens: CEF requires the menu callback be
    // continued or cancelled, and a dropped one wedges the page's menu handling
    // so later right-clicks are ignored. Hence 0 (= dismiss) on every failure
    // path, including no handler and a throwing handler.
    int? command;
    if (onContextMenu != null) {
      try {
        final req = CefContextMenuRequest.fromJson(
          id,
          jsonDecode(a['json'] as String? ?? '{}') as Map<String, dynamic>,
        );
        command = await onContextMenu?.call(req);
      } catch (e, st) {
        command = null;
        FlutterError.reportError(FlutterErrorDetails(
          exception: e,
          stack: st,
          library: 'flutter_cef',
          context: ErrorDescription('handling a page context menu'),
        ));
      }
    }
    if (_disposed) return;
    await _platform.chooseContextMenu(sessionId, id, command ?? 0);
  }

  /// A page asked for the camera/mic and the site has no remembered decision.
  /// Mirrors [_handleJsDialog]: the page's `getUserMedia` is blocked on the
  /// native callback until this answers, so every path must answer exactly once.
  Future<void> _handleMediaRequest(Map<String, dynamic> a) async {
    final id = a['id'] as int? ?? 0;
    // Bits from cef_media_access_permission_types_t: audio = 1<<0, video = 1<<1.
    final permissions = a['permissions'] as int? ?? 0;
    final req = CefMediaPermissionRequest(
      origin: a['origin'] as String? ?? '',
      camera: permissions & 0x2 != 0,
      microphone: permissions & 0x1 != 0,
    );
    // Fail closed: no handler means no way to ask a human, so deny — but
    // TRANSIENTLY (null), never as a remembered site-wide block.
    bool? decision;
    try {
      decision = await onMediaPermissionRequest?.call(req);
    } catch (e, st) {
      decision = null;
      FlutterError.reportError(FlutterErrorDetails(
        exception: e,
        stack: st,
        library: 'flutter_cef',
        context: ErrorDescription(
            'handling a camera/microphone request from a page'),
      ));
    }
    // Torn down mid-prompt: drop it. cef_host cancels every pending request on
    // dispose/navigation, and an unanswered callback denies rather than hangs.
    if (_disposed) return;
    await _platform.respondMediaRequest(sessionId, id,
        allow: decision ?? false,
        // Only a real answer is remembered.
        remember: decision != null);
  }

  // ── Spawn throttle ──────────────────────────────────────────────────────
  // Each create() spawns a cef_host Chromium process tree (GPU + renderer +
  // helper subprocesses). Mounting many CefWebViews in one frame would fork/exec
  // them all at once — a CPU/IO storm that janks the host's render thread on
  // open. Cap the number of in-flight native create() calls so spawns ramp
  // instead of storming; the excess queue and proceed as slots free up. Tunable;
  // set to <= 0 to disable the cap.
  static int maxConcurrentCreates = 3;

  /// Minimum gap between one spawn finishing and the next queued spawn starting,
  /// applied only under contention (waiters present). The costly part of a spawn
  /// — GPU-process init + first paint — is async *after* create() resolves, so a
  /// pure concurrency cap lets those overlap anyway; this staggers their starts
  /// so the work spreads instead of spiking. A lone create() (no waiters) is
  /// never delayed. Set to [Duration.zero] to disable spacing.
  static Duration spawnSpacing = const Duration(milliseconds: 120);

  static int _activeCreates = 0;
  static final List<Completer<bool>> _createQueue = <Completer<bool>>[];

  // This controller's place in [_createQueue] while its create() waits there.
  Completer<bool>? _slotWaiter;

  // True once this spawn holds a slot; false when [dispose] took the controller
  // out of the queue first (it never held one, so it must not release one).
  Future<bool> _acquireCreateSlot() {
    if (maxConcurrentCreates <= 0 || _activeCreates < maxConcurrentCreates) {
      _activeCreates++;
      return Future<bool>.value(true);
    }
    final waiter = _slotWaiter = Completer<bool>();
    _createQueue.add(waiter);
    return waiter.future; // the slot is handed over (active count preserved).
  }

  // Disposed while queued: leave the queue at once, so a dead controller
  // neither takes a slot nor costs the spawns behind it a [spawnSpacing] gap.
  void _leaveCreateQueue() {
    final waiter = _slotWaiter;
    _slotWaiter = null;
    if (waiter != null && _createQueue.remove(waiter)) waiter.complete(false);
  }

  // Frees this spawn's slot. Under contention, waits [spawnSpacing] first so the
  // next spawn's GPU-init doesn't pile onto this one's. Non-blocking: it does not
  // delay the current create()'s own return.
  static void _scheduleSlotRelease() {
    if (spawnSpacing <= Duration.zero || _createQueue.isEmpty) {
      _releaseCreateSlot();
    } else {
      Future<void>.delayed(spawnSpacing, _releaseCreateSlot);
    }
  }

  static void _releaseCreateSlot() {
    if (_createQueue.isNotEmpty) {
      // Pass our slot to the next waiter.
      _createQueue.removeAt(0).complete(true);
    } else if (_activeCreates > 0) {
      _activeCreates--;
    }
  }

  // The single in-flight create() (null when none is running). Memoized so a
  // concurrent create() adopts the running spawn instead of forking a second
  // cef_host (the native handler disposes + cold-starts on a re-create). This is
  // what makes a host's eager warm-spawn and the view's own mount-time create()
  // converge on ONE process even when the warm create() is still parked in the
  // spawn throttle when the view mounts.
  Future<int?>? _createInFlight;

  // The htmlBaseUrl the session was created with (null unless created on
  // html), so thaw(html:) re-authors the document at the same origin.
  String? _htmlBaseUrl;

  /// Spawn the renderer for [url] at [width]×[height] logical px. Returns the
  /// [Texture] id to display, or null on failure.
  ///
  /// Pass [html] instead of a real [url] to create the browser DIRECTLY on an
  /// authored document (host-trusted, allowlist-exempt — the same content
  /// [loadHtmlString] loads, but in ONE step at create, so there is no
  /// about:blank → later loadHtmlString race). [html] wins when both are given;
  /// [url] should be `about:blank` in that case.
  ///
  /// With an http(s) [htmlBaseUrl] the document is served AT that URL rather than
  /// as a `data:` URL, so it has that URL's real origin — see [loadHtmlString].
  ///
  /// Idempotent under concurrency: if a session already exists ([isCreated]) the
  /// existing [textureId] is returned, and if a create() is already in flight
  /// this call adopts it (same future, no second spawn) — [url]/[width]/[height]
  /// of the second call are ignored in that case (navigate / resize afterward).
  Future<int?> create({
    required String url,
    required int width,
    required int height,
    double dpr = 1.0,
    Set<String>? allowedSchemes,
    bool enableCdp = false,
    bool agentControl = false,
    String? html,
    String? htmlBaseUrl,
  }) {
    // The TCP enableCdp+named-profile combination is rejected because CDP-over-TCP
    // is an unauthenticated localhost port that could read the shared cookie jar.
    // Agent-control (pipe) mode is exempt: CDP rides cef_host's inherited fds 3/4
    // (no listening socket), so it's allowed on a named profile — the gate only
    // covers the plain-TCP case.
    assert(
        !(enableCdp && !agentControl && profile != null && profile!.isNotEmpty),
        'enableCdp cannot be combined with a named profile (CDP-over-TCP is an '
        'unauthenticated localhost port that could read the shared cookie jar). '
        'Use agentControl for a private CDP-over-pipe channel instead.');
    if (_textureId != null) return Future<int?>.value(_textureId);
    if (_disposed) return Future<int?>.value();
    if (_createInFlight == null) {
      _htmlBaseUrl = html != null ? htmlBaseUrl : null;
    }
    // create-with-html: a base64 data: URL (as loadHtmlString builds). cef_host
    // arms the trusted-load exemption for a data:/file: create URL, so this
    // renders the authored doc as the browser's first (and only) page.
    final authored = html != null && _servesAtOrigin(htmlBaseUrl);
    final createUrl = html == null
        ? url
        : authored
            ? htmlBaseUrl!
            : _htmlDataUrl(_withBaseHref(html, htmlBaseUrl));
    if (_createInFlight == null) _moveTo(CefSessionState.creating);
    return _createInFlight ??= _createSession(
      url: createUrl,
      authoredHtml: authored ? html : null,
      width: width,
      height: height,
      dpr: dpr,
      allowedSchemes: allowedSchemes,
      enableCdp: enableCdp,
      agentControl: agentControl,
    ).whenComplete(() => _createInFlight = null);
  }

  Future<int?> _createSession({
    required String url,
    required int width,
    required int height,
    required double dpr,
    required Set<String>? allowedSchemes,
    required bool enableCdp,
    required bool agentControl,
    String? authoredHtml,
  }) async {
    // Disposed while parked in the spawn-throttle queue: it left the queue
    // without a slot, and never forks for a dead controller.
    if (!await _acquireCreateSlot()) return null;
    _slotWaiter = null;
    // Disposed after the slot was handed over: pass it straight on, with no
    // spacing gap, since nothing was spawned.
    if (_disposed) {
      _releaseCreateSlot();
      return null;
    }
    Map<String, dynamic>? res;
    try {
      res = await _platform.create(
        sessionId,
        url: url,
        authoredHtml: authoredHtml,
        width: width,
        height: height,
        dpr: dpr,
        allowedSchemes: allowedSchemes != null && allowedSchemes.isNotEmpty
            ? allowedSchemes.map((s) => s.toLowerCase()).join(',')
            : null,
        enableCdp: enableCdp,
        // Agent-control / pipe mode (CEF-1): the native side launches cef_host
        // via posix_spawn with CDP over inherited fds 3/4 (--cdp-pipe) instead
        // of a TCP --cdp-port.
        agentControl: agentControl,
        profile: profile != null && profile!.isNotEmpty ? profile : null,
        hostGroup:
            hostGroup != null && hostGroup!.isNotEmpty ? hostGroup : null,
        // Installed at JS-context creation, ahead of the page's own scripts.
        // Channels registered before create ride along so the page can post
        // from its first script; later registrations take the per-load path.
        documentStartScripts: documentStartScripts,
        channels: _channels.keys.toList(),
      );
    } catch (_) {
      if (_state.value == CefSessionState.creating) {
        _moveTo(CefSessionState.idle);
      }
      rethrow;
    } finally {
      _scheduleSlotRelease();
    }
    // Disposed during the native spawn — tear down the just-created session so
    // it isn't orphaned (its cef_host would otherwise run with no owner).
    if (_disposed) {
      if (res?['textureId'] != null) {
        _platform.dispose(sessionId);
      }
      return null;
    }
    // The session ended while it was being created (processGone came first):
    // there is no browser behind the texture to adopt.
    if (_state.value == CefSessionState.gone) return null;
    final id = res?['textureId'] as int?;
    if (id == null) {
      _moveTo(CefSessionState.idle);
      return null;
    }
    _textureId = id;
    _zoomLevel = 0; // a new browser starts at 100%
    _moveTo(CefSessionState.live);
    // The 127.0.0.1 CDP port CEF bound for this session (0 if CDP wasn't
    // requested). The server comes up shortly after; a CDP client should retry.
    cdpPort.value = res?['cdpPort'] as int? ?? 0;
    // Re-register any JS channels added before the session existed, so call
    // order (addJavaScriptChannel before the widget mounts) doesn't matter.
    for (final name in _channels.keys) {
      _platform.addJavaScriptChannel(sessionId, name);
    }
    // Hand the new session the consumer's last visibility — but only if the
    // consumer ever set it. The platform only now has a session for this id:
    // a setVisible made before create() returned was dropped there, and would
    // leave an off-screen tile painting (or an on-screen one latched hidden).
    // The browser isn't bound yet (create returns before cef_host binds it);
    // the platform records the visibility and re-sends it once the browser
    // binds. Gated on the explicit-set flag so a fresh/recovered slot that was
    // never told a visibility keeps CEF's default-shown instead of being
    // force-repainted.
    if (_visibilityExplicitlySet) {
      _platform.setVisible(sessionId, _lastVisible);
    }
    // Camera/mic needs no re-assert: the decision lives with the site (a
    // per-origin content setting in the profile), not with this session, so it
    // survives create/recover/thaw the way a browser's site permissions survive
    // reopening a tab.
    return textureId;
  }

  /// Navigate the main frame to [url].
  ///
  /// Subject to the view's `allowedSchemes` (if set): a navigation to a scheme
  /// outside the allowlist is refused. Use [loadHtmlString] / [loadFile] for
  /// trusted local content you want to render regardless of the allowlist.
  Future<void> navigate(String url) => _platform.navigate(sessionId, url);

  /// Open [url] in a windowed Chrome-runtime browser for a WebAuthn / passkey
  /// sign-in ceremony (Touch ID, account picker, hybrid QR).
  ///
  /// The OSR tile itself cannot host WebAuthn — `navigator.credentials.create/get`
  /// hangs because there is no window for the system sheet to attach to. This pops
  /// a real Chrome-runtime window that CAN, sharing this tile's cookie jar so the
  /// sign-in propagates back to the tile once the window is closed. Typically
  /// called with the tile's current address ([url]'s live value). A platform
  /// without it throws a [PlatformException] that [isCefUnsupported]
  /// recognises.
  Future<void> openAuthWindow(String url) {
    // Defense-in-depth (mirrored authoritatively in the Swift session): only ever
    // open the cookie-bearing auth window at a real web origin. Refuse non-http(s)
    // schemes (javascript:/data:/file:/about: ...) rather than round-tripping them.
    final scheme = Uri.tryParse(url)?.scheme.toLowerCase();
    if (scheme != 'https' && scheme != 'http') return Future<void>.value();
    return _platform.openAuthWindow(sessionId, url);
  }

  /// CEF-2a — enable agent control for this tile and return a brokered, token-gated
  /// CDP endpoint a standard CDP client (e.g. `agent-browser`) can connect to.
  ///
  /// Requires the controller to have been created with `agentControl: true` (the
  /// CDP-over-pipe mode); otherwise the platform throws a [PlatformException]. The
  /// relay binds loopback only and exists only while enabled. Point a CDP client at
  /// `--cdp <port>` (Playwright/agent-browser discover the ws-url via
  /// `/json/version`). Idempotent: repeated calls return the same live endpoint.
  /// Tear down with [disableAgentControl].
  ///
  /// Security: the [token] is **required**. The relay rejects the ws upgrade with
  /// `401` unless the client presents it as an `Authorization: Bearer <token>`
  /// header (a `?token=` query is an accepted fallback). The token is minted per
  /// grant, held only in memory, and embedded in [wsUrl]. CDP discovery
  /// (`/json/*`) stays token-free, so a local port-scanner can learn the ws-url
  /// but cannot upgrade. On top of the token the relay binds loopback only, allows
  /// a single active client, and exists only while enabled — so even a same-UID
  /// local process can't attach without the in-memory token.
  ///
  /// Per-tile isolation: the relay is scoped to THIS tile's CDP target (resolved
  /// natively), and applies a deny-by-default / fail-closed / flatten-only Target-domain
  /// filter — a connected client sees and drives only this tile, not sibling tiles in
  /// the same shared-profile process. Browser-context-wide CDP (Storage/Tracing/Browser
  /// mutators / cookie-jar methods) is refused, since tiles share one browser context
  /// (so for a credentialed shared profile the agent can drive the page but cannot read
  /// or clear the whole cookie jar). First cut: one agent-controlled tile per process.
  Future<({String wsUrl, String token, int port})?> enableAgentControl() async {
    final res = await _platform.enableAgentControl(sessionId);
    // A partial/empty native reply returns null rather than throwing an
    // uncatchable TypeError on a missing key.
    final wsUrl = res?['wsUrl'] as String?;
    final token = res?['token'] as String?;
    final port = res?['port'] as int?;
    if (wsUrl == null || token == null || port == null) return null;
    return (wsUrl: wsUrl, token: token, port: port);
  }

  /// CEF-2a — tear down the agent-control relay (closes the listener and any client,
  /// invalidates the token). The tile itself keeps running. Idempotent.
  Future<void> disableAgentControl() =>
      _platform.disableAgentControl(sessionId);

  /// Read the live off-screen frame surface: the global IOSurface id this
  /// session's CVPixelBuffer is backed by, plus its PHYSICAL (Retina) pixel
  /// dims. The on-demand pull counterpart to the [onSurface] event (which fires
  /// on each (re)alloc). Returns null if the session doesn't exist yet, or a
  /// [CefSurfaceInfo] with `surfaceId: 0` before the buffer is allocated. A
  /// consumer mirroring the live pixels off-Flutter resolves the surface by id
  /// and must re-read after any resize — the surface is freed and reallocated.
  Future<CefSurfaceInfo?> getFrameSurface() =>
      _platform.getFrameSurface(sessionId);

  /// Load host-trusted content, bypassing the navigation scheme allowlist.
  /// Backs [loadHtmlString] (data:) and [loadFile] (file:): the host explicitly
  /// chose this content, so it isn't subject to `allowedSchemes` the way page
  /// navigation and [navigate] are.
  Future<void> _loadTrusted(String url) =>
      _platform.loadTrusted(sessionId, url);

  /// Reload the current page.
  Future<void> reload() => _platform.reload(sessionId);

  /// Stop the in-progress load.
  Future<void> stop() => _platform.stop(sessionId);

  /// Go back / forward in history (no-op at the ends — gate on [canGoBack] /
  /// [canGoForward]).
  Future<void> goBack() => _platform.goBack(sessionId);
  Future<void> goForward() => _platform.goForward(sessionId);

  /// Run [code] in the main frame (fire-and-forget; no return value).
  Future<void> executeJavaScript(String code) =>
      _platform.executeJavaScript(sessionId, code);

  /// Evaluate [code] in the main frame and return its value (decoded from JSON,
  /// so primitives, lists and maps all round-trip). Completes with an error if
  /// the script throws.
  ///
  /// [code] runs in the page's own JavaScript world and its result comes back
  /// through it, so treat the result as data from the page: a page can change
  /// what the script sees or answer in its place.
  Future<Object?> runJavaScriptReturningResult(String code) {
    final unavailable = _sessionUnavailable;
    if (unavailable != null) return Future.error(StateError(unavailable));
    final id = _evalNextId++;
    final completer = Completer<Object?>();
    _evalPending[id] = completer;
    _platform.evalReturning(sessionId, id, code).catchError((Object e) {
      final c = _evalPending.remove(id);
      if (c != null && !c.isCompleted) c.completeError(e);
    });
    return completer.future;
  }

  /// Why a call answered by the page can't be made now, or null if it can. The
  /// answer would never come: the platform side drops calls for a session it
  /// doesn't have.
  String? get _sessionUnavailable {
    return switch (_state.value) {
      CefSessionState.live => null,
      CefSessionState.frozen => 'the session is frozen',
      CefSessionState.disposed => 'the controller is disposed',
      CefSessionState.gone => 'the cef_host process is gone',
      CefSessionState.idle ||
      CefSessionState.creating =>
        'the session is not created',
    };
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
    return _platform.addJavaScriptChannel(sessionId, name);
  }

  /// Stop delivering a JS channel registered with [addJavaScriptChannel]:
  /// [onMessageReceived] is no longer invoked for [name]. The page-side
  /// `window.<name>` shim is intentionally NOT torn down — it is process-global on
  /// a shared profile, so tearing it down here would also remove it from sibling
  /// views — so the page can still call `window.<name>.postMessage`, but those
  /// messages are dropped.
  void removeJavaScriptChannel(String name) {
    _channels.remove(name);
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

  /// Set a cookie in this session's cookie jar. [url] scopes the cookie;
  /// [domain] defaults to the url's host.
  ///
  /// The jar belongs to the `cef_host` the session runs in, so it is shared by
  /// every view on the same [profile] or [hostGroup]; a session with neither
  /// has a jar of its own.
  ///
  /// [secure], [httpOnly], and [sameSite] mirror the cookie attributes of the
  /// same names. [CefCookieSameSite.none] requires [secure] — Chromium rejects
  /// `SameSite=None` without `Secure` — and is what lets the cookie ride
  /// cross-site subresource requests (fetches, websocket handshakes). Hosts
  /// older than these fields ignore them and store the cookie `SameSite`
  /// unspecified (treated as Lax).
  Future<void> setCookie({
    required String url,
    required String name,
    required String value,
    String domain = '',
    String path = '/',
    bool secure = false,
    bool httpOnly = false,
    CefCookieSameSite sameSite = CefCookieSameSite.unspecified,
  }) =>
      _platform.setCookie(
        sessionId,
        url: url,
        name: name,
        value: value,
        domain: domain,
        path: path,
        secure: secure,
        httpOnly: httpOnly,
        sameSite: sameSite,
      );

  /// Delete all cookies from this session's cookie jar. On a shared [profile]
  /// or [hostGroup] that signs every view on it out, not just this one.
  Future<void> clearCookies() => _platform.clearCookies(sessionId);

  /// Read cookies from this session's cookie jar (shared per [profile] or
  /// [hostGroup], like [setCookie]'s). With no [url], returns every cookie;
  /// with a [url], only the cookies that would be sent to it. Includes
  /// `httpOnly` cookies (not reachable from page JavaScript).
  Future<List<CefCookie>> getCookies({String? url}) {
    final unavailable = _sessionUnavailable;
    if (unavailable != null) return Future.error(StateError(unavailable));
    final id = _cookieNextId++;
    final completer = Completer<List<CefCookie>>();
    _cookiePending[id] = completer;
    _platform.visitCookies(sessionId, id, url ?? '').catchError((Object e) {
      final c = _cookiePending.remove(id);
      if (c != null && !c.isCompleted) c.completeError(e);
    });
    return completer.future;
  }

  /// Delete the cookie named [name] visible to [url].
  Future<void> deleteCookie({required String url, required String name}) =>
      _platform.deleteCookie(sessionId, url, name);

  /// Resolve a pending [getCookies] from the host's JSON.
  void _handleCookies(int id, String json) {
    final completer = _cookiePending.remove(id);
    if (completer == null || completer.isCompleted) return;
    try {
      final list = (jsonDecode(json) as List)
          .map((e) => CefCookie.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
      completer.complete(list);
    } catch (e) {
      completer.completeError(e);
    }
  }

  /// Open Chromium's DevTools for this page in a separate window.
  ///
  /// [inspectAt] (page DIP coordinates, as reported by
  /// [CefContextMenuRequest.x]/[CefContextMenuRequest.y]) opens DevTools already
  /// inspecting the element at that point — what "Inspect" on a right-click
  /// means. DevTools is a real window even though the page is windowless, so
  /// this works from an OSR view.
  Future<void> openDevTools({Offset? inspectAt}) => _platform.showDevTools(
        sessionId,
        inspectX: inspectAt?.dx.round(),
        inspectY: inspectAt?.dy.round(),
      );

  /// Open the macOS Character Viewer (the emoji & symbols picker — the same
  /// panel as ⌃⌘Space) targeting this view. The view must be focused so the
  /// picked glyph is inserted into the page's focused field. The picker is
  /// anchored at the composition caret (or the last click); see [CefWebView].
  /// A platform without it throws a [PlatformException] that
  /// [isCefUnsupported] recognises.
  Future<void> showEmojiPicker() => _platform.showEmojiPicker(sessionId);

  /// Update the active IME composition with [text] (the in-progress, underlined
  /// text). Driven by [CefWebView]'s text-input integration for CJK/emoji
  /// composition; rarely called directly.
  Future<void> imeSetComposition(String text) =>
      _platform.imeSetComposition(sessionId, text);

  /// Commit [text] to the focused input, ending any composition.
  Future<void> imeCommitText(String text) =>
      _platform.imeCommitText(sessionId, text);

  /// Cancel the active IME composition.
  Future<void> imeCancelComposition() =>
      _platform.imeCancelComposition(sessionId);

  /// The `data:` URL an HTML string loads as (base64, utf-8). Shared by
  /// [loadHtmlString] and create-with-html so the two produce identical content.
  static String _htmlDataUrl(String html) =>
      'data:text/html;charset=utf-8;base64,'
      '${base64Encode(const Utf8Encoder().convert(html))}';

  /// Whether an authored document can be served AT [baseUrl] (so it has that
  /// URL's real origin). http(s) only, on the hosts that implement it (macOS
  /// and Windows); elsewhere the `data:` fallback below applies.
  static bool _servesAtOrigin(String? baseUrl) {
    if (baseUrl == null ||
        (defaultTargetPlatform != TargetPlatform.macOS &&
            defaultTargetPlatform != TargetPlatform.windows)) {
      return false;
    }
    final scheme = Uri.tryParse(baseUrl)?.scheme.toLowerCase();
    return scheme == 'http' || scheme == 'https';
  }

  /// The `data:` fallback for a [baseUrl]: relative URLs resolve against it via
  /// `<base href>`, but the document's ORIGIN stays opaque.
  static String _withBaseHref(String html, String? baseUrl) {
    if (baseUrl == null || baseUrl.isEmpty) return html;
    final tag =
        '<base href="${const HtmlEscape(HtmlEscapeMode.attribute).convert(baseUrl)}">';
    // `<head>` or `<head …>`, never `<header>`: a fragment with a <header>
    // and no <head> gets the tag first, ahead of every URL in it.
    final head =
        RegExp(r'<head(\s[^>]*)?>', caseSensitive: false).firstMatch(html);
    return head == null
        ? '$tag$html'
        : html.replaceRange(head.end, head.end, tag);
  }

  /// Load an HTML string.
  ///
  /// With an http(s) [baseUrl] the document is served AT that URL: the browser
  /// navigates to [baseUrl] and the host answers that one main-frame request with
  /// [html] instead of the network. The page then has [baseUrl]'s real origin — its
  /// relative URLs, fetches, workers and storage all behave as if the site had
  /// served it — which a `data:` URL (opaque origin) cannot give. It stays in
  /// effect across [reload]; [navigate] to anywhere, or another load, ends it.
  ///
  /// Without a [baseUrl] (or where serving at an origin is unsupported) it loads
  /// as a `data:` URL, with `<base href>` standing in for [baseUrl].
  ///
  /// Host-trusted content: rendered regardless of the view's `allowedSchemes`.
  Future<void> loadHtmlString(String html, {String? baseUrl}) {
    if (_servesAtOrigin(baseUrl)) {
      return _platform.loadAuthored(sessionId, baseUrl!, html);
    }
    return _loadTrusted(_htmlDataUrl(_withBaseHref(html, baseUrl)));
  }

  /// Load a local file by absolute path.
  ///
  /// Host-trusted content: rendered regardless of the view's `allowedSchemes`
  /// (so `file:` need not be in the allowlist to use this).
  Future<void> loadFile(String absolutePath) => _loadTrusted(
      // A Windows path (drive letter + backslashes, e.g. `C:\a\b.html`) needs
      // Uri.file to become a valid `file:///C:/a/b.html`; the POSIX branch keeps
      // the historical byte-identical `file://<path>` form macOS ships today.
      defaultTargetPlatform == TargetPlatform.windows
          ? Uri.file(absolutePath, windows: true).toString()
          : 'file://$absolutePath');

  /// Set the page content zoom. `level` is a Chromium zoom *level*; the zoom
  /// *factor* is `1.2^level` (0 = 100%, 1 ≈ 120%, -1 ≈ 83%).
  Future<void> setZoomLevel(double level) {
    _zoomLevel = level;
    return _platform.setZoomLevel(sessionId, level);
  }

  /// The zoom level last set with [setZoomLevel] (including by [CefWebView]'s
  /// ⌘+/⌘−/⌘0), or 0 for a session that hasn't been zoomed.
  double get zoomLevel => _zoomLevel;
  double _zoomLevel = 0;

  /// Run a browser edit command on the FOCUSED frame. In off-screen-rendering
  /// mode a raw ⌘C/⌘V key event does NOT trigger these (there is no AppKit
  /// responder chain to translate the shortcut into an editor action), so the
  /// host must invoke them explicitly — [CefWebView] wires the standard
  /// shortcuts to these. All are no-ops when nothing is focused/selected.
  /// [copy]/[cut] write the current selection to the system clipboard; [paste]
  /// inserts from it into the focused editable element.
  Future<void> copy() => _editCommand(0);
  Future<void> cut() => _editCommand(1);
  Future<void> paste() => _editCommand(2);
  Future<void> selectAll() => _editCommand(3);
  Future<void> undo() => _editCommand(4);
  Future<void> redo() => _editCommand(5);

  Future<void> _editCommand(int command) =>
      _platform.editCommand(sessionId, command);

  /// Pause or resume frame production. `setVisible(false)` calls CEF's
  /// `WasHidden(true)` so the page stops painting (no `OnPaint`, the compositor
  /// idles) — the browser stays alive, so it's a cheap pause/resume, not a
  /// teardown. Use it to stop an off-screen view from burning GPU while keeping
  /// its DOM, scroll position, and JS state intact; call `setVisible(true)` to
  /// resume (CEF repaints the current frame). Visibility defaults to shown.
  Future<void> setVisible(bool visible) {
    _lastVisible = visible;
    _visibilityExplicitlySet = true;
    return _platform.setVisible(sessionId, visible);
  }

  /// Change what this site is remembered as being allowed to do with the camera
  /// and microphone.
  ///
  /// This is the "site settings" path behind an in-use / blocked indicator:
  /// [CefMediaSetting.ask] forgets the decision (the page will prompt the next
  /// time it asks), [CefMediaSetting.block] revokes it, [CefMediaSetting.allow]
  /// grants it without prompting. The page is NOT reloaded — a browser doesn't
  /// yank the page to change a permission, so the new decision simply applies
  /// the next time the site calls `getUserMedia`, and a stream already running
  /// keeps running because it belongs to the page. A platform without
  /// camera/mic handling throws a [PlatformException] that [isCefUnsupported]
  /// recognises.
  Future<void> setMediaSetting(CefMediaSetting setting) =>
      _platform.setMediaSetting(sessionId, setting);

  /// Read this session's pixel-liveness counters (see [CefSessionStats]).
  ///
  /// Returns null when the platform has no such session (never created, or
  /// already disposed). Cheap — the counters are maintained where present
  /// frames already arrive, so this adds no IPC to the host.
  ///
  /// A platform that doesn't keep these counters throws a [PlatformException]
  /// that [isCefUnsupported] recognises; that is not "no such session".
  Future<CefSessionStats?> sessionStats() => _platform.sessionStats(sessionId);

  /// Mute or unmute the page's audio output. Besides silencing it, a hidden
  /// AND muted page regains Chromium's intensive wake-up throttling (audible
  /// pages are exempt), so muting on hide keeps a background tile's timers
  /// cheap. Policy is the caller's — muting is user-visible for media tiles.
  /// A no-op on a platform that doesn't support it.
  Future<void> setAudioMuted(bool muted) =>
      _ignoreUnsupported(_platform.setAudioMuted(sessionId, muted));

  /// Set the visible frame cadence: milliseconds between begin-frames (the OSR
  /// frame clock). 16 ≈ 60fps (the default), 33 ≈ 30fps for a
  /// visible-but-unengaged tile. Clamped natively to [8, 250]. Hidden views
  /// produce no frames regardless (see [setVisible]). A no-op on a platform
  /// that doesn't support it.
  Future<void> setFrameInterval(int milliseconds) =>
      _ignoreUnsupported(_platform.setFrameInterval(sessionId, milliseconds));

  // For calls that are only a hint (muting, frame cadence): a platform without
  // them ignores the hint, as it always has, rather than failing the caller.
  static Future<void> _ignoreUnsupported(Future<void> call) =>
      call.catchError((Object _) {}, test: isCefUnsupported);

  /// Whether the native browser is currently frozen — torn down by [freeze]
  /// while the texture keeps serving the last painted frame.
  bool get isFrozen => _state.value == CefSessionState.frozen;

  /// Tear down the native browser — and, when it was the last live browser on
  /// its profile, the entire cef_host process tree — while KEEPING the
  /// texture, which continues to show the last painted frame. Reclaims
  /// essentially the view's whole native cost (renderer process, compositor,
  /// surfaces); use it for tiles culled long enough that a stale still image
  /// is acceptable.
  ///
  /// Page state (DOM, scroll, JS heap) is lost. Cookies/localStorage survive
  /// for a named [profile] (disk-backed jar) but not for an ephemeral session.
  /// [thaw] recreates the browser on the same texture. Returns false when
  /// there was nothing to freeze (not created, already frozen, or the native
  /// process was already gone), and on a platform that can't freeze: the
  /// session then simply stays live.
  Future<bool> freeze() async {
    if (_state.value != CefSessionState.live) return false;
    try {
      if (!await _platform.freezeSession(sessionId)) return false;
    } catch (e) {
      if (isCefUnsupported(e)) return false;
      rethrow;
    }
    // The session may have ended or been disposed while the call was out.
    if (_state.value != CefSessionState.live) return false;
    _moveTo(CefSessionState.frozen);
    // No host is left to answer in-flight round-trips.
    _failPendingEvals('the session is frozen');
    _failPendingCookies('the session is frozen');
    return true;
  }

  /// Recreate the native browser for a [freeze]-d session on the SAME texture.
  /// The frozen frame keeps showing until the new browser's first paint lands
  /// (no flash). [url] overrides the original create URL — pass the page's
  /// current address for fidelity; [html] (winning over [url], mirroring
  /// [create]) re-authors the document directly, for consumers whose content
  /// state lives host-side. Omitted, the browser reloads what [create] was
  /// originally given. Returns false when the session wasn't frozen.
  ///
  /// [html] is served the way [create] served it: at [htmlBaseUrl] (by
  /// default the one [create] was given) when that is http(s), so the page
  /// keeps its origin; otherwise as a `data:` URL with `<base href>`.
  Future<bool> thaw({String? url, String? html, String? htmlBaseUrl}) async {
    if (!isFrozen) return false;
    String? thawUrl = url;
    if (html != null) {
      final base = htmlBaseUrl ?? _htmlBaseUrl;
      if (_servesAtOrigin(base)) {
        // Stage the document on the frozen session (there is no browser to
        // load it into yet): the recreated browser at [base] is then served it,
        // exactly as create(html:, htmlBaseUrl:) was.
        await _platform.loadAuthored(sessionId, base!, html);
        if (!isFrozen) return false;
        thawUrl = base;
      } else {
        thawUrl = _htmlDataUrl(_withBaseHref(html, base));
      }
    }
    final res = await _platform.thawSession(sessionId, url: thawUrl);
    if (res == null || !isFrozen) return false;
    _zoomLevel = 0; // a new browser starts at 100%
    _moveTo(CefSessionState.live);
    // The platform kept the session (and the visibility it was last given)
    // through the freeze and re-applies it when the new browser binds; this
    // re-send is belt and braces for a culled tile that must come back hidden.
    // JS channels re-flush natively in attach().
    if (_visibilityExplicitlySet) {
      _platform.setVisible(sessionId, _lastVisible);
    }
    return true;
  }

  /// Start (or advance) a find-in-page search for [text]. Results arrive on
  /// [onFindResult]. Pass `findNext: true` to move to the next/previous match of
  /// the same query; toggle [forward] for direction.
  Future<void> find(String text,
          {bool forward = true,
          bool matchCase = false,
          bool findNext = false}) =>
      _platform.find(sessionId, text,
          forward: forward, matchCase: matchCase, findNext: findNext);

  /// Stop the current find-in-page search and (by default) clear the selection.
  Future<void> stopFind({bool clearSelection = true}) =>
      _platform.stopFind(sessionId, clearSelection: clearSelection);

  /// Resize the off-screen surface to [width]x[height] logical px at [dpr].
  /// Driven automatically by [CefWebView]; rarely called directly.
  Future<void> resize(int width, int height, {double dpr = 1.0}) =>
      _platform.resize(sessionId, width, height, dpr);

  /// Internal — driven by [CefWebView]'s gesture forwarding; not part of the
  /// supported public API (raw wire encoding).
  /// type: 0=move 1=down 2=up 3=wheel 4=leave; button: 0=left 1=middle 2=right.
  @internal
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
    _platform.pointer(
      sessionId,
      type: type,
      button: button,
      clickCount: clampCefClickCount(clickCount),
      modifiers: modifiers,
      x: x,
      y: y,
      dx: dx,
      dy: dy,
    );
  }

  /// Internal — driven by [CefWebView]'s key forwarding; not part of the
  /// supported public API (raw wire encoding).
  /// type: 0=rawkeydown 2=keyup 3=char.
  @internal
  void sendKey({
    required int type,
    int modifiers = 0,
    int windowsKeyCode = 0,
    int nativeKeyCode = 0,
    int character = 0,
  }) {
    _platform.key(
      sessionId,
      type: type,
      modifiers: modifiers,
      windowsKeyCode: windowsKeyCode,
      nativeKeyCode: nativeKeyCode,
      character: character,
    );
  }

  /// Tear down the native session: its browser and texture, and its
  /// `cef_host` when this was the host's last session. Pending
  /// [runJavaScriptReturningResult] / [getCookies] futures fail with a
  /// [StateError], and the controller is unusable afterwards.
  ///
  /// If a newer controller was constructed with this one's [sessionId], the id
  /// and its native session are the newer one's: they are left alone.
  Future<void> dispose() async {
    if (_disposed) return; // Idempotent: a controller can be disposed twice
    // (e.g. an externally-owned controller torn down by both the app and a stale
    // view). A second pass must not throw via the ValueNotifier dispose asserts.
    _moveTo(CefSessionState.disposed);
    _textureId = null;
    _leaveCreateQueue();
    final ownsId = identical(_bySession[sessionId], this);
    if (ownsId) _bySession.remove(sessionId);
    _failPendingEvals('controller disposed');
    _failPendingCookies('controller disposed');
    _channels.clear();
    cursor.dispose();
    cdpPort.dispose();
    isLoading.dispose();
    canGoBack.dispose();
    canGoForward.dispose();
    title.dispose();
    url.dispose();
    mediaState.dispose();
    _state.dispose();
    if (ownsId) await _platform.dispose(sessionId);
  }
}
