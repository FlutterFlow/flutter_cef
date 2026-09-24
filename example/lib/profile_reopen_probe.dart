// A named profile reopened at once is not reported "locked" — END-TO-END probe
// (macOS).
//
// Auto-running, no-interaction regression test. Closing the last view of a named
// profile shuts its cef_host down, and the host holds the profile's lock until it
// has exited. A view of the same profile opened right after used to start a new
// host that found the lock still held and exited "locked", so the embedder
// treated the profile as open in another app. The plugin now waits for its own
// previous host to go and starts the new one again.
//
// Cases:
//   * close-and-reopen a named profile several times: every view paints and none
//     reports processGone;
//   * the ephemeral-profile sweep at startup keeps the dirs of running apps.
//     The run script plants `flutter_cef_ephem_1_probe` (pid 1 is always alive)
//     in $TMPDIR before launch; the probe checks it survived.
//
// A `CEF_PROBE_RESULT PASS|FAIL` line is printed to stdout at the end.
//
// Run:  mkdir -p "$TMPDIR/flutter_cef_ephem_1_probe"
//       FLUTTER_CEF_HOST=<.../cef_host.app/Contents/MacOS/cef_host> \
//         flutter run -d macos -t lib/profile_reopen_probe.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cef/flutter_cef.dart';

const _page = '<!doctype html><body style="background:#234"><h1>reopen</h1>';
const _profile = 'reopen_probe';
const _rounds = 6;

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

  Future<bool> _painted(CefWebController c) async {
    final sw = Stopwatch()..start();
    while (sw.elapsed.inSeconds < 15) {
      if (((await c.sessionStats())?.presentCount ?? 0) > 0) return true;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return false;
  }

  Future<void> _run() async {
    try {
      final planted = Directory(
        '${Directory.systemTemp.path}/flutter_cef_ephem_1_probe',
      );
      _check(
        'a running app\'s ephemeral dir survives the startup sweep',
        planted.existsSync(),
        planted.path,
      );

      final gone = <String>[];
      var painted = 0;
      for (var i = 0; i < _rounds; i++) {
        final c = CefWebController(profile: _profile)
          ..onProcessGone = (r) => gone.add('round $i: $r');
        await c.create(
          url: 'about:blank',
          html: _page,
          width: 320,
          height: 240,
        );
        if (await _painted(c)) painted++;
        // Dispose, then reopen with no pause: the old host is still exiting.
        await c.dispose();
      }
      _check('every reopened view painted', painted == _rounds, painted);
      _check('no reopen reported processGone', gone.isEmpty, gone);
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
