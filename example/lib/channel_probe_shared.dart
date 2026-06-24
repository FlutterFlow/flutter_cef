// SHARED-HOST page->host channel probe — the single-controller channel_probe.dart
// PASSES, so the basic channel works. Campus's peer tile differs in that it runs
// on a SHARED cef_host (a named profile → one host for many sessions, per the
// #138 consolidation). This probe mounts TWO controllers on ONE named profile
// (= one shared cef_host), each registering the SAME channel name 'probeHost'
// (exactly like every Campus agent_ui uses 'campusHost'), each page posting a
// DISTINCT tag. It verifies each controller's handler receives ONLY its own tag
// — i.e. OnQuery's slot_->browser_id routing stays correct across sessions.
//
// Run:
//   FLUTTER_CEF_HOST=<.../cef_host.app/Contents/MacOS/cef_host> \
//     flutter run -d macos -t lib/channel_probe_shared.dart
// Result: `CEF_SHARED_PROBE_RESULT …` + /tmp/cef_channel_probe_shared.json.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cef/flutter_cef.dart';

const _profile = 'chprobe';
const _resultPath = '/tmp/cef_channel_probe_shared.json';

String _html(String tag) => '''<!doctype html><meta charset="utf-8">
<body style="font:18px system-ui;margin:20px"><h3>session $tag</h3><div id=log></div>
<script>
  var log = document.getElementById('log');
  function probe() {
    var h = !!(window.probeHost && window.probeHost.postMessage);
    var q = !!window.cefQuery;
    document.title = '$tag host=' + (h?'Y':'N') + ' cq=' + (q?'Y':'N');
    // shim path (under test)
    if (h) { try { window.probeHost.postMessage('$tag-shim'); } catch(e){} }
    // direct cefQuery path (bypasses the shim) — proves transport vs shim.
    if (q) { try { window.cefQuery({request:'ch:probeHost:$tag-direct',persistent:false,onSuccess:function(){},onFailure:function(){}}); } catch(e){} }
  }
  probe();
  var n=0, t=setInterval(function(){ probe(); if(++n>18) clearInterval(t); }, 700);
</script>''';

void main() => runApp(const SharedProbeApp());

class SharedProbeApp extends StatefulWidget {
  const SharedProbeApp({super.key});
  @override
  State<SharedProbeApp> createState() => _SharedProbeAppState();
}

class _SharedProbeAppState extends State<SharedProbeApp> {
  final CefWebController _a = CefWebController(profile: _profile);
  final CefWebController _b = CefWebController(profile: _profile);
  final Set<String> _aRecv = {};
  final Set<String> _bRecv = {};
  bool _aLoaded = false, _bLoaded = false;
  String _status = 'starting…';

  void _wire(CefWebController c, String tag, Set<String> recv,
      bool Function() loaded, void Function() setLoaded) {
    c.addJavaScriptChannel('probeHost', onMessageReceived: (m) {
      recv.add(m);
      // ignore: avoid_print
      print('CEF_SHARED_PROBE $tag-handler received: $m');
    });
    c.title.addListener(() {
      // ignore: avoid_print
      print('CEF_SHARED_PROBE $tag title=${c.title.value}');
    });
    c.onPageStarted = (url) {
      // ignore: avoid_print
      print('CEF_SHARED_PROBE $tag onPageStarted ${url.length > 30 ? url.substring(0, 30) : url}');
      if (!loaded()) {
        setLoaded();
        c.loadHtmlString(_html(tag));
      }
    };
    c.onPageFinished = (url) {
      // ignore: avoid_print
      print('CEF_SHARED_PROBE $tag onPageFinished ${url.length > 30 ? url.substring(0, 30) : url}');
    };
  }

  @override
  void initState() {
    super.initState();
    _wire(_a, 'A', _aRecv, () => _aLoaded, () => _aLoaded = true);
    _wire(_b, 'B', _bRecv, () => _bLoaded, () => _bLoaded = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    setState(() => _status = 'waiting for both sessions…');
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while ((_aRecv.isEmpty || _bRecv.isEmpty) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    // Correct routing = A's handler got ONLY A-tags, B's got ONLY B-tags.
    final aOk = _aRecv.any((m) => m.startsWith('A')) &&
        !_aRecv.any((m) => m.startsWith('B'));
    final bOk = _bRecv.any((m) => m.startsWith('B')) &&
        !_bRecv.any((m) => m.startsWith('A'));
    final out = <String, dynamic>{
      'pass': aOk && bOk,
      'a_handler_received': _aRecv.toList(),
      'b_handler_received': _bRecv.toList(),
      'a_ok': aOk,
      'b_ok': bOk,
    };
    try {
      File(_resultPath).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(out),
      );
    } catch (_) {}
    // ignore: avoid_print
    print('CEF_SHARED_PROBE_RESULT ${jsonEncode(out)}');
    if (mounted) {
      setState(() => _status = (aOk && bOk)
          ? 'PASS — both sessions routed correctly'
          : 'FAIL — A=$_aRecv B=$_bRecv (a_ok=$aOk b_ok=$bOk)');
    }
  }

  @override
  void dispose() {
    _a.dispose();
    _b.dispose();
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
                child: Text('shared-host channel probe — $_status',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: CefWebView(
                          key: const ValueKey('A'),
                          url: 'about:blank',
                          controller: _a,
                          profile: _profile),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: CefWebView(
                          key: const ValueKey('B'),
                          url: 'about:blank',
                          controller: _b,
                          profile: _profile),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
