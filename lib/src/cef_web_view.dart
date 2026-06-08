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
/// Text input goes through the platform IME: while the view is focused it holds
/// a [TextInputConnection], so dead keys, CJK composition, and emoji all reach
/// the page (committed text is sent as full UTF-8, not a single UTF-16 unit).
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

class _CefWebViewState extends State<CefWebView>
    implements DeltaTextInputClient {
  late final CefWebController _controller =
      widget.controller ?? CefWebController();
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
    _controller.onImeCompositionBounds = _onImeCompositionBounds;
    _attachFocusListener();
  }

  @override
  void didUpdateWidget(CefWebView old) {
    super.didUpdateWidget(old);
    _attachFocusListener();
    if (old.url != widget.url && _textureId != null) {
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
    final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
    final w = size.width.round();
    final h = size.height.round();
    if (w <= 0 || h <= 0) return;
    if (_textureId == null && !_creating) {
      _creating = true;
      try {
        final id = await _controller.create(
            url: widget.url, width: w, height: h, dpr: dpr);
        _lastSize = size;
        if (mounted) setState(() => _textureId = id);
      } finally {
        _creating = false;
      }
      return;
    }
    if (_textureId != null && _lastSize != size) {
      _lastSize = size;
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
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      _controller.sendKey(
          type: 0,
          modifiers: mods,
          windowsKeyCode: wkc,
          nativeKeyCode: nkc,
          character: keyChar);
      // Fallback before the IME connection attaches: commit the character
      // ourselves (whole string -> surrogate-safe, not codeUnitAt(0)).
      if (isText && (_textInput == null || !_textInput!.attached)) {
        _controller.imeCommitText(ch);
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
      const TextInputConfiguration(
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

  /// Tell the platform where the editable lives (and, when composing, where the
  /// caret is) so the OS input context activates and positions the IME candidate
  /// window. The whole view is the "editable"; the caret rect comes from the
  /// page via [OnImeCompositionRangeChanged].
  void _pushEditableGeometry([Rect? caret]) {
    final conn = _textInput;
    if (conn == null || !conn.attached || !mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    conn
      ..setStyle(
        fontFamily: null,
        fontSize: 16,
        fontWeight: null,
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.left,
      )
      ..setEditableSizeAndTransform(box.size, box.getTransformTo(null));
    if (caret != null) {
      conn
        ..setComposingRect(caret)
        ..setCaretRect(caret);
    }
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
          _controller.imeCommitText(delta.textInserted);
        }
      } else if (delta is TextEditingDeltaReplacement) {
        // A composition resolved to its final text (or was edited to plain
        // text). Commit only the replacement so nothing double-commits.
        if (delta.replacementText.isNotEmpty) {
          _controller.imeCommitText(delta.replacementText);
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
    if (value.text.isNotEmpty) {
      _controller.imeCommitText(value.text);
    } else if (_composing) {
      _controller.imeCancelComposition();
    }
    _composing = false;
    _editingState = _empty;
    _textInput?.setEditingState(_editingState);
  }

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
