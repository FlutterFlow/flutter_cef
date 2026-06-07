import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'cef_web_controller.dart';

/// A live Chromium (CEF) browser rendered into a Flutter [Texture].
///
/// The page renders off-screen in a `cef_host` subprocess and is shown here as
/// a texture (so it composites, transforms, and clips like any widget — unlike
/// a platform view). Pointer + keyboard input is forwarded by coordinate, and
/// the page's cursor drives a [MouseRegion]. macOS only.
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
  });

  /// Page to load. Changing it on an existing view navigates.
  final String url;

  /// Optional external controller (to script the view). If null, one is created
  /// and owned internally.
  final CefWebController? controller;

  /// Optional focus node. Provide one when an outer surface manages focus
  /// (e.g. a canvas tile); otherwise the view creates and owns its own.
  final FocusNode? focusNode;

  /// Shown until the first frame arrives. Defaults to a dark blank box.
  final Widget? placeholder;

  @override
  State<CefWebView> createState() => _CefWebViewState();
}

class _CefWebViewState extends State<CefWebView> {
  late final CefWebController _controller =
      widget.controller ?? CefWebController();
  bool _ownsController = false;
  FocusNode? _ownFocusNode;
  int? _textureId;
  Size? _lastSize;
  bool _creating = false;

  FocusNode get _focusNode =>
      widget.focusNode ?? (_ownFocusNode ??= FocusNode(debugLabel: 'cef'));

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
  }

  @override
  void didUpdateWidget(CefWebView old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url && _textureId != null) {
      _controller.navigate(widget.url);
    }
  }

  Future<void> _ensureSession(Size size) async {
    final w = size.width.round();
    final h = size.height.round();
    if (w <= 0 || h <= 0) return;
    if (_textureId == null && !_creating) {
      _creating = true;
      try {
        final id =
            await _controller.create(url: widget.url, width: w, height: h);
        _lastSize = size;
        if (mounted) setState(() => _textureId = id);
      } finally {
        _creating = false;
      }
      return;
    }
    if (_textureId != null && _lastSize != size) {
      _lastSize = size;
      _controller.resize(w, h);
    }
  }

  @override
  void dispose() {
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
            builder: (context, cursor, child) =>
                MouseRegion(cursor: cursor, child: child),
            child: Focus(
              focusNode: _focusNode,
              onKeyEvent: _onKeyEvent,
              child: Listener(
                onPointerDown: _onPointerDown,
                onPointerMove: _onPointerMove,
                onPointerHover: _onPointerHover,
                onPointerUp: _onPointerUp,
                onPointerSignal: _onPointerSignal,
                child: Texture(textureId: id),
              ),
            ),
          ),
        );
      },
    );
  }

  // ── input forwarding ──────────────────────────────────────────────
  // CEF event flags.
  static const int _evShift = 1 << 1, _evCtrl = 1 << 2, _evAlt = 1 << 3;
  static const int _evLeftBtn = 1 << 4, _evMidBtn = 1 << 5, _evRightBtn = 1 << 6;
  static const int _evCommand = 1 << 7;
  int _lastButton = 0;

  int _cefButton(int buttons) {
    if (buttons & kSecondaryButton != 0) return 2;
    if (buttons & kMiddleMouseButton != 0) return 1;
    return 0;
  }

  int _cefModifiers([int buttons = 0]) {
    final keys = HardwareKeyboard.instance;
    var m = 0;
    if (keys.isShiftPressed) m |= _evShift;
    if (keys.isControlPressed) m |= _evCtrl;
    if (keys.isAltPressed) m |= _evAlt;
    if (keys.isMetaPressed) m |= _evCommand;
    if (buttons & kPrimaryButton != 0) m |= _evLeftBtn;
    if (buttons & kMiddleMouseButton != 0) m |= _evMidBtn;
    if (buttons & kSecondaryButton != 0) m |= _evRightBtn;
    return m;
  }

  void _onPointerDown(PointerDownEvent e) {
    _focusNode.requestFocus();
    _lastButton = _cefButton(e.buttons);
    _controller.sendPointer(
        type: 1,
        x: e.localPosition.dx,
        y: e.localPosition.dy,
        button: _lastButton,
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

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    final mods = _cefModifiers();
    final wkc = _windowsKeyCode(event.logicalKey);
    // CEF on macOS resolves editing keys (backspace/delete/arrows/enter) from
    // the native macOS keycode, not the Windows VK; printable chars ride the
    // separate CHAR event.
    final nkc = _macKeyCode[event.logicalKey] ?? wkc;
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      _controller.sendKey(
          type: 0, modifiers: mods, windowsKeyCode: wkc, nativeKeyCode: nkc);
      final ch = event.character;
      if (ch != null && ch.isNotEmpty && ch.codeUnitAt(0) >= 0x20) {
        _controller.sendKey(
            type: 3,
            modifiers: mods,
            windowsKeyCode: wkc,
            nativeKeyCode: nkc,
            character: ch.codeUnitAt(0));
      }
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent) {
      _controller.sendKey(
          type: 2, modifiers: mods, windowsKeyCode: wkc, nativeKeyCode: nkc);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // macOS virtual keycodes (kVK_*) for keys whose editing behavior CEF derives
  // from the native code.
  static final Map<LogicalKeyboardKey, int> _macKeyCode = {
    LogicalKeyboardKey.backspace: 51,
    LogicalKeyboardKey.delete: 117,
    LogicalKeyboardKey.enter: 36,
    LogicalKeyboardKey.numpadEnter: 76,
    LogicalKeyboardKey.tab: 48,
    LogicalKeyboardKey.escape: 53,
    LogicalKeyboardKey.space: 49,
    LogicalKeyboardKey.arrowLeft: 123,
    LogicalKeyboardKey.arrowRight: 124,
    LogicalKeyboardKey.arrowDown: 125,
    LogicalKeyboardKey.arrowUp: 126,
    LogicalKeyboardKey.home: 115,
    LogicalKeyboardKey.end: 119,
    LogicalKeyboardKey.pageUp: 116,
    LogicalKeyboardKey.pageDown: 121,
  };

  static final Map<LogicalKeyboardKey, int> _specialVk = {
    LogicalKeyboardKey.backspace: 0x08,
    LogicalKeyboardKey.tab: 0x09,
    LogicalKeyboardKey.enter: 0x0D,
    LogicalKeyboardKey.numpadEnter: 0x0D,
    LogicalKeyboardKey.escape: 0x1B,
    LogicalKeyboardKey.space: 0x20,
    LogicalKeyboardKey.pageUp: 0x21,
    LogicalKeyboardKey.pageDown: 0x22,
    LogicalKeyboardKey.end: 0x23,
    LogicalKeyboardKey.home: 0x24,
    LogicalKeyboardKey.arrowLeft: 0x25,
    LogicalKeyboardKey.arrowUp: 0x26,
    LogicalKeyboardKey.arrowRight: 0x27,
    LogicalKeyboardKey.arrowDown: 0x28,
    LogicalKeyboardKey.delete: 0x2E,
  };

  int _windowsKeyCode(LogicalKeyboardKey key) {
    final s = _specialVk[key];
    if (s != null) return s;
    final id = key.keyId;
    if (id >= 0x61 && id <= 0x7A) return id - 0x20; // a-z -> VK A-Z
    if (id >= 0x41 && id <= 0x5A) return id; // A-Z
    if (id >= 0x30 && id <= 0x39) return id; // 0-9
    return 0;
  }
}
