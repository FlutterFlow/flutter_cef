// Cull/visibility WEDGE probe — verifies the OSR surface REPAINTS after the cull
// transitions that used to wedge it permanently blank (only relaunch recovered):
//   * setVisible(false) → resize while hidden → setVisible(true)
//   * setVisible(false) → setVisible(true) after the off-screen frame is evicted
// The native fix (F-1): DoSetVisible(true) forces a full repaint on the hidden→visible
// edge; (F-2) DoResize defers its paint while hidden; (F-4) the resize watchdog never
// force-promotes a hidden (never-painted) surface. Without these, the page below stays
// BLANK after "Wedge cycle"; with them it reappears (gradient + the ticking clock proves
// the frame is FRESH, not a stale cached one).
//
// Controls: Hide / Show toggle visibility; Resize toggles the logical size; "Wedge cycle"
// runs hide→resize→show automatically. Watch the page: it must come back, filling the
// (possibly new) size, with the clock ticking.
//
// Run (single-view, real cef_host — no Campus):
//   FLUTTER_CEF_HOST=<.../cef_host.app/Contents/MacOS/cef_host> \
//     FLUTTER_CEF_ALLOW_INSECURE_PROFILE=1 \
//     flutter run -d macos -t lib/cull_wedge_probe.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_cef/flutter_cef.dart';

// Full-bleed gradient + a big label + a JS clock. Blank vs painted is unmistakable, and
// the ticking clock distinguishes a FRESH repaint from a frozen/stale frame.
const _html = '''<!doctype html><meta charset="utf-8">
<body style="margin:0;height:100vh;display:flex;flex-direction:column;align-items:center;
  justify-content:center;font:600 22px/1.4 -apple-system,system-ui;color:#fff;
  background:linear-gradient(135deg,#2563eb,#7c3aed,#db2777)">
  <div style="font-size:13px;letter-spacing:3px;opacity:.7">RENDERED</div>
  <div id="t" style="font-size:40px;font-variant-numeric:tabular-nums">—</div>
  <div style="font-size:12px;opacity:.6;margin-top:6px">clock ticking = fresh frame</div>
  <script>function u(){document.getElementById('t').textContent=new Date().toLocaleTimeString()}
  u();setInterval(u,250)</script>
</body>''';

void main() => runApp(const WedgeApp());

class WedgeApp extends StatefulWidget {
  const WedgeApp({super.key});
  @override
  State<WedgeApp> createState() => _WedgeAppState();
}

class _WedgeAppState extends State<WedgeApp> {
  final _controller = CefWebController();
  bool _visible = true;
  bool _big = false;
  String _status = 'ready';

  @override
  void initState() {
    super.initState();
    _controller.onPageStarted = (_) => _controller.loadHtmlString(_html);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _setVisible(bool v) {
    setState(() {
      _visible = v;
      _status = v ? 'shown' : 'HIDDEN';
    });
    _controller.setVisible(v);
  }

  void _toggleSize() => setState(() {
        _big = !_big;
        _status = 'resized to ${_big ? "480×360" : "360×300"}';
      });

  // The exact wedge sequence: hide → resize WHILE HIDDEN → show. The page must come back
  // at the new size with the clock ticking. Pre-fix it stayed permanently blank here.
  Future<void> _wedgeCycle() async {
    setState(() => _status = 'cycle: hiding…');
    _setVisible(false);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    setState(() {
      _big = !_big;
      _status = 'cycle: resized while hidden…';
    });
    await Future<void>.delayed(const Duration(milliseconds: 400));
    setState(() => _status = 'cycle: showing — page MUST repaint');
    _setVisible(true);
  }

  @override
  Widget build(BuildContext context) {
    final w = _big ? 480.0 : 360.0;
    final h = _big ? 360.0 : 300.0;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF111722),
        body: Column(
          children: [
            Container(
              width: double.infinity,
              color: const Color(0xFF0B1220),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'visible=$_visible  size=${w.toInt()}×${h.toInt()}   $_status',
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                  _btn(_visible ? 'Hide' : 'Show',
                      () => _setVisible(!_visible)),
                  const SizedBox(width: 6),
                  _btn('Resize', _toggleSize),
                  const SizedBox(width: 14),
                  _btn('Wedge cycle', _wedgeCycle, wide: true),
                ],
              ),
            ),
            Expanded(
              child: Center(
                // A checkerboard backdrop so a BLANK (wedged) surface reads as obviously
                // empty, not just a same-colored void.
                child: Container(
                  color: const Color(0xFF2A3340),
                  padding: const EdgeInsets.all(24),
                  child: SizedBox(
                    width: w,
                    height: h,
                    child: CefWebView(url: 'about:blank', controller: _controller),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _btn(String label, VoidCallback onTap, {bool wide = false}) => ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          minimumSize: Size(wide ? 110 : 64, 36),
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
        child: Text(label),
      );
}
