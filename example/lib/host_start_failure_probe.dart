// A cef_host that never becomes ready — END-TO-END probe (macOS).
//
// Auto-running, no-interaction regression test. Point FLUTTER_CEF_HOST at a
// binary that isn't cef_host:
//
//   EXITS (default) — FLUTTER_CEF_HOST=/usr/bin/false. The host exits before
//       connecting. An ephemeral session, a named-profile session and two
//       host-group sessions must each get onCreateFailed and
//       onProcessGone('createFailed') within 2 s, so a consumer can fall back.
//       Before the fix nothing was reported and the views stayed blank.
//   HANGS (--dart-define=CEF_PROBE_HOST_HANGS=true) — FLUTTER_CEF_HOST is a
//       script that sleeps and never connects. Disposing the session is prompt
//       and stops the host. Before the fix dispose blocked the main thread for
//       2 s on a reader stuck in accept().
//
// A `CEF_PROBE_RESULT PASS|FAIL` line is printed to stdout at the end.
//
// Run:  FLUTTER_CEF_HOST=/usr/bin/false \
//         flutter run -d macos -t lib/host_start_failure_probe.dart
//       printf '#!/bin/sh\nexec sleep 600\n' > /tmp/hang && chmod +x /tmp/hang
//       FLUTTER_CEF_HOST=/tmp/hang flutter run -d macos \
//         -t lib/host_start_failure_probe.dart \
//         --dart-define=CEF_PROBE_HOST_HANGS=true
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cef/flutter_cef.dart';

const _hostHangs = bool.fromEnvironment('CEF_PROBE_HOST_HANGS');

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

  /// Creates each of [controllers] and checks the host reports every create
  /// failed, promptly.
  Future<void> _expectCreateFailed(
      String kind, List<CefWebController> controllers) async {
    final failed = <Completer<Object>>[];
    final gone = <Completer<String>>[];
    for (final c in controllers) {
      final f = Completer<Object>();
      final g = Completer<String>();
      c.onCreateFailed = (e) {
        if (!f.isCompleted) f.complete(e);
      };
      c.onProcessGone = (r) {
        if (!g.isCompleted) g.complete(r);
      };
      failed.add(f);
      gone.add(g);
    }
    final sw = Stopwatch()..start();
    for (final c in controllers) {
      await c.create(url: 'about:blank', width: 320, height: 200);
    }
    const limit = Duration(seconds: 2);
    for (var i = 0; i < controllers.length; i++) {
      final reason = await gone[i].future
          .timeout(const Duration(seconds: 10), onTimeout: () => 'none');
      final elapsed = sw.elapsed;
      _check('$kind #$i: processGone is createFailed', reason == 'createFailed',
          reason);
      _check('$kind #$i: onCreateFailed called', failed[i].isCompleted);
      _check('$kind #$i: reported within $limit', elapsed < limit, elapsed);
    }
    for (final c in controllers) {
      final d = Stopwatch()..start();
      await c.dispose();
      _check('$kind: dispose is prompt',
          d.elapsed < const Duration(milliseconds: 500), d.elapsed);
    }
  }

  Future<Set<String>> _children(String name) async {
    final r = await Process.run('pgrep', ['-P', '$pid', '-x', name]);
    return (r.stdout as String)
        .trim()
        .split('\n')
        .where((l) => l.isNotEmpty)
        .toSet();
  }

  Future<void> _run() async {
    try {
      final host = Platform.environment['FLUTTER_CEF_HOST'];
      _check('FLUTTER_CEF_HOST is set', host != null && host.isNotEmpty, host);
      if (!_hostHangs) {
        await _expectCreateFailed('ephemeral', [CefWebController()]);
        await _expectCreateFailed(
            'profile', [CefWebController(profile: 'host-start-failure')]);
        await _expectCreateFailed('host group', [
          CefWebController(hostGroup: 'host-start-failure'),
          CefWebController(hostGroup: 'host-start-failure'),
        ]);
      } else {
        final c = CefWebController();
        final gone = <String>[];
        c.onProcessGone = gone.add;
        await c.create(url: 'about:blank', width: 320, height: 200);
        await Future<void>.delayed(const Duration(seconds: 1));
        _check('the host is running', (await _children('sleep')).isNotEmpty,
            await _children('sleep'));
        final d = Stopwatch()..start();
        await c.dispose();
        _check('dispose before the host connects is prompt',
            d.elapsed < const Duration(milliseconds: 500), d.elapsed);
        final sw = Stopwatch()..start();
        while ((await _children('sleep')).isNotEmpty &&
            sw.elapsed < const Duration(seconds: 5)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        _check('dispose stops the host', (await _children('sleep')).isEmpty,
            await _children('sleep'));
        _check('a clean dispose reports no processGone', gone.isEmpty, gone);
      }
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
