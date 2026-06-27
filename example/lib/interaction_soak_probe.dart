// Interaction SOAK probe — reproduces Campus's "degrades after interaction" by hitting all
// the things the single-tile zoom soak did NOT: MULTIPLE tiles on the shared host, CULL
// (setVisible false/true) interleaved with renderScale (dpr) changes, and LOGICAL tile
// resizes. The size-gate + cull + multi-tile interaction is the untested seam.
//
// Each of 4 tiles independently, on a rotating schedule, does one of: change renderScale,
// hide, show, change logical size. A tile that wedges shows blank / frozen clock / wrong
// scale and STAYS that way. With FLUTTER_CEF_DEBUG=1 the [cefdiag-resize] lines reveal a
// STUCK resize (repeated match=false for the same pendSid → the size-gate never promotes).
//
//   FLUTTER_CEF_HOST=<cef_host> FLUTTER_CEF_ALLOW_INSECURE_PROFILE=1 FLUTTER_CEF_DEBUG=1 \
//     flutter run -d macos -t lib/interaction_soak_probe.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_cef/flutter_cef.dart';

String _html(int i) => '''<!doctype html><meta charset="utf-8">
<body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;
  font:600 14px/1.4 -apple-system,system-ui;color:#fff;
  background:linear-gradient(135deg,${_bg(i)})">
  <div style="width:55%;height:55%;border:3px solid rgba(255,255,255,.9);border-radius:10px;
    display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center">
    <div style="font-size:11px;letter-spacing:2px;opacity:.7">TILE $i</div>
    <div id="t" style="font-size:22px;font-variant-numeric:tabular-nums">—</div>
  </div>
  <script>function u(){document.getElementById('t').textContent=new Date().toLocaleTimeString()}
  u();setInterval(u,250)</script>
</body>''';
String _bg(int i) => const [
      '#2563eb,#7c3aed', '#db2777,#f59e0b', '#059669,#2563eb', '#7c3aed,#db2777'
    ][i % 4];

const _scales = [2.0, 3.0, 4.0, 5.0, 6.0, 4.0];

void main() => runApp(const App());

class App extends StatefulWidget {
  const App({super.key});
  @override
  State<App> createState() => _AppState();
}

class _Tile {
  final CefWebController controller = CefWebController();
  double scale = 2.0;
  bool visible = true;
  bool big = false;
  int scaleIdx = 0;
}

class _AppState extends State<App> {
  final _tiles = List.generate(4, (_) => _Tile());
  Timer? _timer;
  int _tick = 0;
  bool _running = true;

  @override
  void initState() {
    super.initState();
    for (var i = 0; i < _tiles.length; i++) {
      final t = _tiles[i];
      t.controller.onPageStarted = (_) => t.controller.loadHtmlString(_html(i));
    }
    Future<void>.delayed(const Duration(seconds: 5), () {
      _timer = Timer.periodic(const Duration(milliseconds: 350), (_) => _step());
    });
  }

  // Each tick, drive ONE action on ONE tile — interleaving zoom / cull / resize across the
  // 4 tiles on the shared host, the way real canvas interaction does.
  void _step() {
    if (!mounted || !_running) return;
    final t = _tiles[_tick % _tiles.length];
    final action = (_tick ~/ _tiles.length) % 4;
    setState(() {
      switch (action) {
        case 0: // zoom (renderScale / dpr)
          t.scaleIdx = (t.scaleIdx + 1) % _scales.length;
          t.scale = _scales[t.scaleIdx];
        case 1: // cull off (hide)
          t.visible = false;
          t.controller.setVisible(false);
        case 2: // logical resize WHILE the tile may be hidden
          t.big = !t.big;
        case 3: // un-cull (show) — F-1 must repaint, size-gate must promote
          t.visible = true;
          t.controller.setVisible(true);
      }
      _tick++;
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final t in _tiles) {
      t.controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
              child: Row(children: [
                Expanded(
                  child: Text('INTERACTION SOAK  tick=$_tick',
                      style: const TextStyle(color: Colors.white, fontSize: 13)),
                ),
                TextButton(
                  onPressed: () => setState(() => _running = !_running),
                  child: Text(_running ? 'pause' : 'resume',
                      style: const TextStyle(color: Colors.white)),
                ),
              ]),
            ),
            Expanded(
              child: GridView.count(
                crossAxisCount: 2,
                padding: const EdgeInsets.all(16),
                mainAxisSpacing: 16,
                crossAxisSpacing: 16,
                children: [
                  for (var i = 0; i < _tiles.length; i++) _tileView(i),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tileView(int i) {
    final t = _tiles[i];
    final w = t.big ? 360.0 : 280.0;
    final h = t.big ? 240.0 : 200.0;
    return Container(
      color: const Color(0xFF2A3340),
      alignment: Alignment.center,
      child: Stack(
        alignment: Alignment.topLeft,
        children: [
          SizedBox(
            width: w,
            height: h,
            child: CefWebView(
              url: 'about:blank',
              controller: t.controller,
              renderScale: t.scale,
            ),
          ),
          Container(
            color: Colors.black54,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            child: Text(
              'T$i s=${t.scale.toStringAsFixed(0)} ${t.visible ? "vis" : "HID"} ${w.toInt()}w',
              style: const TextStyle(color: Colors.white, fontSize: 9),
            ),
          ),
        ],
      ),
    );
  }
}
