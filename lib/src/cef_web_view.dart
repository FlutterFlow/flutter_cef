
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:flutter_cef_platform_interface/flutter_cef_platform_interface.dart';

import 'cef_web_controller.dart';

/// Per-event gain applied to trackpad two-finger pan when forwarding it to the
/// page as a scroll. OSR gets no OS scroll momentum, so a flat gain brings the
/// swipe distance closer to a native browser. Tunable.
const double _kTrackpadScrollGain = 3.0;

/// A live Chromium (CEF) browser rendered into a Flutter [Texture].
///
/// The page renders off-screen in a `cef_host` subprocess and is shown here as
/// a texture (so it composites, transforms, and clips like any widget — unlike
/// a platform view). Pointer + keyboard input is forwarded by coordinate, and
/// the page's cursor drives a [MouseRegion]. macOS only.
///
/// Keyboard input reaches the page as real `keydown → keypress → keyup` events,
/// so a focused control activates from the keyboard (Enter submits / clicks,
/// Space toggles a checkbox) and the page's own key handlers fire. While focused
/// the view holds a [TextInputConnection], so dead keys, CJK composition, and
/// emoji work; composition commits and multi-unit inserts (emoji, paste) reach
/// the page as full UTF-8 rather than a keypress. The connection is bound to
/// the [View] hosting this widget (as `EditableText` does), so text input works
/// in multi-view / multi-window apps — where the implicit view doesn't exist —
/// and it is re-shown on every click into the already-focused view, so a host
/// that moves macOS first responder around can't strand the IME.
///
/// Trackpad two-finger pans are forwarded to the page as scrolls even when an
/// ancestor opts into Flutter's trackpad gesture API (which reroutes them from
/// [PointerScrollEvent] to pan-zoom events — e.g. canvas hosts).
///
/// If the backing `cef_host` process dies (crash, or the profile's cache lock
/// was taken by another process), the texture freezes on its last frame. Wire
/// [CefWebController.onProcessGone] to detect it and recreate the view — this
/// widget surfaces the event through the controller rather than handling it
/// itself, so the host decides what UI to show (a reload affordance, an
/// "already open elsewhere" message for the `"locked"` reason, etc.).
///
/// ```dart
/// CefWebView(url: 'https://flutter.dev')
/// ```
class CefWebView extends StatefulWidget {
  const CefWebView({
    super.key,
    required this.url,
    this.controller,
    this.focusNode,
    this.placeholder,
    this.allowedSchemes,
    this.enableCdp = false,
    this.agentControl = false,
    this.profile,
  }) : assert(!(enableCdp && !agentControl && profile != null && profile != ''),
            'enableCdp cannot be combined with a named profile: CDP-over-TCP '
            'exposes an unauthenticated localhost port that could read the '
            'profile\'s shared cookie jar. Use agentControl (CDP-over-pipe, no '
            'open port) for a named profile instead.');

  /// Page to load. Changing it on an existing view navigates.
  final String url;

  /// Optional external controller (to script the view). If null, one is created
  /// and owned internally (and disposed with the view).
  ///
  /// When you supply a controller **you own its lifecycle** — the view only
  /// auto-disposes a controller it created itself. Call `controller.dispose()`
  /// when you're done with it, otherwise the per-view `cef_host` process tree,
  /// the texture, and the controller's notifiers leak.
  final CefWebController? controller;

  /// Optional focus node. Provide one when an outer surface manages focus
  /// (e.g. a canvas tile); otherwise the view creates and owns its own.
  final FocusNode? focusNode;

  /// Shown until the first frame arrives. Defaults to a dark blank box.
  final Widget? placeholder;

  /// If non-null, the page may only navigate to URLs whose scheme is in this
  /// set (case-insensitive) — every other navigation, including the initial
  /// load, programmatic [CefWebController.navigate], in-page clicks, and
  /// redirects, is refused by the renderer ([CefClient.OnBeforeBrowse]). The
  /// `about` scheme (e.g. `about:blank`) is always allowed. Use this to keep an
  /// untrusted page off `file:` / `data:` / `chrome:` etc. — important when a
  /// host can be driven to navigate the view programmatically. Null (the
  /// default) allows all schemes, matching a plain browser.
  ///
  /// The host's explicit content-injection APIs — [CefWebController.loadHtmlString]
  /// (a `data:` URL) and [CefWebController.loadFile] (a `file:` URL) — are NOT
  /// subject to this allowlist: the host chose that content, so it always loads.
  /// Only navigation (the page's, and [CefWebController.navigate]) is gated.
  final Set<String>? allowedSchemes;

  /// Enable the Chrome DevTools Protocol (CDP) for this session: CEF binds a
  /// DevTools server on a free `127.0.0.1` port (read it from
  /// [CefWebController.cdpPort]). UNAUTHENTICATED — any local client that
  /// reaches the port fully drives the page — so opt in deliberately. Only
  /// honoured when this view creates the session (not when it adopts an already
  /// pre-created controller).
  final bool enableCdp;

  /// Enable agent-control / pipe mode: cef_host exposes CDP over inherited file
  /// descriptors (a private, NUL-framed JSON pipe) instead of a TCP port, so
  /// there is no listening socket and the only possible CDP client is this app.
  /// Because nothing is exposed to other local processes, this is permitted on a
  /// named [profile] (unlike [enableCdp]). Only honoured when this view creates
  /// the session (not when it adopts a pre-created controller). Call
  /// [CefWebController.enableAgentControl] to broker a token-gated, per-tile-scoped
  /// loopback CDP endpoint to an external agent (e.g. agent-browser); the relay
  /// confines the agent to this tile's CDP target.
  final bool agentControl;

  /// The persistent, shared browser profile this view's login lives in. Views with
  /// the same non-null [profile] share one signed-in profile that survives relaunch.
  /// Null (default) is ephemeral. Ignored when an external [controller] is supplied
  /// (that controller carries its own profile). Mutually exclusive with the TCP
  /// [enableCdp] (open port), but compatible with [agentControl] (private pipe).
  final String? profile;

  @override
  State<CefWebView> createState() => _CefWebViewState();
}

class _CefWebViewState extends State<CefWebView>
    implements DeltaTextInputClient {
  late final CefWebController _controller =
      widget.controller ?? CefWebController(profile: widget.profile);
  bool _ownsController = false;
  FocusNode? _ownFocusNode;
  int? _textureId;
  Size? _lastSize;
  bool _creating = false;

  // ── IME / text input ─────────────────────────────────────────────
  // While focused we hold a TextInputConnection so the platform IME drives
  // composition. The page owns the real text buffer; this connection is a
  // write-only relay, kept empty between inputs so its value never accumulates.
  TextInputConnection? _textInput;
  // An empty editing state with a VALID caret (offset 0). TextEditingValue.empty
  // uses selection offset -1, which the macOS IME treats as "no insertion point"
  // and refuses to start a marked-text composition on — emoji/insertText still
  // lands, but CJK composition is silently dropped. A real caret fixes that.
  static const TextEditingValue _empty = TextEditingValue(
    selection: TextSelection.collapsed(offset: 0),
  );
  TextEditingValue _editingState = _empty;
  bool _composing = false;
  FocusNode? _listenedFocusNode;

  FocusNode get _focusNode =>
      widget.focusNode ?? (_ownFocusNode ??= FocusNode(debugLabel: 'cef'));

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    // Adopt an externally-pre-created controller (e.g. one a host eager-spawned
    // before this view mounted) instead of calling create() again: the native
    // create handler disposes + recreates the session, which would throw away
    // the warm process and cold-start fresh. With textureId already set,
    // _ensureSession skips create() and just reconciles size via resize().
    _textureId = _controller.textureId;
    _controller.onImeCompositionBounds = _onImeCompositionBounds;
    _attachFocusListener();
  }

  @override
  void didUpdateWidget(CefWebView old) {
    super.didUpdateWidget(old);
    _attachFocusListener();
    // Navigate only when the [url] prop changes to a page we're NOT already on.
    // A host that mirrors the live URL back into [url] (e.g. binding the prop to
    // the controller's own onUrlChange) would otherwise re-issue navigate() to
    // the page's CURRENT location on the next rebuild — a redundant reload that
    // throws away scroll position and page state. Navigating to the current URL
    // is a reload; that's what reload() is for.
    if (old.url != widget.url &&
        _textureId != null &&
        widget.url != _controller.url.value) {
      _controller.navigate(widget.url);
    }
  }

  void _attachFocusListener() {
    final node = _focusNode;
    if (identical(_listenedFocusNode, node)) return;
    _listenedFocusNode?.removeListener(_handleFocusChanged);
    node.addListener(_handleFocusChanged);
    _listenedFocusNode = node;
  }

  void _handleFocusChanged() {
    if (_focusNode.hasFocus) {
      _openTextInput();
    } else {
      _closeTextInput();
    }
  }

  Future<void> _ensureSession(Size size) async {
    // Scheduled via a post-frame callback, which can fire after this State was
    // disposed (same-frame removal). Bail before touching context / the
    // controller so we don't read a deactivated MediaQuery or resize a
    // torn-down session.
    if (!mounted) return;
    final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
    final w = size.width.round();
    final h = size.height.round();
    if (w <= 0 || h <= 0) return;
    if (_textureId == null && !_creating) {
      _creating = true;
      try {
        final id = await _controller.create(
            url: widget.url,
            width: w,
            height: h,
            dpr: dpr,
            allowedSchemes: widget.allowedSchemes,
            enableCdp: widget.enableCdp,
            agentControl: widget.agentControl);
        // Don't record `_lastSize` here: create() may have ADOPTED an in-flight
        // session a host eager-spawned at a different (tile snapshot) size, so
        // we can't assume the live surface is `size`. Leaving `_lastSize` null
        // makes the resize branch below reconcile to the real laid-out size on
        // the next frame (a no-op resize when create() did size to `size`).
        if (mounted) setState(() => _textureId = id);
      } finally {
        _creating = false;
      }
      return;
    }
    if (_textureId != null && _lastSize != size) {
      _lastSize = size;
      // Resize on every layout change. The native session (CefWebSession) flow-controls the
      // sends to cef_host's paint rate — it keeps one resize in flight and coalesces to the
      // latest size — so the page reflows live during the drag without us pacing here.
      _controller.resize(w, h, dpr: dpr);
    }
  }

  @override
  void dispose() {
    _listenedFocusNode?.removeListener(_handleFocusChanged);
    _controller.onImeCompositionBounds = null;
    _closeTextInput();
    _ownFocusNode?.dispose();
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _ensureSession(size));
        final id = _textureId;
        if (id == null) {
          return widget.placeholder ??
              const ColoredBox(color: Color(0xFF101828));
        }
        return ClipRect(
          child: ValueListenableBuilder<MouseCursor>(
            valueListenable: _controller.cursor,
            builder: (context, cursor, child) => MouseRegion(
              cursor: cursor,
              // Tell the page the cursor left so :hover / link highlights clear.
              onExit: (e) => _controller.sendPointer(
                  type: 4, x: e.localPosition.dx, y: e.localPosition.dy),
              child: child,
            ),
            child: Focus(
              focusNode: _focusNode,
              onKeyEvent: _onKeyEvent,
              child: Listener(
                onPointerDown: _onPointerDown,
                onPointerMove: _onPointerMove,
                onPointerHover: _onPointerHover,
                onPointerUp: _onPointerUp,
                onPointerSignal: _onPointerSignal,
                onPointerPanZoomStart: _onPointerPanZoomStart,
                onPointerPanZoomUpdate: _onPointerPanZoomUpdate,
                child: Texture(textureId: id),
              ),
            ),
          ),
        );
      },
    );
  }

  // ── input forwarding ──────────────────────────────────────────────
  int _lastButton = 0;
  // Multi-click tracking — the page keys word/line selection off clickCount,
  // which Flutter's Listener doesn't surface.
  Duration _lastDownAt = Duration.zero;
  Offset _lastDownPos = Offset.zero;
  int _clickCount = 1;

  int _cefModifiers([int buttons = 0]) {
    final keys = HardwareKeyboard.instance;
    var m = cefButtonModifiers(buttons);
    if (keys.isShiftPressed) m |= kCefEventFlagShiftDown;
    if (keys.isControlPressed) m |= kCefEventFlagControlDown;
    if (keys.isAltPressed) m |= kCefEventFlagAltDown;
    if (keys.isMetaPressed) m |= kCefEventFlagCommandDown;
    return m;
  }

  void _onPointerDown(PointerDownEvent e) {
    _lastButton = cefMouseButton(e.buttons);
    // Cycle 1→2→3→1 (caret→word→line) when clicks are quick and close, so the
    // page gets real double/triple clicks.
    final near = (e.localPosition - _lastDownPos).distanceSquared <= 25;
    final quick =
        (e.timeStamp - _lastDownAt) <= const Duration(milliseconds: 300);
    _clickCount = (near && quick) ? (_clickCount % 3) + 1 : 1;
    _lastDownAt = e.timeStamp;
    _lastDownPos = e.localPosition;
    // Record the click BEFORE focusing: a cold focus seeds the emoji/accent
    // picker's anchor from _lastDownPos. Re-seed on later clicks (when not
    // composing) so the picker follows where the user last clicked.
    final wasFocused = _focusNode.hasFocus;
    _focusNode.requestFocus();
    // On a RE-CLICK (the view was already focused) re-issue show() so the
    // platform IME view reclaims macOS first responder. AppKit makes the
    // clicked host view (e.g. an embedder's top-level FlutterView) the first
    // responder on every mouse-down, which silently stops the IME from
    // delivering insertText; an already-focused click never re-fires the focus
    // listener, so without this the IME goes dead on the 2nd+ click (CJK/emoji/
    // dead-keys and plain typing all fail). This mirrors EditableText, which
    // calls requestKeyboard()->show() on every tap. The first focus
    // (wasFocused == false) is owned by the focus listener -> _openTextInput.
    if (wasFocused && !_composing) {
      if (_textInput?.attached ?? false) {
        _pushEditableGeometry(); // re-seed caret at the click for the picker
        _textInput!.show();
      } else {
        _openTextInput();
      }
    }
    _controller.sendPointer(
        type: 1,
        x: e.localPosition.dx,
        y: e.localPosition.dy,
        button: _lastButton,
        clickCount: _clickCount,
        modifiers: _cefModifiers(e.buttons));
  }

  void _onPointerMove(PointerMoveEvent e) => _controller.sendPointer(
      type: 0,
      x: e.localPosition.dx,
      y: e.localPosition.dy,
      modifiers: _cefModifiers(e.buttons));

  void _onPointerHover(PointerHoverEvent e) => _controller.sendPointer(
      type: 0,
      x: e.localPosition.dx,
      y: e.localPosition.dy,
      modifiers: _cefModifiers());

  void _onPointerUp(PointerUpEvent e) => _controller.sendPointer(
      type: 2,
      x: e.localPosition.dx,
      y: e.localPosition.dy,
      button: _lastButton,
      clickCount: _clickCount,
      modifiers: _cefModifiers());

  void _onPointerSignal(PointerSignalEvent e) {
    if (e is PointerScrollEvent) {
      _controller.sendPointer(
          type: 3,
          x: e.localPosition.dx,
          y: e.localPosition.dy,
          dx: -e.scrollDelta.dx,
          dy: -e.scrollDelta.dy);
    }
  }

  // Trackpad two-finger pan. On macOS, Flutter delivers trackpad scroll as
  // pan-zoom gesture events (not PointerScrollEvent) whenever any ancestor opts
  // into the trackpad gesture API — which Campus's canvas does, so the swipe is
  // routed here rather than to [_onPointerSignal]. Forward each incremental pan
  // to the page as a scroll. (pan delta ≈ −scroll delta for the same intent, so
  // we forward it un-negated to match the wheel path above.) The OS doesn't add
  // momentum to OSR, so a per-event gain brings the distance closer to Chrome's.
  // Required to make the Listener route pan-zoom *update* events; nothing to do
  // on the start of a trackpad gesture.
  void _onPointerPanZoomStart(PointerPanZoomStartEvent e) {}

  void _onPointerPanZoomUpdate(PointerPanZoomUpdateEvent e) {
    _controller.sendPointer(
        type: 3,
        x: e.localPosition.dx,
        y: e.localPosition.dy,
        dx: e.localPanDelta.dx * _kTrackpadScrollGain,
        dy: e.localPanDelta.dy * _kTrackpadScrollGain);
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    // Key routing across three owners — Flutter's shortcuts, the macOS IME, and
    // CEF — split by key kind:
    //   - Text keys must reach the platform text-input plugin so the IME fires
    //     insertText / marked-text: return `skipRemainingHandlers` (stops
    //     Flutter's own handlers, still hands the key to the platform IME).
    //   - Editing / navigation keys (backspace, arrows, enter, tab, …) are
    //     already applied by CEF via `sendKey` below: return `handled` so they
    //     do NOT also reach the platform IME (which re-runs the edit command —
    //     the double delete / double arrow-move) or Flutter's own shortcuts
    //     (which eat arrows). `ignored` would let both fire; blanket `handled`
    //     would starve the IME of text.
    if (_composing) {
      // While composing the IME owns the keystroke end-to-end (extend, candidate
      // navigation, confirm, cancel) — it must reach the platform IME, and we
      // must NOT also send a raw key (Enter would both confirm and submit).
      return KeyEventResult.skipRemainingHandlers;
    }

    // ⌃⌘Space opens the macOS emoji & symbols picker. It MUST fall through to
    // the platform text-input context (which shows the picker) — if we return
    // `handled` (which we would, since the combo carries no `character`, so
    // isText is false) the embedder never feeds it to NSTextInputContext and
    // the picker never opens. Flutter's own plugin documents this exact case.
    // skipRemainingHandlers stops Flutter ancestors from eating it but still
    // hands it to the platform; don't forward it to the page either.
    final keys = HardwareKeyboard.instance;
    if (event.logicalKey == LogicalKeyboardKey.space &&
        keys.isControlPressed &&
        keys.isMetaPressed) {
      return KeyEventResult.skipRemainingHandlers;
    }

    final mods = _cefModifiers();
    final wkc = cefWindowsKeyCode(event.logicalKey);
    // native_key_code MUST be the macOS keycode for the physical key — CEF on
    // macOS keys editing/navigation off it. Deriving it from the Windows VK
    // collides (e.g. 0 -> VK 0x30 == macOS keycode 48 == Tab, moving focus).
    final nkc = cefMacNativeKeyCode(event.physicalKey) ?? wkc;
    final ch = event.character;
    final isText = ch != null && _isPrintable(ch);
    // Editing / navigation keys MUST carry the macOS NSEvent character or CEF
    // OSR double-applies them (one Backspace deletes two, one arrow moves two).
    final keyChar = cefMacCharForKey(event.logicalKey);
    // The page should see keydown→keypress→keyup for every character, like a
    // browser. We always send RAWKEYDOWN/KEYUP; the keypress (CHAR) is
    // synthesized by [_commitText] when the IME's insertText delivers a typed
    // character. Enter is the exception: the IME reports it as the `insertNewline`
    // command, never as text, so its keypress CHAR (CR) is sent here — that's
    // what activates a focused <button>/<a> and submits a single-line form.
    // (⌃⌘Space is handled above; ⌘/⌃+Enter is a shortcut, not activation.)
    final isEnter = !keys.isMetaPressed &&
        !keys.isControlPressed &&
        (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter);
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      _controller.sendKey(
          type: 0,
          modifiers: mods,
          windowsKeyCode: wkc,
          nativeKeyCode: nkc,
          character: keyChar);
      if (isEnter) {
        _controller.sendKey(
            type: 3, // KEYEVENT_CHAR — the keypress that fires the page action
            modifiers: mods,
            windowsKeyCode: wkc,
            nativeKeyCode: nkc,
            character: 0x0D);
        return KeyEventResult.handled;
      }
      // Before the IME connection attaches, deliver the character ourselves so
      // early keystrokes aren't lost; once it's up, its insertText delta drives
      // [_commitText] instead.
      if (isText && (_textInput == null || !_textInput!.attached)) {
        _commitText(ch);
      }
      return isText
          ? KeyEventResult.skipRemainingHandlers
          : KeyEventResult.handled;
    }
    if (event is KeyUpEvent) {
      _controller.sendKey(
          type: 2,
          modifiers: mods,
          windowsKeyCode: wkc,
          nativeKeyCode: nkc,
          character: keyChar);
      if (isEnter) return KeyEventResult.handled;
      return isText
          ? KeyEventResult.skipRemainingHandlers
          : KeyEventResult.handled;
    }
    return KeyEventResult.handled;
  }

  static bool _isPrintable(String ch) {
    if (ch.isEmpty) return false;
    final c = ch.codeUnitAt(0);
    // Skip C0 controls and DEL — those ride the raw key event, not text.
    return c >= 0x20 && c != 0x7f;
  }

  /// Deliver committed (non-composing) text to the page. A single typed
  /// character is sent as a real CHAR (keypress) key event, so the page sees
  /// keydown→keypress→keyup exactly like a browser — which is what activates a
  /// focused <button>, toggles a checkbox/radio on Space, and fires the page's
  /// own keypress handlers. Multi-unit inserts (emoji, paste, autofill) and IME
  /// composition commits ([composed]) have no keypress, so they use
  /// imeCommitText (which also keeps astral characters surrogate-safe).
  void _commitText(String text, {bool composed = false}) {
    if (!composed && text.length == 1) {
      final cp = text.codeUnitAt(0);
      _controller.sendKey(
          type: 3, // KEYEVENT_CHAR
          modifiers: _cefModifiers(),
          windowsKeyCode: cp,
          nativeKeyCode: 0,
          character: cp);
    } else {
      _controller.imeCommitText(text);
    }
  }

  // ── IME plumbing ──────────────────────────────────────────────────
  void _openTextInput() {
    if (_textInput != null && _textInput!.attached) {
      _textInput!.show();
      return;
    }
    _editingState = _empty;
    _composing = false;
    final conn = TextInput.attach(
      this,
      TextInputConfiguration(
        // Bind the connection to the FlutterView that hosts this widget — as
        // EditableText does. In a multi-view host (e.g. an app with secondary
        // windows) the implicit view 0 does not exist; without this the engine
        // binds the IME to a nil view, show() never makes the input view first
        // responder, and the platform never delivers insertText (typing
        // produces keydown/keyup but no characters).
        viewId: View.maybeOf(context)?.viewId,
        // Single-line + no action so the IME composes but Enter/newline are not
        // captured as text — they reach the page via the raw key path instead.
        inputType: TextInputType.text,
        inputAction: TextInputAction.none,
        autocorrect: false,
        enableSuggestions: false,
        enableInteractiveSelection: false,
        enableDeltaModel: true,
      ),
    );
    _textInput = conn;
    // macOS only engages its native input context — and thus the IME and the
    // emoji picker — once the editable's size, transform, and style are known.
    // Push them BEFORE show() (as EditableText does); without this, CJK
    // marked-text composition never routes to us and the emoji picker only works
    // if another real text field activated the context first. Re-push after the
    // next layout in case the render box wasn't sized yet.
    _pushEditableGeometry();
    conn
      ..setEditingState(_editingState)
      ..show();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _pushEditableGeometry());
  }

  /// Tell the platform where the editable lives and where the caret is, so the
  /// OS input context activates and positions the IME candidate window *and* the
  /// cold-start emoji / accent pickers (⌃⌘Space, press-and-hold).
  ///
  /// The caret rect is what macOS reads for `firstRectForCharacterRange:` — and
  /// Flutter's text-input plugin returns `CGRectZero` for it until a caret rect
  /// has been pushed, which leaves the Character Viewer anchored at the screen
  /// origin (so it appears not to open). So we ALWAYS push a caret: the real one
  /// from the page during composition ([OnImeCompositionRangeChanged]), or a seed
  /// at the last click otherwise. The whole view is the "editable".
  void _pushEditableGeometry([Rect? caret]) {
    final conn = _textInput;
    if (conn == null || !conn.attached || !mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final c = caret ?? _seedCaretRect();
    conn
      ..setStyle(
        fontFamily: null,
        fontSize: 16,
        fontWeight: null,
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.left,
      )
      ..setEditableSizeAndTransform(box.size, box.getTransformTo(null))
      ..setComposingRect(c)
      ..setCaretRect(c);
  }

  /// A best-effort caret rect (view-local logical px) for when the page hasn't
  /// reported a real composition caret yet — anchored at the last click, so the
  /// emoji / accent picker opens roughly where the user is about to type. Falls
  /// back to the top-left for focus changes that didn't come from a click.
  Rect _seedCaretRect() {
    final p = _lastDownPos == Offset.zero ? const Offset(4, 16) : _lastDownPos;
    return Rect.fromLTWH(p.dx, p.dy - 9, 2, 18);
  }

  void _closeTextInput() {
    if (_composing) {
      _controller.imeCancelComposition();
      _composing = false;
    }
    _textInput?.close();
    _textInput = null;
    _editingState = _empty;
  }

  /// Keep the relay buffer empty between inputs so [TextEditingValue.text] never
  /// accumulates (the page, not this connection, holds the real text). Only safe
  /// when no composition is in flight.
  void _resetScratch() {
    if (_composing || _editingState == _empty) return;
    _editingState = _empty;
    _textInput?.setEditingState(_editingState);
  }

  /// The page reported the composition caret rect (view-local logical px, which
  /// equals this widget's local coordinates). Hand the platform IME the caret +
  /// the widget-to-screen transform so the OS candidate window appears under the
  /// text being composed instead of at a default position.
  void _onImeCompositionBounds(Rect caretRect) =>
      _pushEditableGeometry(caretRect);

  @override
  void updateEditingValueWithDeltas(List<TextEditingDelta> deltas) {
    for (final delta in deltas) {
      final applied = delta.apply(_editingState);
      _editingState = applied;
      final composing = applied.composing;
      final isComposing = composing.isValid &&
          !composing.isCollapsed &&
          composing.start >= 0 &&
          composing.end <= applied.text.length;

      if (isComposing) {
        // In-progress, underlined composition.
        _composing = true;
        _controller.imeSetComposition(composing.textInside(applied.text));
        continue;
      }

      // No active composition after this delta.
      if (delta is TextEditingDeltaInsertion) {
        if (delta.textInserted.isNotEmpty) {
          // Direct typing fires a keypress; an insertion that resolves a
          // composition is a commit (no keypress).
          _commitText(delta.textInserted, composed: _composing);
        }
      } else if (delta is TextEditingDeltaReplacement) {
        // A composition resolved to its final text (or autocorrect replaced a
        // word) — a commit, not a keypress. Commit only the replacement so
        // nothing double-commits.
        if (delta.replacementText.isNotEmpty) {
          _commitText(delta.replacementText, composed: true);
        } else if (_composing) {
          _controller.imeCancelComposition();
        }
      } else if (delta is TextEditingDeltaDeletion) {
        if (_composing) {
          // The composition was deleted away entirely.
          _controller.imeCancelComposition();
        }
        // Otherwise a plain backspace — the page handles it via the raw key
        // path; the relay buffer is empty so there is nothing to delete here.
      }
      _composing = false;
    }
    _resetScratch();
  }

  @override
  void updateEditingValue(TextEditingValue value) {
    // Fallback for platforms / paths that don't use the delta model.
    final composing = value.composing;
    if (composing.isValid &&
        !composing.isCollapsed &&
        composing.end <= value.text.length) {
      _composing = true;
      _editingState = value;
      _controller.imeSetComposition(composing.textInside(value.text));
      return;
    }
    final wasComposing = _composing;
    if (value.text.isNotEmpty) {
      _commitText(value.text, composed: wasComposing);
    } else if (_composing) {
      _controller.imeCancelComposition();
    }
    _composing = false;
    _editingState = _empty;
    _textInput?.setEditingState(_editingState);
  }

  // Deliberately returns the empty scratch state, never a real buffer: the page
  // (not Flutter) owns the text, so we keep `_editingState` as a fixed insertion
  // point for composition and never mirror the page's content back to the
  // framework. See `_editingState` / `_pushEditableGeometry`.
  @override
  TextEditingValue? get currentTextEditingValue => _editingState;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void performAction(TextInputAction action) {
    // Enter / Done is delivered to the page via the raw key path, not here.
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  void removeTextPlaceholder() {}

  @override
  void showToolbar() {}

  @override
  void connectionClosed() {
    _textInput = null;
    _composing = false;
    _editingState = _empty;
  }

  @override
  void performSelector(String selectorName) {
    // macOS doCommandBySelector (deleteBackward:, insertNewline:, moveLeft: …).
    // These keys also arrive on the raw key path ([_onKeyEvent]) and are
    // forwarded to the page there, so nothing to do here.
  }

  @override
  void insertContent(KeyboardInsertedContent content) {}

  @override
  void didChangeInputControl(
      TextInputControl? oldControl, TextInputControl? newControl) {}
}
