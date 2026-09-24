// A view that stops painting for good is reported — END-TO-END probe (macOS).
//
// Auto-running, no-interaction regression test. A browser that has painted and
// then can never paint again used to be accepted as an idle static page: no
// event, so the embedder never recreated it and the view stayed frozen. Two
// ways that happens, both seen under memory pressure:
//   * the GPU process dies. Chromium relaunches it, but off-screen frames never
//     come back, while JS keeps answering;
//   * the renderer hangs. It stops painting and stops answering JS.
// The plugin now ends such a host, so the embedder gets processGone("crashed")
// and recreates the view the way it recovers from a real crash.
//
// Cases, each on its own ephemeral host:
//   * an idle static page is left alone (no processGone in 35s);
//   * a page waiting on an open alert() is left alone (its renderer can't answer
//     the liveness ping, but it isn't hung), and answering the alert doesn't take
//     the host down;
//   * killing the GPU process reports processGone("crashed") within 10s;
//   * stopping the renderer (SIGSTOP) reports processGone("crashed") within 45s.
//
// A `CEF_PROBE_RESULT PASS|FAIL` line is printed to stdout at the end.
//
// Run:  FLUTTER_CEF_HOST=<.../cef_host.app/Contents/MacOS/cef_host> \
//         flutter run -d macos -t lib/wedge_recovery_probe.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cef/flutter_cef.dart';

const _animated = '''<!doctype html><meta charset="utf-8">
<style>
  body { margin: 0; background: #111; }
  #s { width: 160px; height: 160px; margin: 20px; animation: spin 1s linear infinite;
       background: linear-gradient(90deg, #f43f5e, #3b82f6); }
  @keyframes spin { to { transform: rotate(360deg); } }
</style>
<div id="s"></div>''';

const _static = '<!doctype html><body style="background:#123"><h1>static</h1>';

const _alerting =
    '<!doctype html><body style="background:#321"><h1>alert</h1>'
    '<script>setTimeout(() => alert("open"), 300)</script>';

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

  Future<int?> _pgrep(List<String> args) async {
    final r = await Process.run('pgrep', args);
    final pids = '${r.stdout}'.trim().split('\n').where((l) => l.isNotEmpty);
    return pids.isEmpty ? null : int.parse(pids.last);
  }

  /// This app's newest cef_host, and that host's helper of [type].
  Future<int?> _helper(String type) async {
    final host = await _pgrep(['-n', '-P', '$pid', '-x', 'cef_host']);
    if (host == null) return null;
    return _pgrep(['-P', '$host', '-f', 'type=$type']);
  }

  /// Creates a view on [html], waits for it to paint, and returns it with a
  /// future that completes with the first processGone reason.
  Future<(CefWebController, Future<String>)> _open(
    String html, {
    Future<void> Function(CefJsDialogRequest)? onAlert,
  }) async {
    final c = CefWebController()..onJavaScriptAlertDialog = onAlert;
    final gone = Completer<String>();
    c.onProcessGone = (reason) {
      if (!gone.isCompleted) gone.complete(reason);
    };
    await c.create(url: 'about:blank', html: html, width: 320, height: 240);
    final sw = Stopwatch()..start();
    while (((await c.sessionStats())?.presentCount ?? 0) <= 0 &&
        sw.elapsed.inSeconds < 15) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return (c, gone.future);
  }

  Future<String?> _goneWithin(Future<String> gone, Duration d) =>
      gone.then<String?>((r) => r).timeout(d, onTimeout: () => null);

  Future<void> _run() async {
    try {
      final host = Platform.environment['FLUTTER_CEF_HOST'];
      _check('FLUTTER_CEF_HOST is set', host != null && host.isNotEmpty, host);

      var (c, gone) = await _open(_static);
      final idle = await _goneWithin(gone, const Duration(seconds: 35));
      _check('an idle static page is left alone', idle == null, idle);
      await c.dispose();

      final alertOpen = Completer<void>();
      final answer = Completer<void>();
      (c, gone) = await _open(
        _alerting,
        onAlert: (_) {
          if (!alertOpen.isCompleted) alertOpen.complete();
          return answer.future;
        },
      );
      await alertOpen.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => _check('the alert opened', false),
      );
      final waiting = await _goneWithin(gone, const Duration(seconds: 35));
      _check(
        'a page waiting on an alert is left alone',
        waiting == null,
        waiting,
      );
      answer.complete();
      final answered = await _goneWithin(gone, const Duration(seconds: 3));
      _check(
        'answering the alert leaves the host up',
        answered == null,
        answered,
      );
      await c.dispose();

      (c, gone) = await _open(_animated);
      final gpu = await _helper('gpu-process');
      _check('found the GPU process', gpu != null);
      if (gpu != null) Process.killPid(gpu, ProcessSignal.sigkill);
      final afterGpu = await _goneWithin(gone, const Duration(seconds: 10));
      _check(
        'a killed GPU process reports processGone(crashed)',
        afterGpu == 'crashed',
        afterGpu,
      );
      await c.dispose();

      (c, gone) = await _open(_animated);
      final renderer = await _helper('renderer');
      _check('found the renderer', renderer != null);
      if (renderer != null) Process.killPid(renderer, ProcessSignal.sigstop);
      final afterHang = await _goneWithin(gone, const Duration(seconds: 45));
      _check(
        'a hung renderer reports processGone(crashed)',
        afterHang == 'crashed',
        afterHang,
      );
      if (renderer != null) Process.killPid(renderer, ProcessSignal.sigcont);
      await c.dispose();
    } catch (e, st) {
      _check('probe ran to completion', false, '$e\n$st');
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
