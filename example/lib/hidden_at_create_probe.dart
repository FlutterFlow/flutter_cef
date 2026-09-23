// A view hidden right after create() — END-TO-END probe (macOS).
//
// Auto-running, no-interaction regression test. A consumer that mounts a view
// out of sight (a preview warming up offscreen, a culled tile) calls
// `setVisible(false)` as soon as `create()` returns. cef_host registers a
// browser's slot only as it creates the browser, and used to DROP a hide that
// arrived before that — always on a cold host, where control frames go out at
// connect and creates at ready — so the page kept painting while the plugin
// believed it hidden. The plugin now re-sends the hide when the host reports
// the browser created.
//
// Each case loads a continuously animating page, hides it the moment create()
// returns, and checks:
//   * no frames arrive while hidden (sessionStats().presentCount holds still)
//     and the page sees `document.visibilityState == "hidden"`;
//   * after setVisible(true) frames resume and the page is visible again.
// Cases: an ephemeral session (its own, cold host) and a session created on a
// warm host (a host group whose first view is already painting).
//
// A `CEF_PROBE_RESULT PASS|FAIL` line is printed to stdout at the end.
//
// Run:  FLUTTER_CEF_HOST=<.../cef_host.app/Contents/MacOS/cef_host> \
//         flutter run -d macos -t lib/hidden_at_create_probe.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cef/flutter_cef.dart';

// Animates on the compositor (a spinning square) and on the main thread (a
// requestAnimationFrame loop), so a visible page presents every frame.
const _html = '''<!doctype html><meta charset="utf-8">
<style>
  body { margin: 0; background: #111; }
  #s { width: 160px; height: 160px; margin: 20px; animation: spin 1s linear infinite;
       background: linear-gradient(90deg, #f43f5e, #3b82f6); }
  @keyframes spin { to { transform: rotate(360deg); } }
</style>
<div id="s"></div>
<script>(function f() { requestAnimationFrame(f); })();</script>''';

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

  Future<String> _visibility(CefWebController c) async {
    try {
      final r = await c
          .runJavaScriptReturningResult('document.visibilityState')
          .timeout(const Duration(seconds: 5));
      return '$r';
    } catch (e) {
      return 'eval failed: $e';
    }
  }

  /// Creates [c] on the animating page, hides it the moment create() returns,
  /// and checks it stays dark until shown again.
  Future<void> _hiddenAtCreate(String kind, CefWebController c) async {
    final texture =
        await c.create(url: 'about:blank', html: _html, width: 320, height: 240);
    await c.setVisible(false);
    _check('$kind: created', texture != null, texture);
    // Let the hide land and anything already in flight drain.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final before = await _presents(c);
    await Future<void>.delayed(const Duration(seconds: 3));
    final after = await _presents(c);
    _log('$kind: presents while hidden $before -> $after');
    _check('$kind: no frames while hidden', after == before, after - before);
    final hidden = await _visibility(c);
    _check('$kind: the page is hidden', hidden.contains('hidden'), hidden);

    await c.setVisible(true);
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    final shown = await _presents(c);
    _log('$kind: presents after show $after -> $shown');
    _check('$kind: frames resume once shown', shown - after > 10, shown - after);
    final visible = await _visibility(c);
    _check('$kind: the page is visible', visible.contains('visible'), visible);
  }

  Future<void> _run() async {
    final controllers = <CefWebController>[];
    try {
      final host = Platform.environment['FLUTTER_CEF_HOST'];
      _check('FLUTTER_CEF_HOST is set', host != null && host.isNotEmpty, host);

      // Its own cef_host, started by this create.
      final cold = CefWebController();
      controllers.add(cold);
      await _hiddenAtCreate('cold host', cold);

      // A host already serving a painting view.
      final group = 'hidden-at-create-$pid';
      final anchor = CefWebController(hostGroup: group);
      controllers.add(anchor);
      await anchor.create(
          url: 'about:blank', html: _html, width: 320, height: 240);
      final sw = Stopwatch()..start();
      while (await _presents(anchor) <= 0 && sw.elapsed.inSeconds < 15) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      _check('warm host: first view painting', await _presents(anchor) > 0);
      final warm = CefWebController(hostGroup: group);
      controllers.add(warm);
      await _hiddenAtCreate('warm host', warm);
    } catch (e, st) {
      _check('probe ran to completion', false, '$e\n$st');
    }
    for (final c in controllers) {
      await c.dispose();
    }
    // ignore: avoid_print
    print('CEF_PROBE_RESULT ${_pass ? "PASS" : "FAIL"}');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(_pass ? 0 : 1);
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
