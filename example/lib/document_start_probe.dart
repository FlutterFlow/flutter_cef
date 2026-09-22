// Document-start scripts, create-time JS channels and host groups — END-TO-END
// probe (macOS; the Windows host implements the same contract).
//
// Auto-running, no-interaction self-test of what the FlutterFlow Test Mode
// preview needs from flutter_cef:
//
//   DOC START  — a `documentStartScripts` entry runs before the page's first
//                <head> script, on the first document AND after navigating to
//                another (cross-site → new renderer process) origin.
//   CHANNELS   — a JS channel registered before create is callable from that
//                first <head> script (no load-start race).
//   ISOLATION  — a throwing document-start script is reported to the console
//                and the scripts after it still run.
//   HOST GROUP — two views in one `hostGroup` share ONE cef_host process, which
//                outlives either view alone and exits with the last.
//   LARGE HTML — a 3 MB authored document served at a synthetic https origin
//                (past Chromium's 2 MB data: URL cap) loads.
//
// A `CEF_PROBE_RESULT PASS|FAIL` line is printed to stdout at the end.
//
// Run:  flutter run -d macos -t lib/document_start_probe.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cef/flutter_cef.dart';

const _docStart = '''
window.__ds = (window.__ds || 0) + 1;
window.__dsScriptsSeen = document.scripts.length;
''';

String _page(String title) => '''<!doctype html><html><head><title>$title</title>
<script>
window.__pageSawDocStart = window.__ds;
window.__channelType = typeof window.probe;
try { probe.postMessage('early:$title:' + window.__ds); }
catch (e) { window.__postError = String(e); }
</script></head><body>$title</body></html>''';

void main() => runApp(const MaterialApp(home: ProbeApp()));

class ProbeApp extends StatefulWidget {
  const ProbeApp({super.key});
  @override
  State<ProbeApp> createState() => _ProbeAppState();
}

class _ProbeAppState extends State<ProbeApp> {
  final List<String> _lines = [];
  final List<String> _messages = [];
  final List<String> _console = [];
  bool _pass = true;

  late final CefWebController _a =
      CefWebController(documentStartScripts: const [_docStart]);

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
    // Registered BEFORE the view creates the session: rides in at create.
    _a.addJavaScriptChannel('probe', onMessageReceived: _messages.add);
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<Object?> _eval(CefWebController c, String js) =>
      c.runJavaScriptReturningResult(js).timeout(const Duration(seconds: 5));

  Future<void> _waitTitle(CefWebController c, String title) async {
    final sw = Stopwatch()..start();
    while (await _eval(c, 'document.title').catchError((_) => null) != title) {
      if (sw.elapsed > const Duration(seconds: 20)) {
        throw StateError('"$title" never loaded');
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  }

  Future<void> _waitFor(bool Function() cond) async {
    final sw = Stopwatch()..start();
    while (!cond() && sw.elapsed < const Duration(seconds: 5)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  // PIDs of the cef_host processes spawned by THIS app (helpers are named
  // differently). Tracked by pid, not count: an earlier view's host may still be
  // shutting down.
  Future<Set<String>> _hosts() async {
    final r = await Process.run('pgrep', ['-P', '$pid', '-x', 'cef_host']);
    return (r.stdout as String).trim().split('\n').where((l) => l.isNotEmpty).toSet();
  }

  Future<void> _run() async {
    try {
      // ── DOC START + CHANNELS, first document ────────────────────────────
      await _waitTitle(_a, 'one');
      _check('doc-start ran before the first <head> script',
          await _eval(_a, 'window.__pageSawDocStart') == 1,
          await _eval(_a, 'window.__pageSawDocStart'));
      _check('doc-start ran before any <script> was parsed',
          await _eval(_a, 'window.__dsScriptsSeen') == 0,
          await _eval(_a, 'window.__dsScriptsSeen'));
      _check('create-time channel exists for the first <head> script',
          await _eval(_a, 'window.__channelType') == 'object',
          await _eval(_a, 'window.__channelType + " " + window.__postError'));
      await _waitFor(() => _messages.contains('early:one:1'));
      _check('early post from the first <head> script reached Dart',
          _messages.contains('early:one:1'), _messages);

      // ── cross-site navigation (a new renderer process) ─────────────────
      await _a.loadHtmlString(_page('two'), baseUrl: 'https://ds-two.invalid/');
      await _waitTitle(_a, 'two');
      _check('doc-start ran again on a cross-site document',
          await _eval(_a, 'window.__pageSawDocStart') == 1,
          await _eval(_a, 'window.__pageSawDocStart'));
      await _waitFor(() => _messages.contains('early:two:1'));
      _check('channel ready again on the cross-site document',
          _messages.contains('early:two:1'), _messages);

      // ── ISOLATION: a throwing script doesn't stop the next one ─────────
      final c = CefWebController(documentStartScripts: const [
        'throw new Error("boom")',
        'window.__second = 1;',
      ]);
      c.onConsoleMessage = (m) => _console.add(m.message);
      await c.create(
          url: 'about:blank',
          html: _page('three'),
          htmlBaseUrl: 'https://ds-three.invalid/',
          width: 320,
          height: 200);
      await _waitTitle(c, 'three');
      _check('script after a throwing one still ran',
          await _eval(c, 'window.__second') == 1, await _eval(c, 'window.__second'));
      await _waitFor(() => _console.any((m) => m.contains('boom')));
      _check('the throw was reported to the console',
          _console.any((m) =>
              m.contains('document-start script failed') && m.contains('boom')),
          _console);
      await c.dispose();

      // ── HOST GROUP ─────────────────────────────────────────────────────
      final before = await _hosts();
      final g1 = CefWebController(hostGroup: 'probe-group');
      final g2 = CefWebController(hostGroup: 'probe-group');
      await g1.create(
          url: 'about:blank', html: _page('g1'),
          htmlBaseUrl: 'https://ds-g1.invalid/', width: 320, height: 200);
      await g2.create(
          url: 'about:blank', html: _page('g2'),
          htmlBaseUrl: 'https://ds-g2.invalid/', width: 320, height: 200);
      await _waitTitle(g1, 'g1');
      await _waitTitle(g2, 'g2');
      final spawned = (await _hosts()).difference(before);
      _check('two group views share one cef_host', spawned.length == 1,
          'before=$before spawned=$spawned');
      await g1.dispose();
      await Future<void>.delayed(const Duration(seconds: 1));
      _check('the group host outlives one view',
          (await _hosts()).containsAll(spawned), await _hosts());
      await g2.loadHtmlString(_page('g2b'), baseUrl: 'https://ds-g2.invalid/');
      await _waitTitle(g2, 'g2b');
      _check('the remaining group view still works', true);
      await g2.dispose();
      final sw = Stopwatch()..start();
      while ((await _hosts()).intersection(spawned).isNotEmpty &&
          sw.elapsed < const Duration(seconds: 10)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      _check('the group host exits with its last view',
          (await _hosts()).intersection(spawned).isEmpty, await _hosts());

      // ── LARGE authored document at a synthetic origin ──────────────────
      final big = CefWebController();
      const head = '<!doctype html><html><head><title>big</title></head><body>ok<!--';
      const tail = '--></body></html>';
      final html = head + ('x' * (3 * 1024 * 1024)) + tail;
      await big.create(url: 'about:blank', width: 320, height: 200);
      await big.loadHtmlString(html, baseUrl: 'https://ff-editor.invalid/');
      await _waitTitle(big, 'big');
      _check('3 MB authored document loads at a synthetic origin',
          await _eval(big, 'location.href') == 'https://ff-editor.invalid/',
          await _eval(big, 'location.href'));
      await big.dispose();
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
      body: Row(children: [
        SizedBox(
          width: 400,
          height: 300,
          child: CefWebView(
            url: 'about:blank',
            html: _page('one'),
            htmlBaseUrl: 'https://ds-one.invalid/',
            controller: _a,
          ),
        ),
        Expanded(
          child: ListView(
            children: [for (final l in _lines) Text(l, style: const TextStyle(fontSize: 11))],
          ),
        ),
      ]),
    );
  }
}
