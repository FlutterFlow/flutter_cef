// Shared-host loadHtmlString probe — reproduces Campus's agent_ui scenario where, on a fresh
// launch, only ~2 of 6 agent_ui tiles paint and the rest stay BLANK. agent_ui tiles all share
// ONE named-profile cef_host and load their UI via onPageStarted -> loadHtmlString (NOT a URL).
// This mounts 6 such tiles at once (the queued-create burst on the shared host) and labels each
// with its index + a clock, so a blank tile is obvious. Run via `flutter run` so cef_host's
// stdout (FIRSTPAINT / kOpAddChannel / errors) is captured — the data the open-launched Campus
// app hides.
//
//   FLUTTER_CEF_HOST=<cef_host> FLUTTER_CEF_ALLOW_INSECURE_PROFILE=1 FLUTTER_CEF_DEBUG=1 \
//     flutter run -d macos -t lib/sharedhost_html_probe.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_cef/flutter_cef.dart';

// Tile count configurable via PROBE_N (default 6) to bracket the per-host browser limit.
final int _probeN = int.tryParse(Platform.environment['PROBE_N'] ?? '') ?? 6;

String _html(int i) => '''<!doctype html><meta charset="utf-8">
<body style="margin:0;height:100vh;display:flex;flex-direction:column;align-items:center;
  justify-content:center;font:600 16px system-ui;color:#fff;
  background:linear-gradient(135deg,${[
  '#2563eb,#7c3aed', '#db2777,#f59e0b', '#059669,#2563eb',
  '#7c3aed,#db2777', '#0891b2,#4f46e5', '#ca8a04,#dc2626'
][i % 6]})">
  <div style="font-size:13px;letter-spacing:2px;opacity:.8">TILE $i (html)</div>
  <div id="t" style="font-size:24px;font-variant-numeric:tabular-nums">—</div>
  <script>setInterval(()=>document.getElementById('t').textContent=new Date().toLocaleTimeString(),250)</script>
</body>''';

void main() => runApp(const App());

class App extends StatefulWidget {
  const App({super.key});
  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  // 6 controllers, ALL on one shared named profile (like agent_ui's 'agent-ui-cef'), each
  // loading its UI via onPageStarted -> loadHtmlString — the exact agent_ui pattern.
  late final List<CefWebController> _controllers;

  @override
  void initState() {
    super.initState();
    _controllers = List.generate(_probeN, (i) {
      final c = CefWebController(profile: 'agent-ui-test');
      c.onPageStarted = (url) {
        // Only inject on the initial about:blank — loadHtmlString navigates to a data: URL
        // which re-fires onPageStarted, so an unconditional load is an infinite reload loop.
        if (url == 'about:blank') {
          // ignore: avoid_print
          print('PROBE loadHtmlString slot=$i');
          c.loadHtmlString(_html(i));
        }
      };
      return c;
    });
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF111722),
        body: Padding(
          padding: const EdgeInsets.all(12),
          child: GridView.count(
            crossAxisCount: 3,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            children: [
              for (var i = 0; i < _controllers.length; i++)
                Container(
                  color: const Color(0xFF2A3340),
                  // No alignment + tight cell constraints -> the Container fills the cell, the
                  // Stack inherits tight constraints and fills, so Positioned.fill gives the
                  // CefWebView the FULL cell size (the earlier shrink-wrap made it ~50px).
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: CefWebView(
                          url: 'about:blank',
                          controller: _controllers[i],
                          renderScale: 2.0,
                        ),
                      ),
                      Positioned(
                        top: 0,
                        left: 0,
                        child: Container(
                          color: Colors.black54,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          child: Text('slot $i',
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 9)),
                        ),
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
