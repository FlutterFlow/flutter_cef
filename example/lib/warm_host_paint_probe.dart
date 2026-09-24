// A second view on a warm shared host paints — END-TO-END probe (macOS).
//
// Auto-running, no-interaction regression test. Consumers put several views on
// one shared host (FlutterFlow's code editors on one named profile, Campus's web
// tiles on one host group). Each round here starts a host group with an
// animating view, waits for it to paint, then opens a second view on that warm
// host and times its first frame. The views are disposed at the end of the
// round, so the next round starts a fresh host while the last one exits.
//
// Checks, over ROUNDS rounds (default 30): every second view presents a frame
// within LIMIT_MS (default 8000). A second view that never paints is the bug
// this guards: the host's first view took begin-frame source id 0, and a new
// view whose first begin frame landed while that view was mid-frame never got
// another one (see ClaimFirstBeginFrameSource in the host). Before the fix
// 10 to 25 percent of rounds failed. On a failure the probe logs whether a
// requestAnimationFrame callback runs in the stuck page, which tells begin frames
// not reaching the page apart from frames that are drawn but not delivered.
//
// A `CEF_PROBE_RESULT PASS|FAIL` line is printed to stdout at the end.
//
// Run:  FLUTTER_CEF_HOST=<.../cef_host.app/Contents/MacOS/cef_host> \
//         flutter run -d macos -t lib/warm_host_paint_probe.dart
//       [--dart-define=ROUNDS=30 --dart-define=LIMIT_MS=8000 --dart-define=KEEP=true]
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cef/flutter_cef.dart';

const _rounds = int.fromEnvironment('ROUNDS', defaultValue: 30);
const _limitMs = int.fromEnvironment('LIMIT_MS', defaultValue: 8000);
// KEEP keeps one first view, and so one host, across all rounds.
const _keep = bool.fromEnvironment('KEEP');

const _animated = '''<!doctype html><meta charset="utf-8">
<style>
  body { margin: 0; background: #111; }
  #s { width: 120px; height: 120px; margin: 20px; animation: spin 1s linear infinite;
       background: linear-gradient(90deg, #f43f5e, #3b82f6); }
  @keyframes spin { to { transform: rotate(360deg); } }
</style>
<div id="s"></div>''';

const _static = '''<!doctype html><body style="background:#234">
<h1 style="color:#fff">second view</h1>''';

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

  /// Milliseconds until [c] presents its first frame, or null if it hasn't
  /// within [limitMs].
  Future<int?> _firstFrame(CefWebController c, int limitMs) async {
    final sw = Stopwatch()..start();
    while (sw.elapsedMilliseconds < limitMs) {
      if (await _presents(c) > 0) return sw.elapsedMilliseconds;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return null;
  }

  Future<String> _eval(CefWebController c, String code) async {
    try {
      return '${await c.runJavaScriptReturningResult(code).timeout(const Duration(seconds: 3))}';
    } catch (e) {
      return 'eval failed: $e';
    }
  }

  /// Whether a requestAnimationFrame callback runs in [c]'s page within 500 ms,
  /// i.e. whether begin frames reach its renderer.
  Future<String> _raf(CefWebController c) async {
    await _eval(
      c,
      '(window.__raf = "no", requestAnimationFrame(() => { window.__raf = "yes"; }), "ok")',
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
    return _eval(
      c,
      'String(window.__raf) + " paints=" + performance.getEntriesByType("paint").map(e => e.name).join(",")',
    );
  }

  Future<void> _run() async {
    final host = Platform.environment['FLUTTER_CEF_HOST'];
    _check('FLUTTER_CEF_HOST is set', host != null && host.isNotEmpty, host);
    var failed = 0;
    final times = <int>[];
    final group = 'warm-host-paint-$pid';
    CefWebController? kept;
    for (var i = 1; i <= _rounds; i++) {
      final first = kept ?? CefWebController(hostGroup: group);
      CefWebController? second;
      try {
        if (kept == null) {
          await first.create(
            url: 'about:blank',
            html: _animated,
            width: 320,
            height: 240,
          );
        }
        if (_keep) kept = first;
        final t1 = await _firstFrame(first, 15000);
        if (t1 == null) {
          _check('round $i: the first view paints', false, 'no frame in 15 s');
          if (_keep) break;
          continue;
        }
        second = CefWebController(hostGroup: group);
        await second.create(
          url: 'about:blank',
          html: _static,
          width: 320,
          height: 240,
        );
        final t2 = await _firstFrame(second, _limitMs);
        if (t2 == null) {
          failed++;
          _log('round $i: stuck page rAF: ${await _raf(second)}');
          final late = await _firstFrame(second, 7000);
          _log(
            'round $i: second view: NO FRAME in ${_limitMs}ms '
            '(first view ${t1}ms; later: ${late == null ? "still none after 7 s more" : "+${late}ms"}; '
            'page: ${await _eval(second, 'document.readyState + " " + document.visibilityState')})',
          );
        } else {
          times.add(t2);
          _log(
            'round $i: first view ${t1}ms, second view ${t2}ms'
            '${i == 1 ? " (rAF: ${await _raf(second)})" : ""}',
          );
        }
      } catch (e, st) {
        _check('round $i: ran to completion', false, '$e\n$st');
      } finally {
        await second?.dispose();
        if (!_keep) await first.dispose();
      }
    }
    await kept?.dispose();
    times.sort();
    final median = times.isEmpty ? 0 : times[times.length ~/ 2];
    final max = times.isEmpty ? 0 : times.last;
    _log(
      'second view: $failed of $_rounds rounds never painted; '
      'painted rounds: median ${median}ms, max ${max}ms',
    );
    _check(
      'every second view on a warm host paints within ${_limitMs}ms',
      failed == 0,
      '$failed of $_rounds',
    );
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
