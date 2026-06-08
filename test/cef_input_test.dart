import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_cef/src/cef_input.dart';

void main() {
  group('cefWindowsKeyCode — editing/navigation keys resolve to Windows VK',
      () {
    // These are the codes CEF keys DOM behavior off of. Regressions here are
    // exactly the "backspace deletes nothing / arrows do nothing" class of bug.
    final expected = <LogicalKeyboardKey, int>{
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
    expected.forEach((key, vk) {
      test('${key.debugName} -> 0x${vk.toRadixString(16)}', () {
        expect(cefWindowsKeyCode(key), vk);
      });
    });
  });

  group('cefWindowsKeyCode — alphanumerics map to VK A-Z / 0-9', () {
    test('a -> VK_A (0x41), z -> VK_Z (0x5A)', () {
      expect(cefWindowsKeyCode(LogicalKeyboardKey.keyA), 0x41);
      expect(cefWindowsKeyCode(LogicalKeyboardKey.keyZ), 0x5A);
    });
    test('0 -> 0x30, 9 -> 0x39', () {
      expect(cefWindowsKeyCode(LogicalKeyboardKey.digit0), 0x30);
      expect(cefWindowsKeyCode(LogicalKeyboardKey.digit9), 0x39);
    });
    test('an unmapped printable (period) -> 0 (rides the CHAR event)', () {
      expect(cefWindowsKeyCode(LogicalKeyboardKey.period), 0);
    });
  });

  group('cefMacKeyCode — editing keys resolve from the native macOS keycode',
      () {
    final expected = <LogicalKeyboardKey, int>{
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
    expected.forEach((key, code) {
      test('${key.debugName} -> $code', () {
        expect(cefMacKeyCode(key), code);
      });
    });
    test('a printable key has no native override (-> null)', () {
      expect(cefMacKeyCode(LogicalKeyboardKey.keyA), isNull);
      expect(cefMacKeyCode(LogicalKeyboardKey.digit5), isNull);
    });
  });

  group('cefMacCharForKey — keys with a default action carry the NSEvent char',
      () {
    // A 0 here is the "Backspace deletes two / arrow moves two" CEF-OSR bug
    // (forum t=11650), and for Space the "focused button/checkbox won't
    // activate" bug: the host de-duplicates / Blink derives the activation key
    // only when character is non-zero.
    final expected = <LogicalKeyboardKey, int>{
      LogicalKeyboardKey.backspace: 0x7F,
      LogicalKeyboardKey.delete: 0xF728,
      LogicalKeyboardKey.tab: 0x09,
      LogicalKeyboardKey.enter: 0x0D,
      LogicalKeyboardKey.escape: 0x1B,
      LogicalKeyboardKey.space: 0x20, // activates a focused control
      LogicalKeyboardKey.arrowUp: 0xF700,
      LogicalKeyboardKey.arrowDown: 0xF701,
      LogicalKeyboardKey.arrowLeft: 0xF702,
      LogicalKeyboardKey.arrowRight: 0xF703,
    };
    expected.forEach((key, code) {
      test('${key.debugName} -> 0x${code.toRadixString(16)}', () {
        expect(cefMacCharForKey(key), code);
        expect(cefMacCharForKey(key), isNonZero); // the whole point
      });
    });
    test('printable keys carry no override char (-> 0; they ride the IME)', () {
      expect(cefMacCharForKey(LogicalKeyboardKey.keyA), 0);
      expect(cefMacCharForKey(LogicalKeyboardKey.digit5), 0);
    });
  });

  group('cefMacNativeKeyCode — physical key -> macOS keycode', () {
    test('digit 0 -> 29 (kVK_ANSI_0), NOT 48 (Tab) — the focus-move bug', () {
      expect(cefMacNativeKeyCode(PhysicalKeyboardKey.digit0), 29);
      expect(cefMacNativeKeyCode(PhysicalKeyboardKey.digit0), isNot(48));
    });
    test('no digit resolves to Tab (48)', () {
      final digits = [
        PhysicalKeyboardKey.digit0,
        PhysicalKeyboardKey.digit1,
        PhysicalKeyboardKey.digit2,
        PhysicalKeyboardKey.digit3,
        PhysicalKeyboardKey.digit4,
        PhysicalKeyboardKey.digit5,
        PhysicalKeyboardKey.digit6,
        PhysicalKeyboardKey.digit7,
        PhysicalKeyboardKey.digit8,
        PhysicalKeyboardKey.digit9,
      ];
      expect(digits.map(cefMacNativeKeyCode), isNot(contains(48)));
    });
    test('representative letters / whitespace map to their kVK codes', () {
      expect(cefMacNativeKeyCode(PhysicalKeyboardKey.keyA), 0);
      expect(cefMacNativeKeyCode(PhysicalKeyboardKey.keyZ), 6);
      expect(cefMacNativeKeyCode(PhysicalKeyboardKey.tab), 48);
      expect(cefMacNativeKeyCode(PhysicalKeyboardKey.space), 49);
      expect(cefMacNativeKeyCode(PhysicalKeyboardKey.backspace), 51);
      expect(cefMacNativeKeyCode(PhysicalKeyboardKey.enter), 36);
    });
  });

  group('cefMouseButton', () {
    test(
        'primary -> 0 (left)', () => expect(cefMouseButton(kPrimaryButton), 0));
    test('middle -> 1', () => expect(cefMouseButton(kMiddleMouseButton), 1));
    test('secondary -> 2 (right)',
        () => expect(cefMouseButton(kSecondaryButton), 2));
    test('none -> 0', () => expect(cefMouseButton(0), 0));
    test('secondary wins over middle when both set', () {
      expect(cefMouseButton(kSecondaryButton | kMiddleMouseButton), 2);
    });
  });

  group('cefButtonModifiers — button bits of the modifier mask', () {
    test('primary -> left flag', () {
      expect(cefButtonModifiers(kPrimaryButton), kCefEventFlagLeftMouseButton);
    });
    test('middle -> middle flag', () {
      expect(cefButtonModifiers(kMiddleMouseButton),
          kCefEventFlagMiddleMouseButton);
    });
    test('secondary -> right flag', () {
      expect(
          cefButtonModifiers(kSecondaryButton), kCefEventFlagRightMouseButton);
    });
    test('combined buttons OR together', () {
      expect(
        cefButtonModifiers(kPrimaryButton | kSecondaryButton),
        kCefEventFlagLeftMouseButton | kCefEventFlagRightMouseButton,
      );
    });
  });

  group('clampCefClickCount — Chromium only accepts 1..3', () {
    test('clamps below 1 up to 1', () {
      expect(clampCefClickCount(0), 1);
      expect(clampCefClickCount(-7), 1);
    });
    test('passes 1, 2, 3 through', () {
      expect(clampCefClickCount(1), 1);
      expect(clampCefClickCount(2), 2);
      expect(clampCefClickCount(3), 3);
    });
    test('clamps above 3 down to 3', () {
      expect(clampCefClickCount(4), 3);
      expect(clampCefClickCount(99), 3);
    });
  });

  group('cefCursorForType — cef_cursor_type_t -> Flutter cursor', () {
    test('known types', () {
      expect(cefCursorForType(1), SystemMouseCursors.precise);
      expect(cefCursorForType(2), SystemMouseCursors.click);
      expect(cefCursorForType(3), SystemMouseCursors.text);
      expect(cefCursorForType(4), SystemMouseCursors.wait);
      expect(cefCursorForType(5), SystemMouseCursors.help);
    });
    test('pointer (0) and unknown types fall back to basic', () {
      expect(cefCursorForType(0), SystemMouseCursors.basic);
      expect(cefCursorForType(9999), SystemMouseCursors.basic);
    });
  });
}
