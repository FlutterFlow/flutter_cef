// Zoom-resize SOAK probe — hammers the device-scale (renderScale) resize path the way a
// user repeatedly zooming the canvas does, to expose the "slowly degrades, freezes at wrong
// size, never recovers" failure. It auto-cycles renderScale across the 1×–3× band every
// 500ms (each step is a dpr resize → new IOSurface + re-raster). The page is a full-bleed
// gradient with a ticking clock + a centered fixed-proportion box: a FROZEN tile stops the
// clock; a WRONG-SCALE tile shows the box too big/small or offset.
//
// Run FLUTTER_CEF_DEBUG=1 and watch the [cefdiag-resize] lines: they print, per present
// while a resize is pending, the actual composited src dims vs the expected new-surface dims
// and whether they match — the oracle for whether the size-gate can ever promote (if src is
// pool-sized, match is never true and the resize STICKS).
//
//   FLUTTER_CEF_HOST=<cef_host> FLUTTER_CEF_ALLOW_INSECURE_PROFILE=1 FLUTTER_CEF_DEBUG=1 \
//     flutter run -d macos -t lib/zoom_soak_probe.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_cef/flutter_cef.dart';

const _html = '''<!doctype html><meta charset="utf-8">
<body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;
  font:600 16px/1.4 -apple-system,system-ui;color:#fff;
  background:linear-gradient(135deg,#2563eb,#7c3aed,#db2777)">
  <!-- A fixed 50%×50% centered box: wrong-scale makes it not-centered / wrong-size. -->
  <div style="width:50%;height:50%;border:3px solid rgba(255,255,255,.9);border-radius:10px;
    display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center">
    <div style="font-size:11px;letter-spacing:2px;opacity:.7">DENSITY SOAK</div>
    <div id="t" style="font-size:26px;font-variant-numeric:tabular-nums">—</div>
    <div style="font-size:10px;opacity:.6">clock = fresh · box = correct scale</div>
  </div>
  <script>function u(){document.getElementById('t').textContent=new Date().toLocaleTimeString()}
  u();setInterval(u,250)</script>
</body>''';

// The renderScale (device-scale) sweep — each value is a dpr resize.
const _scales = [2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 5.0, 4.0, 3.0, 2.5];

void main() => runApp(const SoakApp());

class SoakApp extends StatefulWidget {
  const SoakApp({super.key});
  @override
  State<SoakApp> createState() => _SoakAppState();
}

class _SoakAppState extends State<SoakApp> {
  final _controller = CefWebController();
  int _i = 0;
  int _cycles = 0;
  Timer? _timer;
  bool _running = true;

  @override
  void initState() {
    super.initState();
    _controller.onPageStarted = (_) => _controller.loadHtmlString(_html);
    // Start soaking a few seconds after first paint.
    Future<void>.delayed(const Duration(seconds: 4), _startSoak);
  }

  void _startSoak() {
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted || !_running) return;
      setState(() {
        _i = (_i + 1) % _scales.length;
        if (_i == 0) _cycles++;
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = _scales[_i];
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
                      'SOAK  renderScale=${scale.toStringAsFixed(1)}  '
                      'cycles=$_cycles  step=$_i',
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _running = !_running),
                    child: Text(_running ? 'pause' : 'resume',
                        style: const TextStyle(color: Colors.white)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: Container(
                  color: const Color(0xFF2A3340),
                  padding: const EdgeInsets.all(28),
                  // Fixed LOGICAL size; only renderScale (density) changes — the layout must
                  // stay identical, so any size change in the box is a scale bug.
                  child: SizedBox(
                    width: 400,
                    height: 300,
                    child: CefWebView(
                      url: 'about:blank',
                      controller: _controller,
                      renderScale: scale,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
