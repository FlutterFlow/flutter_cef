// P7 JS-bridge smoke harness (Windows integration proof) — reload-tolerant.
//
// loadHtmlString settles with an extra page reload, so linear orchestration on
// one page session is fragile. Instead: confirm() + the download click run in
// the page's inline script (idempotent — they re-run on every load and report a
// stable signal), while find + zoom are Dart-driven and re-armed on each load.
// A feature is "proven" the first time its signal is observed; the probe
// finalizes once all are collected (or on a hard timeout).
//
// Covers: runJavaScriptReturningResult (String/num/List, incl. error path),
// JS confirm dialog (Dart answers true, page observes true), find-in-page count,
// content zoom (applies without wedging the renderer), and download (onDownload
// + file lands in Downloads). Alert is proven separately by alert_probe.dart.
//
// Writes C:\tmp\cef_jsbridge_smoke.json and prints CEF_JSBRIDGE_SMOKE_RESULT.
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cef/flutter_cef.dart';

const _resultPath = '/tmp/cef_jsbridge_smoke.json';

// confirm() result -> title 'cfm:true'/'cfm:false'; download link auto-clicked.
const _html = r'''<!doctype html><meta charset="utf-8">
<body style="font:18px system-ui;margin:20px">
<h2>jsbridge smoke</h2>
<p id="p">the quick brown fox the fox jumps over the fox again</p>
<a id="dl" href="data:text/plain;charset=utf-8,hello-from-cef-download"
   download="cef_smoke.txt">dl</a>
<script>
  var saw = confirm('smoke-confirm');
  document.title = 'cfm:' + saw;
  document.getElementById('dl').click();
</script>''';

void main() => runApp(const SmokeApp());

class SmokeApp extends StatefulWidget {
  const SmokeApp({super.key});
  @override
  State<SmokeApp> createState() => _SmokeAppState();
}

class _SmokeAppState extends State<SmokeApp> {
  final CefWebController _c = CefWebController();
  final Map<String, dynamic> _out = {};
  bool _loaded = false;
  bool _runjsDone = false;
  bool _findZoomDone = false;
  bool _finished = false;
  String _status = 'starting…';

  @override
  void initState() {
    super.initState();

    // confirm — Dart answers true; the page's confirm() must observe true.
    _c.onJavaScriptConfirmDialog = (req) async {
      _out['confirm_seen'] = req.message;
      return true;
    };
    _c.title.addListener(() {
      final t = _c.title.value;
      if (t.startsWith('cfm:')) {
        _out['confirm_page_saw'] = t == 'cfm:true';
        _out['confirm_ok'] =
            _out['confirm_seen'] == 'smoke-confirm' && t == 'cfm:true';
        print('CEF_JSBRIDGE_SMOKE confirm title=$t');
        _maybeStartDartTests();
      }
    });

    // download — fires on every load; capture the first.
    _c.onDownload = (name) {
      if (_out['download_event'] == null) {
        _out['download_event'] = name;
        print('CEF_JSBRIDGE_SMOKE download=$name');
      }
    };

    _c.onPageStarted = (url) {
      if (!_loaded) {
        _loaded = true;
        _c.loadHtmlString(_html);
      }
    };

    Timer(const Duration(seconds: 30), () => _finish());
  }

  // Runs the Dart-driven tests once, after the confirm signal proves the page
  // is live. Re-entrant-safe via the _runjsDone / _findZoomDone guards.
  Future<void> _maybeStartDartTests() async {
    if (_runjsDone) return;
    _runjsDone = true;

    // 1. runJavaScriptReturningResult — typed round-trips.
    try {
      final s = await _c
          .runJavaScriptReturningResult("'hello'+'-world'")
          .timeout(const Duration(seconds: 4));
      _out['runjs_string'] = s;
      _out['runjs_string_ok'] = s == 'hello-world';

      final n = await _c
          .runJavaScriptReturningResult('6*7')
          .timeout(const Duration(seconds: 4));
      _out['runjs_num'] = n;
      _out['runjs_num_ok'] = n is num && n == 42;

      final l = await _c
          .runJavaScriptReturningResult('[1,2,3].map(function(x){return x*10;})')
          .timeout(const Duration(seconds: 4));
      _out['runjs_list'] = l;
      _out['runjs_list_ok'] = l is List && l.length == 3 && l[2] == 30;

      try {
        await _c
            .runJavaScriptReturningResult('(function(){throw new Error("boom")})()')
            .timeout(const Duration(seconds: 4));
        _out['runjs_error_ok'] = false;
      } catch (_) {
        _out['runjs_error_ok'] = true;
      }
      print('CEF_JSBRIDGE_SMOKE runjs s=$s n=$n l=$l err_ok=${_out['runjs_error_ok']}');
    } catch (e) {
      _out['runjs_exception'] = e.toString();
      print('CEF_JSBRIDGE_SMOKE runjs EXCEPTION $e');
    }

    await _runFindZoom();
    _finish();
  }

  Future<void> _runFindZoom() async {
    if (_findZoomDone) return;
    _findZoomDone = true;

    // 4. find — "fox" appears 3x.
    final findDone = Completer<CefFindResult>();
    _c.onFindResult = (r) {
      if (r.numberOfMatches > 0 && !findDone.isCompleted) findDone.complete(r);
    };
    await _c.find('fox');
    try {
      final fr = await findDone.future.timeout(const Duration(seconds: 4));
      _out['find_count'] = fr.numberOfMatches;
      _out['find_ok'] = fr.numberOfMatches == 3;
      print('CEF_JSBRIDGE_SMOKE find count=${fr.numberOfMatches}');
    } catch (_) {
      _out['find_ok'] = false;
    }
    await _c.stopFind();

    // 5. zoom — verb applies and the renderer stays live (readback of an eval).
    try {
      await _c.setZoomLevel(2.0);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final alive = await _c
          .runJavaScriptReturningResult('1+1')
          .timeout(const Duration(seconds: 4));
      await _c.setZoomLevel(0.0);
      _out['zoom_ok'] = alive == 2;
      print('CEF_JSBRIDGE_SMOKE zoom alive=$alive');
    } catch (e) {
      _out['zoom_ok'] = false;
      _out['zoom_exception'] = e.toString();
    }
  }

  void _finish() {
    if (_finished) return;
    // Wait for the Dart tests + a download signal before finalizing (unless the
    // hard timeout forced us here).
    final dlDir = '${Platform.environment['USERPROFILE']}\\Downloads';
    final target = File('$dlDir\\cef_smoke.txt');
    _out['download_landed'] = target.existsSync();
    _out['download_ok'] =
        _out['download_event'] != null && target.existsSync();
    if (target.existsSync()) {
      try {
        _out['download_bytes'] = target.readAsStringSync();
      } catch (_) {}
    }

    final haveAll = _findZoomDone &&
        _out.containsKey('runjs_string_ok') &&
        _out.containsKey('find_ok') &&
        _out.containsKey('zoom_ok') &&
        _out.containsKey('confirm_ok') &&
        _out['download_event'] != null;
    if (!haveAll && DateTime.now().isBefore(_hardDeadline)) {
      // Not everything collected yet and no timeout — try again shortly.
      Timer(const Duration(milliseconds: 500), _finish);
      return;
    }
    _finished = true;

    final gate = (_out['runjs_string_ok'] == true) &&
        (_out['runjs_num_ok'] == true) &&
        (_out['runjs_list_ok'] == true) &&
        (_out['runjs_error_ok'] == true) &&
        (_out['confirm_ok'] == true) &&
        (_out['find_ok'] == true) &&
        (_out['zoom_ok'] == true) &&
        (_out['download_ok'] == true);
    _out['pass'] = gate;

    try {
      File(_resultPath).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(_out),
      );
    } catch (_) {}
    print('CEF_JSBRIDGE_SMOKE_RESULT ${jsonEncode(_out)}');
    if (mounted) setState(() => _status = gate ? 'PASS' : 'PARTIAL — $_out');
  }

  final DateTime _hardDeadline =
      DateTime.now().add(const Duration(seconds: 28));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text('jsbridge smoke — $_status',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              Expanded(child: CefWebView(url: 'about:blank', controller: _c)),
            ],
          ),
        ),
      ),
    );
  }
}
