// ⌘-key routing END-TO-END probe (macOS).
//
// Auto-running, no-interaction self-test of what a code editor (Monaco) needs
// from the keyboard path. Drives the real cef_host through
// CefWebController.sendKey with the exact encodings CefWebView produces:
//
//   BARE ⌘     — a modifier pressed alone must reach the page as the Meta key.
//                Sent as keycode 0 (the old encoding) it IS the `A` key, so the
//                page saw ⌘A — shown here as the OLD-ENCODING control.
//   PAGE FIRST — a page that handles ⌘Z / ⌘A in keydown (preventDefault) gets
//                the event, and the browser's own command does NOT also run.
//   FALLBACK   — a page that doesn't handle them still gets select-all / undo /
//                redo (cef_host's OnKeyEvent), as in a real browser.
//
// A `CEF_PROBE_RESULT PASS|FAIL` line is printed to stdout at the end.
//
// Run:  flutter run -d macos -t lib/keyboard_shortcut_probe.dart
// ignore_for_file: invalid_use_of_internal_member
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cef/flutter_cef.dart';

const _cmd = 1 << 7; // EVENTFLAG_COMMAND_DOWN
const _shift = 1 << 1;

const _html = '''<!doctype html><html><head><title>kbd</title></head>
<body style="margin:0"><textarea id="t" style="width:380px;height:260px"></textarea>
<script>
window.keys = []; window.owned = 0; window.own = false;
document.addEventListener('keydown', function (e) {
  window.keys.push((e.metaKey ? 'M-' : '') + e.key + '/' + e.code);
  if (window.own && e.metaKey &&
      (e.code === 'KeyZ' || e.code === 'KeyA' || e.code === 'ArrowLeft')) {
    e.preventDefault(); window.owned++;
  }
}, true);
</script></body></html>''';

void main() => runApp(const ProbeApp());

class ProbeApp extends StatefulWidget {
  const ProbeApp({super.key});
  @override
  State<ProbeApp> createState() => _ProbeAppState();
}

class _ProbeAppState extends State<ProbeApp> {
  final List<String> _lines = [];
  final CefWebController _c = CefWebController();
  bool _pass = true;

  void _check(String name, bool cond, [Object? got]) {
    if (!cond) _pass = false;
    _log('${cond ? "PASS" : "FAIL"}  $name${cond ? "" : "  (got: $got)"}');
  }

  void _log(String s) {
    _lines.add(s);
    // ignore: avoid_print
    print('CEF_PROBE_LOG  $s');
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<Object?> _eval(String js) =>
      _c.runJavaScriptReturningResult(js).timeout(const Duration(seconds: 5));

  Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 250));

  void _key(int vk, int native, int ch, {int mods = 0}) {
    _c.sendKey(type: 0, modifiers: mods, windowsKeyCode: vk, nativeKeyCode: native, character: ch);
    _c.sendKey(type: 2, modifiers: mods, windowsKeyCode: vk, nativeKeyCode: native, character: ch);
  }

  void _type(String text) {
    for (final cp in text.codeUnits) {
      _c.sendKey(type: 3, windowsKeyCode: cp, character: cp);
    }
  }

  /// ⌘ down → [body] → ⌘ up, with the Command key encoded as CefWebView does.
  Future<void> _withCmd(Future<void> Function() body) async {
    _c.sendKey(type: 0, modifiers: _cmd, windowsKeyCode: 0x5B, nativeKeyCode: 55);
    await body();
    _c.sendKey(type: 2, windowsKeyCode: 0x5B, nativeKeyCode: 55);
    await _settle();
  }

  Future<int> _selected() async =>
      (await _eval('t.selectionEnd - t.selectionStart') as num).toInt();

  Future<void> _run() async {
    try {
      final sw = Stopwatch()..start();
      while (await _eval('document.title').catchError((_) => null) != 'kbd') {
        if (sw.elapsed > const Duration(seconds: 20)) throw StateError('page never loaded');
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      // Click into the textarea: gives the browser keyboard focus.
      _c.sendPointer(type: 1, x: 60, y: 60);
      _c.sendPointer(type: 2, x: 60, y: 60);
      await _settle();
      _type('abc');
      await _settle();
      _check('typed', await _eval('t.value') == 'abc', await _eval('t.value'));

      // --- OLD-ENCODING control: a bare ⌘ sent as keycode 0 IS ⌘A ---
      await _eval('window.keys = []');
      _c.sendKey(type: 0, modifiers: _cmd); // wkc 0, native 0, char 0
      _c.sendKey(type: 2);
      await _settle();
      _log('old encoding → page saw ${await _eval('window.keys.join(" ")')}, '
          'selected ${await _selected()} of 3');
      await _eval('t.setSelectionRange(3, 3)');

      // --- BARE ⌘, correctly encoded ---
      await _eval('window.keys = []');
      await _withCmd(() async {});
      final bare = '${await _eval('window.keys.join(" ")')}';
      _check('bare ⌘ reaches the page as the Meta key', bare.contains('Meta/MetaLeft'), bare);
      _check('bare ⌘ selects nothing', await _selected() == 0, await _selected());

      // --- FALLBACK: the page does not handle ⌘A / ⌘Z ---
      await _withCmd(() async => _key(0x41, 0, 0x61, mods: _cmd));
      _check('⌘A unhandled → browser select-all', await _selected() == 3, await _selected());
      await _eval('t.setSelectionRange(3, 3)');
      await _withCmd(() async => _key(0x5A, 6, 0x7A, mods: _cmd));
      final undone = '${await _eval('t.value')}';
      _check('⌘Z unhandled → browser undo', undone != 'abc', undone);
      await _withCmd(() async => _key(0x5A, 6, 0x7A, mods: _cmd | _shift));
      _check('⌘⇧Z unhandled → browser redo', await _eval('t.value') == 'abc', await _eval('t.value'));

      // --- PAGE FIRST: the page owns ⌘Z / ⌘A (an editor with its own stack) ---
      await _eval('(window.own = true, t.setSelectionRange(3, 3), 1)');
      await _withCmd(() async => _key(0x5A, 6, 0x7A, mods: _cmd));
      await _withCmd(() async => _key(0x41, 0, 0x61, mods: _cmd));
      _check('page received both', await _eval('window.owned') == 2, await _eval('window.owned'));
      _check('…and the browser undo did not also run', await _eval('t.value') == 'abc', await _eval('t.value'));
      _check('…nor the browser select-all', await _selected() == 0, await _selected());

      // --- macOS text-editing bindings in a PLAIN field (no page handler).
      // AppKit supplies these as edit commands in a windowed browser; cef_host
      // reads the same key-binding dict and attaches them to the keydown.
      await _eval('(window.own = false, t.value = "hello world foo", t.setSelectionRange(15, 15), 1)');
      const alt = 1 << 3;
      Future<void> chord(int mods, int modVk, int modNative, void Function() key) async {
        _c.sendKey(type: 0, modifiers: mods & ~_shift, windowsKeyCode: modVk, nativeKeyCode: modNative);
        key();
        _c.sendKey(type: 2, windowsKeyCode: modVk, nativeKeyCode: modNative);
        await _settle();
      }
      await chord(alt, 0x12, 58, () => _key(0x25, 123, 0xF702, mods: alt));
      _check('⌥← moves by word', await _eval('t.selectionStart') == 12, await _eval('t.selectionStart'));
      await chord(_cmd, 0x5B, 55, () => _key(0x25, 123, 0xF702, mods: _cmd));
      _check('⌘← moves to line start', await _eval('t.selectionStart') == 0, await _eval('t.selectionStart'));
      await chord(_cmd, 0x5B, 55, () => _key(0x27, 124, 0xF703, mods: _cmd));
      _check('⌘→ moves to line end', await _eval('t.selectionStart') == 15, await _eval('t.selectionStart'));
      await chord(alt | _shift, 0x12, 58, () => _key(0x25, 123, 0xF702, mods: alt | _shift));
      _check('⇧⌥← selects a word', await _selected() == 3, await _selected());
      await _eval('(t.setSelectionRange(15, 15), 1)');
      await chord(alt, 0x12, 58, () => _key(0x08, 51, 0x7F, mods: alt));
      _check('⌥⌫ deletes a word', await _eval('t.value') == 'hello world ', await _eval('t.value'));

      const ctrl = 1 << 2;
      await _eval('(t.value = "one two\\nthree four\\nfive", t.setSelectionRange(14, 14), 1)');
      await chord(_cmd | _shift, 0x5B, 55, () => _key(0x27, 124, 0xF703, mods: _cmd | _shift));
      _check('⇧⌘→ selects to line end', await _eval('t.selectionStart + ":" + t.selectionEnd') == '14:18',
          await _eval('t.selectionStart + ":" + t.selectionEnd'));
      await chord(_cmd, 0x5B, 55, () => _key(0x26, 126, 0xF700, mods: _cmd));
      _check('⌘↑ moves to document start', await _eval('t.selectionStart') == 0, await _eval('t.selectionStart'));
      await chord(_cmd, 0x5B, 55, () => _key(0x28, 125, 0xF701, mods: _cmd));
      _check('⌘↓ moves to document end', await _eval('t.selectionStart') == 23, await _eval('t.selectionStart'));
      await _eval('(t.setSelectionRange(14, 14), 1)');
      await chord(ctrl, 0x11, 59, () => _key(0x41, 0, 0x61, mods: ctrl));
      _check('⌃A moves to paragraph start', await _eval('t.selectionStart') == 8, await _eval('t.selectionStart'));
      await _eval('(t.setSelectionRange(14, 14), 1)');
      await chord(ctrl, 0x11, 59, () => _key(0x4B, 40, 0x6B, mods: ctrl));
      _check('⌃K kills to paragraph end', await _eval('t.value') == 'one two\nthree \nfive', await _eval('t.value'));
      await chord(_cmd, 0x5B, 55, () => _key(0x08, 51, 0x7F, mods: _cmd));
      _check('⌘⌫ deletes to line start', await _eval('t.value') == 'one two\n\nfive', await _eval('t.value'));

      // The page still comes first: an editor that owns ⌘← sees a normal keydown
      // and its preventDefault stops the bound command.
      await _eval('(window.own = true, window.owned = 0, window.keys = [], t.value = "abc def", t.setSelectionRange(7, 7), 1)');
      await chord(_cmd, 0x5B, 55, () => _key(0x25, 123, 0xF702, mods: _cmd));
      final seen = await _eval('window.keys.join(",")') as String;
      _check('page sees ⌘← as a real keydown', seen.contains('M-ArrowLeft/ArrowLeft'), seen);
      _check('page owns ⌘← → caret stays', await _eval('window.owned + ":" + t.selectionStart') == '1:7',
          await _eval('window.owned + ":" + t.selectionStart'));
    } catch (e) {
      _pass = false;
      _log('EXCEPTION  $e');
    }
    // ignore: avoid_print
    print('CEF_PROBE_RESULT ${_pass ? "PASS" : "FAIL"}');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(_pass ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Row(children: [
          SizedBox(width: 420, child: CefWebView(url: 'about:blank', html: _html, controller: _c)),
          Expanded(child: ListView(children: [for (final l in _lines) Text(l)])),
        ]),
      ),
    );
  }
}
