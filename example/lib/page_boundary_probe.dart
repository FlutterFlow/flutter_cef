// What a page can reach beyond its own tile — END-TO-END probe (macOS).
//
// Auto-running, no-interaction regression test for three host-side boundaries.
// All tiles share one cef_host (a host group) with the scheme allowlist
// {https}.
//   * JS channels are per tile: a channel tile A registered is not injected into
//     tile B's page, and B calling window.cefQuery with A's channel name directly
//     is refused. A's and B's own channels still work, including B's
//     create-time channel after a reload.
//   * Sized popups (window.open with a size) need a user gesture, a URL the tile
//     may load, and fewer than 4 already open.
//   * A navigate sent before its tile's create frame reached the host is held to
//     the allowlist like any other navigate.
//
// A `CEF_PROBE_RESULT PASS|FAIL` line is printed to stdout at the end.
//
// Run:  FLUTTER_CEF_HOST=<.../cef_host.app/Contents/MacOS/cef_host> \
//         flutter run -d macos -t lib/page_boundary_probe.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cef/flutter_cef.dart';

const _group = 'page_boundary';
const _schemes = {'https'};

// window.tryChannel posts straight through window.cefQuery, as a page could
// without any shim, and records the answer in window.answers.
const _channelPage = '''<!doctype html><body><h1>channels</h1><script>
window.answers = [];
window.tryChannel = function (name, msg) {
  window.cefQuery({request: 'ch:' + name + ':' + msg, persistent: false,
    onSuccess: function () { window.answers.push('ok'); },
    onFailure: function (code) { window.answers.push('refused ' + code); }});
  return 1;
};
</script>''';

// The whole page is one button: a click opens a sized popup to window.target.
const _popupPage = '''<!doctype html><body style="margin:0">
<button id=b style="width:100vw;height:100vh">open</button><script>
window.opened = [];
window.target = 'https://example.com/';
document.getElementById('b').onclick = function () {
  window.opened.push(window.open(window.target, '_blank', 'width=300,height=200'));
};
window.noGesture = window.open('https://example.com/', '_blank', 'width=300,height=200');
</script>''';

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

  Future<void> _painted(CefWebController c) async {
    final sw = Stopwatch()..start();
    while (((await c.sessionStats())?.presentCount ?? 0) <= 0 &&
        sw.elapsed.inSeconds < 15) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<CefWebController> _open(String html) async {
    final c = CefWebController(hostGroup: _group);
    await c.create(
      url: 'about:blank',
      html: html,
      width: 400,
      height: 300,
      allowedSchemes: _schemes,
    );
    await _painted(c);
    return c;
  }

  /// Waits for [cond] to hold, for up to [seconds].
  Future<bool> _eventually(bool Function() cond, {int seconds = 5}) async {
    final sw = Stopwatch()..start();
    while (!cond() && sw.elapsed.inSeconds < seconds) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return cond();
  }

  Future<void> _channels() async {
    final gotA = <String>[], gotBOwn = <String>[];
    final a = await _open(_channelPage);
    await a.addJavaScriptChannel('probeHost', onMessageReceived: gotA.add);
    final b = CefWebController(hostGroup: _group);
    await b.addJavaScriptChannel('ownHost', onMessageReceived: gotBOwn.add);
    await b.create(
      url: 'about:blank',
      html: _channelPage,
      width: 400,
      height: 300,
      allowedSchemes: _schemes,
    );
    await _painted(b);

    _check(
      "A's page has the channel A registered",
      await a.runJavaScriptReturningResult('typeof window.probeHost') ==
          'object',
    );
    _check(
      "B's page doesn't have A's channel",
      await b.runJavaScriptReturningResult('typeof window.probeHost') ==
          'undefined',
    );
    await b.runJavaScriptReturningResult(
      'window.tryChannel("probeHost", "from-B")',
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final direct = await b.runJavaScriptReturningResult('window.answers[0]');
    _check(
      "B's direct cefQuery on A's channel is refused",
      '$direct'.startsWith('refused'),
      direct,
    );
    await a.runJavaScriptReturningResult(
      'window.tryChannel("probeHost", "from-A")',
    );
    _check(
      "A's own channel delivers",
      await _eventually(() => gotA.contains('from-A')),
      gotA,
    );
    _check("nothing from B reached A", !gotA.contains('from-B'), gotA);

    await b.reload();
    await Future<void>.delayed(const Duration(seconds: 2));
    await b.runJavaScriptReturningResult(
      'window.ownHost.postMessage("after-reload"), 1',
    );
    _check(
      "B's create-time channel works after a reload",
      await _eventually(() => gotBOwn.contains('after-reload')),
      gotBOwn,
    );
    _check(
      "B's page still doesn't have A's channel after a reload",
      await b.runJavaScriptReturningResult('typeof window.probeHost') ==
          'undefined',
    );
    await a.dispose();
    await b.dispose();
  }

  // A real click: sendPointer is internal API, used here to make a user gesture.
  // ignore_for_file: invalid_use_of_internal_member
  Future<void> _click(CefWebController c) async {
    c.sendPointer(type: 0, x: 200, y: 150);
    c.sendPointer(type: 1, x: 200, y: 150);
    c.sendPointer(type: 2, x: 200, y: 150);
    await Future<void>.delayed(const Duration(milliseconds: 700));
  }

  Future<void> _popups() async {
    final c = await _open(_popupPage);
    _check(
      'a sized popup without a user gesture is blocked',
      await c.runJavaScriptReturningResult('window.noGesture === null') == true,
    );
    await c.runJavaScriptReturningResult('window.target = "file:///tmp/", 1');
    await _click(c);
    _check(
      'a sized popup to a scheme outside the allowlist is blocked',
      await c.runJavaScriptReturningResult('window.opened[0] === null') == true,
      await c.runJavaScriptReturningResult('window.opened.length'),
    );
    await c.runJavaScriptReturningResult(
      'window.target = "https://example.com/", 1',
    );
    for (var i = 0; i < 5; i++) {
      await _click(c);
    }
    final opened = await c.runJavaScriptReturningResult(
      'window.opened.slice(1).map(function (w) { return w !== null; })',
    );
    _check(
      'clicks open sized popups, at most 4 at once',
      '$opened' == '[true, true, true, true, false]',
      opened,
    );
    await c.runJavaScriptReturningResult(
      'window.opened.forEach(function (w) { if (w) w.close(); }), 1',
    );
    await c.dispose();
  }

  Future<void> _earlyNavigate() async {
    // A holds the host's create pacer until it paints, so B's create frame is
    // still queued plugin-side when its navigate goes out.
    final a = CefWebController(hostGroup: _group);
    final b = CefWebController(hostGroup: _group);
    final started = <String>[];
    b.onPageStarted = started.add;
    final createA = a.create(
      url: 'https://example.com/',
      width: 400,
      height: 300,
      allowedSchemes: _schemes,
    );
    await b.create(
      url: 'https://example.com/',
      width: 400,
      height: 300,
      allowedSchemes: _schemes,
    );
    await b.navigate('data:text/html,<title>early</title>');
    await createA;
    await _painted(b);
    await Future<void>.delayed(const Duration(seconds: 2));
    _check(
      'a navigate that beat its create is held to the allowlist',
      !started.any((u) => u.startsWith('data:')),
      started,
    );
    await a.dispose();
    await b.dispose();
  }

  Future<void> _run() async {
    try {
      await _channels();
      await _popups();
      await _earlyNavigate();
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
