// Recreate SOAK probe — mimics Campus's CefSessionController.recover() (the one pattern
// the other probes never exercised): on a paint-stall / F-6 stall Campus DISPOSES the
// controller, builds a FRESH one, and REMOUNTS the CefWebView against it (a generation
// ValueKey bump). This probe drives that recreate cycle interleaved with zoom (renderScale)
// and cull (setVisible) — the suspected source of "looks fine, then after interaction
// degrades to blank/freeze/wrong-size, never recovers".
//
// Each tile, on a schedule: change renderScale, hide, show, or RECREATE (dispose+new+remount).
// A tile that wedges after a recreate shows blank / frozen clock / wrong scale and stays.
// FLUTTER_CEF_DEBUG=1 → [cefdiag-resize] shows whether the recreated controller's first
// correct-scale frame ever promotes.
//
//   FLUTTER_CEF_HOST=<cef_host> FLUTTER_CEF_ALLOW_INSECURE_PROFILE=1 FLUTTER_CEF_DEBUG=1 \
//     flutter run -d macos -t lib/recreate_soak_probe.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_cef/flutter_cef.dart';

String _html(int i, int gen) => '''<!doctype html><meta charset="utf-8">
<body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;
  font:600 14px/1.4 -apple-system,system-ui;color:#fff;
  background:linear-gradient(135deg,${['#2563eb,#7c3aed','#db2777,#f59e0b'][i % 2]})">
  <div style="width:55%;height:55%;border:3px solid rgba(255,255,255,.9);border-radius:10px;
    display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center">
    <div style="font-size:11px;letter-spacing:2px;opacity:.7">TILE $i · gen $gen</div>
    <div id="t" style="font-size:22px;font-variant-numeric:tabular-nums">—</div>
  </div>
  <script>function u(){document.getElementById('t').textContent=new Date().toLocaleTimeString()}
  u();setInterval(u,250)</script>
</body>''';

const _scales = [2.0, 3.0, 4.0, 5.0, 6.0, 4.0];

void main() => runApp(const App());

class App extends StatefulWidget {
  const App({super.key});
  @override
  State<App> createState() => _AppState();
}

class _Tile {
  CefWebController controller = CefWebController();
  int gen = 0;
  double scale = 2.0;
  int scaleIdx = 0;
  bool visible = true;
  int recreates = 0;
}

class _AppState extends State<App> {
  final _tiles = List.generate(2, (_) => _Tile());
  Timer? _timer;
  int _tick = 0;
  bool _running = true;

  @override
  void initState() {
    super.initState();
    for (var i = 0; i < _tiles.length; i++) {
      _wire(i);
    }
    Future<void>.delayed(const Duration(seconds: 5), () {
      _timer = Timer.periodic(const Duration(milliseconds: 400), (_) => _step());
    });
  }

  void _wire(int i) {
    final t = _tiles[i];
    t.controller.onPageStarted = (_) => t.controller.loadHtmlString(_html(i, t.gen));
  }

  // Mimic CefSessionController.recover(): build a fresh controller, bump the generation
  // (remount key), dispose the old. The CefWebView below is keyed on gen, so it remounts
  // and re-create()s against the new controller — exactly Campus's recover path.
  void _recreate(int i) {
    final t = _tiles[i];
    final old = t.controller;
    t.controller = CefWebController();
    t.gen++;
    t.recreates++;
    _wire(i);
    // ignore: discarded_futures
    old.dispose();
    // Emit a running total so the leak-soak gate can confirm the dispose+create churn actually
    // happened (the lifetime stress that producer-allocates mint/release must survive bounded).
    final total = _tiles.fold<int>(0, (s, x) => s + x.recreates);
    // ignore: avoid_print
    print('PROBE recreates_total=$total');
  }

  void _step() {
    if (!mounted || !_running) return;
    final t = _tiles[_tick % _tiles.length];
    final action = (_tick ~/ _tiles.length) % 5;
    setState(() {
      switch (action) {
        case 0:
          t.scaleIdx = (t.scaleIdx + 1) % _scales.length;
          t.scale = _scales[t.scaleIdx];
        case 1:
          t.visible = false;
          t.controller.setVisible(false);
        case 2:
          t.visible = true;
          t.controller.setVisible(true);
        case 3:
          _recreate(t == _tiles[0] ? 0 : 1); // RECREATE — the suspect path
        case 4:
          // recreate WHILE at a non-default scale (the recreate-during-zoom interaction)
          t.scaleIdx = (t.scaleIdx + 2) % _scales.length;
          t.scale = _scales[t.scaleIdx];
          _recreate(t == _tiles[0] ? 0 : 1);
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
                  child: Text(
                    'RECREATE SOAK  tick=$_tick  '
                    'recreates=${_tiles.map((t) => t.recreates).join(",")}',
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() => _running = !_running),
                  child: Text(_running ? 'pause' : 'resume',
                      style: const TextStyle(color: Colors.white)),
                ),
              ]),
            ),
            Expanded(
              child: Row(
                children: [
                  for (var i = 0; i < _tiles.length; i++) Expanded(child: _tileView(i)),
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
    return Container(
      color: const Color(0xFF2A3340),
      alignment: Alignment.center,
      child: Stack(
        alignment: Alignment.topLeft,
        children: [
          SizedBox(
            width: 320,
            height: 240,
            // Keyed on gen → remounts against the fresh controller on recreate (Campus's
            // generation-keyed body).
            child: CefWebView(
              key: ValueKey('tile$i-gen${t.gen}'),
              url: 'about:blank',
              controller: t.controller,
              renderScale: t.scale,
            ),
          ),
          Container(
            color: Colors.black54,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            child: Text(
              'T$i gen${t.gen} s=${t.scale.toStringAsFixed(0)} ${t.visible ? "vis" : "HID"}',
              style: const TextStyle(color: Colors.white, fontSize: 9),
            ),
          ),
        ],
      ),
    );
  }
}
