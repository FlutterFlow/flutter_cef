/// Pure mappings between Flutter input and CEF wire values.
///
/// Kept free of widget/runtime state so they can be unit-tested in isolation —
/// the keycode tables in particular are the historically fragile part (editing
/// keys like backspace/delete/arrows resolve from the macOS *native* keycode,
/// while DOM-level handling keys off the Windows virtual-key code).
library;

import 'package:flutter/gestures.dart'
    show kPrimaryButton, kSecondaryButton, kMiddleMouseButton;
import 'package:flutter/services.dart';

// ── CEF event flags (cef_event_flags_t) ──────────────────────────────────
const int kCefEventFlagShiftDown = 1 << 1;
const int kCefEventFlagControlDown = 1 << 2;
const int kCefEventFlagAltDown = 1 << 3;
const int kCefEventFlagLeftMouseButton = 1 << 4;
const int kCefEventFlagMiddleMouseButton = 1 << 5;
const int kCefEventFlagRightMouseButton = 1 << 6;
const int kCefEventFlagCommandDown = 1 << 7;

// ── Pointer ──────────────────────────────────────────────────────────────

/// CEF `cef_mouse_button_type_t`: 0=left, 1=middle, 2=right — from a Flutter
/// pointer `buttons` bitmask.
int cefMouseButton(int flutterButtons) {
  if (flutterButtons & kSecondaryButton != 0) return 2;
  if (flutterButtons & kMiddleMouseButton != 0) return 1;
  return 0;
}

/// The mouse-button bits of a CEF modifier mask, from a Flutter `buttons` mask.
int cefButtonModifiers(int flutterButtons) {
  var m = 0;
  if (flutterButtons & kPrimaryButton != 0) m |= kCefEventFlagLeftMouseButton;
  if (flutterButtons & kMiddleMouseButton != 0) m |= kCefEventFlagMiddleMouseButton;
  if (flutterButtons & kSecondaryButton != 0) m |= kCefEventFlagRightMouseButton;
  return m;
}

/// Chromium only accepts a click count of 1, 2, or 3; anything else breaks
/// double/triple-click selection. (CefSharp #3940.)
int clampCefClickCount(int n) => n < 1 ? 1 : (n > 3 ? 3 : n);

// ── Keyboard ─────────────────────────────────────────────────────────────

/// macOS virtual keycodes (`kVK_*`) for keys whose editing behavior CEF derives
/// from the native code rather than the Windows VK. Printable characters ride
/// the separate CHAR event and are not in this table.
final Map<LogicalKeyboardKey, int> kCefMacKeyCodes = <LogicalKeyboardKey, int>{
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

/// Windows virtual-key codes for keys CEF resolves by VK (editing/navigation
/// keys and the alphanumerics). DOM `KeyboardEvent.keyCode` follows these.
final Map<LogicalKeyboardKey, int> kCefSpecialWindowsKeyCodes =
    <LogicalKeyboardKey, int>{
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

/// The macOS native keycode for [key], or null if it's not an editing key whose
/// behavior CEF derives natively.
int? cefMacKeyCode(LogicalKeyboardKey key) => kCefMacKeyCodes[key];

/// The Windows virtual-key code for [key]: the special-key table first, then
/// a→VK_A..z→VK_Z, A–Z, and 0–9. 0 if unmapped (a printable that rides CHAR).
int cefWindowsKeyCode(LogicalKeyboardKey key) {
  final special = kCefSpecialWindowsKeyCodes[key];
  if (special != null) return special;
  final id = key.keyId;
  if (id >= 0x61 && id <= 0x7A) return id - 0x20; // a-z -> VK A-Z
  if (id >= 0x41 && id <= 0x5A) return id; // A-Z
  if (id >= 0x30 && id <= 0x39) return id; // 0-9
  return 0;
}

// ── Cursor ───────────────────────────────────────────────────────────────

/// Map a CEF `cef_cursor_type_t` to a Flutter [MouseCursor] (the common ones;
/// everything else falls back to [SystemMouseCursors.basic]).
MouseCursor cefCursorForType(int cefCursorType) {
  switch (cefCursorType) {
    case 1:
      return SystemMouseCursors.precise; // CT_CROSS
    case 2:
      return SystemMouseCursors.click; // CT_HAND
    case 3:
      return SystemMouseCursors.text; // CT_IBEAM
    case 4:
      return SystemMouseCursors.wait; // CT_WAIT
    case 5:
      return SystemMouseCursors.help; // CT_HELP
    default:
      return SystemMouseCursors.basic;
  }
}
