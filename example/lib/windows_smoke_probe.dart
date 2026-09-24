// Windows runtime smoke test — END-TO-END probe (Windows, run by CI).
//
// Auto-running, no-interaction. The windows-build CI job builds the example
// with this entry point and runs it against the cef_host it just built, so a
// change that compiles but can't paint, round-trip or recover fails CI instead
// of merging. It checks, on one view:
//   * the first frame reaches the texture (sessionStats().presentCount > 0) —
//     on a CI runner there is no GPU, so this also covers the software paint
//     path;
//   * runJavaScriptReturningResult and a JS channel round-trip;
//   * a resize is followed by frames at the new size;
//   * setAudioMuted / setFrameInterval are accepted, and a verb Windows can't
//     serve fails with PlatformException('unsupported');
//   * freeze() then thaw() brings frames back on the same texture;
//   * dispose.
//
// The result is a `CEF_PROBE_RESULT PASS|FAIL` line on stdout and, because a
// Windows GUI app's stdout isn't reliably captured, also in the file named by
// the FLUTTER_CEF_PROBE_OUT env var when it is set.
//
// Run:  flutter build windows --debug -t lib/windows_smoke_probe.dart
//       set FLUTTER_CEF_PROBE_OUT=%TEMP%\smoke.txt
//       build\windows\x64\runner\Debug\flutter_cef_example.exe
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cef/flutter_cef.dart';

// Animates on the compositor, so a visible page presents every frame.
const _html = '''<!doctype html><meta charset="utf-8">
<style>
  body { margin: 0; background: #111; }
  #s { width: 120px; height: 120px; margin: 20px; animation: spin 1s linear infinite;
       background: linear-gradient(90deg, #f43f5e, #3b82f6); }
  @keyframes spin { to { transform: rotate(360deg); } }
</style>
<div id="s"></div>''';

void main() => runApp(const MaterialApp(home: ProbeApp()));

class ProbeApp extends StatefulWidget {
  const ProbeApp({super.key});
  @override
  State<ProbeApp> createState() => _ProbeAppState();
}

class _ProbeAppState extends State<ProbeApp> {
  final List<String> _lines = [];
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

  Future<int> _presents(CefWebController c) async =>
      (await c.sessionStats())?.presentCount ?? -1;

  /// Waits until [c] has presented more than [floor] frames.
  Future<bool> _presentsPast(CefWebController c, int floor,
      {Duration within = const Duration(seconds: 30)}) async {
    final sw = Stopwatch()..start();
    while (sw.elapsed < within) {
      if (await _presents(c) > floor) return true;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return false;
  }

  Future<void> _run() async {
    final c = CefWebController();
    var gone = '';
    c.onProcessGone = (reason) => gone = reason;
    try {
      final received = Completer<String>();
      await c.addJavaScriptChannel('smoke', onMessageReceived: (m) {
        if (!received.isCompleted) received.complete(m);
      });
      final texture = await c.create(
          url: 'about:blank', html: _html, width: 320, height: 240);
      _check('create returns a texture', texture != null, texture);

      // A cold CEF start on a CI runner (no GPU) can take a while.
      _check(
          'first frame reaches the texture',
          await _presentsPast(c, 0, within: const Duration(seconds: 90)),
          await c.sessionStats());
      final stats = await c.sessionStats();
      _check('sessionStats reports the first present',
          stats != null && stats.firstPresentSeen && !stats.frozen, stats);

      final two = await c
          .runJavaScriptReturningResult('1 + 1')
          .timeout(const Duration(seconds: 10));
      _check('eval round-trip', '$two' == '2', two);

      await c.executeJavaScript('smoke.postMessage("hello")');
      final msg = await received.future
          .timeout(const Duration(seconds: 10), onTimeout: () => '<timeout>');
      _check('JS channel round-trip', msg == 'hello', msg);

      await c.resize(400, 300);
      final beforeResize = await _presents(c);
      var resized = false;
      final sw = Stopwatch()..start();
      while (!resized && sw.elapsed.inSeconds < 15) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final surface = await c.getFrameSurface();
        resized = await _presents(c) > beforeResize &&
            surface != null &&
            surface.width == 400 &&
            surface.height == 300;
      }
      _check('frames at the new size after resize', resized,
          await c.getFrameSurface());

      await c.setAudioMuted(true);
      await c.setFrameInterval(33);
      _check('setAudioMuted / setFrameInterval accepted', true);

      Object? unsupported;
      try {
        await c.showEmojiPicker();
      } catch (e) {
        unsupported = e;
      }
      _check(
          'an unsupported verb fails as unsupported',
          unsupported is PlatformException && unsupported.code == 'unsupported',
          unsupported);

      _check('freeze', await c.freeze(), await c.sessionStats());
      _check('sessionStats says frozen',
          (await c.sessionStats())?.frozen == true, await c.sessionStats());
      final frozenAt = await _presents(c);
      _check('thaw', await c.thaw(), await c.sessionStats());
      _check('frames resume after thaw', await _presentsPast(c, frozenAt),
          await c.sessionStats());

      _check('no processGone', gone.isEmpty, gone);
    } catch (e, st) {
      _check('probe ran to completion', false, '$e\n$st');
    }
    await c.dispose();
    _finish();
  }

  void _finish() {
    final result = 'CEF_PROBE_RESULT ${_pass ? "PASS" : "FAIL"}';
    // ignore: avoid_print
    print(result);
    final out = Platform.environment['FLUTTER_CEF_PROBE_OUT'];
    if (out != null && out.isNotEmpty) {
      File(out).writeAsStringSync('${_lines.join('\n')}\n$result\n');
    }
    Future<void>.delayed(const Duration(milliseconds: 300))
        .then((_) => exit(_pass ? 0 : 1));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListView(
        children: [
          for (final l in _lines) Text(l, style: const TextStyle(fontSize: 11)),
        ],
      ),
    );
  }
}
