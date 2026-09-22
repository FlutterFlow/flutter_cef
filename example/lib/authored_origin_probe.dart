// Authored-document-at-a-real-origin + create-race END-TO-END probe (macOS).
//
// Auto-running, no-interaction self-test for two host behaviours the FlutterFlow
// desktop code editor depends on:
//
//   EARLY VERBS — cookie verbs issued the instant create() returns. The host
//                 registers the browser slot on a later UI task (and paces the
//                 create frame itself), so these used to be DROPPED: setCookie
//                 lost, getCookies never answered. Now: answered first try.
//   ORIGIN      — html + htmlBaseUrl / loadHtmlString(baseUrl:) serve the
//                 document AT that URL, so location.origin is the real origin
//                 (a data: URL's is "null"), relative URLs resolve against it,
//                 and origin-keyed storage works. The hosts used here do not
//                 resolve, which proves the bytes came from us, not the network.
//                 Holds across reload(); navigate() ends it.
//
// A `CEF_PROBE_RESULT PASS|FAIL` line is printed to stdout at the end.
//
// Run:  flutter run -d macos -t lib/authored_origin_probe.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cef/flutter_cef.dart';

const _createBase = 'https://authored.evi.example/app/';
const _loadBase = 'https://second.evi.example'; // bare authority on purpose

String _doc(String title) => '<!doctype html><html><head><title>$title</title>'
    '</head><body><h1>$title</h1><script>'
    'try{localStorage.setItem("k","$title");}catch(e){}'
    '</script></body></html>';

void main() => runApp(const ProbeApp());

class ProbeApp extends StatefulWidget {
  const ProbeApp({super.key});
  @override
  State<ProbeApp> createState() => _ProbeAppState();
}

class _ProbeAppState extends State<ProbeApp> {
  final List<String> _lines = [];
  final CefWebController _page = CefWebController();
  final StreamController<String> _finished = StreamController.broadcast();
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
    _page.onPageFinished = _finished.add;
    _page.onLoadError = (e) => _log('loadError: $e');
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<Object?> _eval(String js) => _page
      .runJavaScriptReturningResult(js)
      .timeout(const Duration(seconds: 5));

  /// Wait until the page reports [title] (pageFinished for it may already have
  /// fired before we started listening).
  Future<void> _untilTitle(String title) async {
    final sw = Stopwatch()..start();
    while (sw.elapsed < const Duration(seconds: 20)) {
      try {
        if (await _eval('document.title') == title) return;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    throw StateError('page never showed title "$title"');
  }

  Future<void> _earlyVerbs() async {
    final c = CefWebController();
    try {
      await c
          .create(url: 'about:blank', width: 320, height: 200, dpr: 1.0)
          .timeout(const Duration(seconds: 20));
      // NO wait, NO retry: straight into the create race.
      const url = 'https://early.evi.example/';
      await c.setCookie(url: url, name: 'early', value: '1', secure: true);
      List<CefCookie>? jar;
      try {
        jar = await c.getCookies(url: url).timeout(const Duration(seconds: 3));
      } on TimeoutException {
        jar = null;
      }
      _check('early getCookies answered (first try)', jar != null);
      // The jar commit is async; the WRITE must not have been dropped.
      for (var i = 0; i < 30 && !(jar ?? const []).any((k) => k.name == 'early'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        jar = await c.getCookies(url: url).timeout(const Duration(seconds: 3));
      }
      _check('early setCookie landed', (jar ?? const []).any((k) => k.name == 'early'), jar);
    } finally {
      c.dispose();
    }
  }

  Future<void> _run() async {
    try {
      await _earlyVerbs();

      // --- create ON an authored document ---
      await _untilTitle('created');
      _check('create: origin', await _eval('location.origin') == 'https://authored.evi.example',
          await _eval('location.origin'));
      _check('create: href', await _eval('location.href') == _createBase, await _eval('location.href'));
      _check('create: relative URL resolves against it',
          await _eval('new URL("x.js", document.baseURI).href') == '${_createBase}x.js');
      _check('create: origin-keyed storage works', await _eval('localStorage.getItem("k")') == 'created');

      // --- reload keeps serving it ---
      await _eval('document.title = "stale"');
      await _page.reload();
      await _untilTitle('created');
      _check('reload: still the authored document', true);

      // --- loadHtmlString(baseUrl:) on a bare authority ---
      await _page.loadHtmlString(_doc('loaded'), baseUrl: _loadBase);
      await _untilTitle('loaded');
      _check('load: origin', await _eval('location.origin') == _loadBase, await _eval('location.origin'));
      _check('load: storage is per-origin', await _eval('localStorage.getItem("k")') == 'loaded');

      // --- no baseUrl: unchanged data: behaviour ---
      await _page.loadHtmlString(_doc('plain'));
      await _untilTitle('plain');
      _check('plain: opaque origin', await _eval('location.origin') == 'null', await _eval('location.origin'));

      // --- navigate() ends it: the authored host goes back to the network ---
      final failed = Completer<void>();
      _page.onLoadError = (e) {
        if (!failed.isCompleted) failed.complete();
      };
      await _page.loadHtmlString(_doc('again'), baseUrl: _loadBase);
      await _untilTitle('again');
      await _page.navigate(_loadBase);
      var networkTried = true;
      await failed.future.timeout(const Duration(seconds: 15), onTimeout: () => networkTried = false);
      _check('navigate: authored document no longer served', networkTried);
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
          SizedBox(
            width: 420,
            child: CefWebView(
              url: 'about:blank',
              html: _doc('created'),
              htmlBaseUrl: _createBase,
              controller: _page,
            ),
          ),
          Expanded(
            child: ListView(children: [for (final l in _lines) Text(l)]),
          ),
        ]),
      ),
    );
  }
}
