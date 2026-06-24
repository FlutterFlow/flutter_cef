// page->host JS-channel probe — reproduces the Campus "peer edit never reaches
// the host" symptom in isolation (no Campus, no multiplayer).
//
// A Campus PEER mounts a FRESH CefWebController, registers a JS channel
// (addJavaScriptChannel), loads an HTML doc ON the first onPageStarted (session
// ready), and the page calls window.<channel>.postMessage(...). Live, that never
// invokes the Dart onMessageReceived (host->page works; page->host is dead).
// This probe exercises exactly that path and reports — via document.title (an
// INDEPENDENT page->host signal, OnTitleChange, NOT the cefQuery channel under
// test) — whether window.probeHost / window.cefQuery exist and whether a direct
// cefQuery succeeds or fails.
//
// Run (cef_host must be built; CEF cached):
//   FLUTTER_CEF_HOST=<.../cef_host.app/Contents/MacOS/cef_host> \
//     flutter run -d macos -t lib/channel_probe.dart
// Result: `CEF_CHANNEL_PROBE_RESULT …` stdout + /tmp/cef_channel_probe.json.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cef/flutter_cef.dart';

const _resultPath = '/tmp/cef_channel_probe.json';

const _probeHtml = r'''<!doctype html><meta charset="utf-8">
<body style="font:20px system-ui;margin:24px;color:#111;background:#fff">
<h2>page&rarr;host channel probe</h2>
<button id="b" style="font:18px system-ui;padding:10px 18px">postMessage to host</button>
<div id="log" style="margin-top:16px;color:#555"></div>
<script>
  var log = document.getElementById('log');
  function rep(s) { document.title = s; if (log) log.textContent = s; }
  function probe(tag) {
    var hasHost = !!(window.probeHost && window.probeHost.postMessage);
    var hasCq = !!window.cefQuery;
    if (hasHost) { try { window.probeHost.postMessage('shim:' + tag); } catch (e) {} }
    if (hasCq) {
      try {
        window.cefQuery({
          request: 'ch:probeHost:direct:' + tag,
          persistent: false,
          onSuccess: function (r) { rep('host=' + (hasHost?'Y':'N') + ' cq=Y SUCCESS @' + tag); },
          onFailure: function (c, m) { rep('host=' + (hasHost?'Y':'N') + ' cq=Y FAIL ' + c + ' ' + m); }
        });
      } catch (e) { rep('host=' + (hasHost?'Y':'N') + ' cq=Y THREW ' + e); }
    } else {
      rep('host=' + (hasHost?'Y':'N') + ' cq=N @' + tag);
    }
  }
  document.getElementById('b').onclick = function () { probe('click'); };
  probe('load');
  var n = 0;
  var t = setInterval(function () { probe('auto' + n); if (++n > 18) clearInterval(t); }, 700);
</script>''';

void main() => runApp(const ProbeApp());

class ProbeApp extends StatefulWidget {
  const ProbeApp({super.key});
  @override
  State<ProbeApp> createState() => _ProbeAppState();
}

class _ProbeAppState extends State<ProbeApp> {
  // Fresh, ephemeral controller — exactly like a Campus peer mirror.
  final CefWebController _c = CefWebController();
  final List<String> _received = [];
  bool _hostGot = false;
  bool _loaded = false;
  String _status = 'starting…';

  @override
  void initState() {
    super.initState();
    _c.addJavaScriptChannel('probeHost', onMessageReceived: (m) {
      _received.add(m);
      _hostGot = true;
      // ignore: avoid_print
      print('CEF_CHANNEL_PROBE host received: $m');
    });
    _c.title.addListener(() {
      // ignore: avoid_print
      print('CEF_CHANNEL_PROBE title=${_c.title.value}');
    });
    // Mirror _CefSurfaceView on a peer: load the doc on the first onPageStarted
    // (the initial about:blank — session is up by then), NOT before it exists.
    _c.onPageStarted = (url) {
      // ignore: avoid_print
      print('CEF_CHANNEL_PROBE onPageStarted url=$url');
      if (!_loaded) {
        _loaded = true;
        _c.loadHtmlString(_probeHtml);
      }
    };
    _c.onPageFinished = (url) {
      // ignore: avoid_print
      print('CEF_CHANNEL_PROBE onPageFinished url=$url');
    };
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    setState(() => _status = 'waiting for page + channel…');
    final deadline = DateTime.now().add(const Duration(seconds: 18));
    while (!_hostGot && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    final out = <String, dynamic>{
      'pass': _hostGot,
      'received_count': _received.length,
      'received': _received.take(5).toList(),
    };
    try {
      File(_resultPath).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(out),
      );
    } catch (_) {}
    // ignore: avoid_print
    print('CEF_CHANNEL_PROBE_RESULT ${jsonEncode(out)}');
    if (mounted) {
      setState(() => _status = _hostGot
          ? 'PASS — host received ${_received.length} message(s)'
          : 'FAIL — host received NOTHING (page->host channel dead)');
    }
  }

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
                child: Text('channel probe — $_status',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              Expanded(
                child: CefWebView(url: 'about:blank', controller: _c),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
