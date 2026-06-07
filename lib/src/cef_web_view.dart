import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'cef_input.dart';
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
  int _lastButton = 0;

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
    _focusNode.requestFocus();
    _lastButton = cefMouseButton(e.buttons);
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
    final wkc = cefWindowsKeyCode(event.logicalKey);
    // CEF on macOS resolves editing keys (backspace/delete/arrows/enter) from
    // the native macOS keycode, not the Windows VK; printable chars ride the
    // separate CHAR event.
    final nkc = cefMacKeyCode(event.logicalKey) ?? wkc;
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
}
