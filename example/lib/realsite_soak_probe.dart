// Real-website SOAK probe — the missing variable: trivial HTML re-rasters in ~1 frame, so
// the size-gate's "wait for a correct-scale frame" always resolves instantly. A REAL site
// (heavy layout, async content, continuous paint) re-rasters SLOWLY, so RAPID renderScale
// (zoom) changes can outrun the re-raster — the renderer never produces a frame at the
// LATEST size, the size-gate never promotes, resizeInFlight sticks → freeze at wrong/old
// scale, "never recovers". This mixes a trivial page with heavy real sites and hammers
// renderScale fast, exactly that scenario.
//
//   FLUTTER_CEF_HOST=<cef_host> FLUTTER_CEF_ALLOW_INSECURE_PROFILE=1 FLUTTER_CEF_DEBUG=1 \
//     flutter run -d macos -t lib/realsite_soak_probe.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_cef/flutter_cef.dart';

const _trivial = '''<!doctype html><meta charset="utf-8">
<body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;
  font:600 22px system-ui;color:#fff;background:linear-gradient(135deg,#2563eb,#db2777)">
  <div id="t">trivial —</div>
  <script>setInterval(()=>document.getElementById('t').textContent='trivial '+new Date().toLocaleTimeString(),250)</script>
</body>''';

// Tile 0 = trivial HTML; tiles 1-3 = heavy real sites (loaded via the URL prop, like a
// cefWebview tile — NOT loadHtmlString).
const _urls = [null, 'https://en.wikipedia.org/wiki/Web_browser',
  'https://flutter.dev', 'https://news.ycombinator.com'];

const _scales = [2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 5.0, 4.0, 3.0, 2.5];

void main() => runApp(const App());

class App extends StatefulWidget {
  const App({super.key});
  @override
  State<App> createState() => _AppState();
}

class _Tile {
  // SHARED named profile → all tiles route to ONE cef_host (like Campus's 'campus-web'),
  // serialized by the create-pacer — NOT a host-per-controller. This is the regime Campus
  // actually runs and the probes had been missing.
  final CefWebController controller = CefWebController(profile: 'soak-shared');
  double scale = 2.0;
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
    // Tile 0 loads trivial HTML; the rest navigate to their real URL on first establishment.
    _tiles[0].controller.onPageStarted = (_) => _tiles[0].controller.loadHtmlString(_trivial);
    // Hammer renderScale FAST (200ms) across all tiles — faster than a heavy page re-rasters.
    Future<void>.delayed(const Duration(seconds: 6), () {
      _timer = Timer.periodic(const Duration(milliseconds: 200), (_) => _step());
    });
  }

  void _step() {
    if (!mounted || !_running) return;
    final t = _tiles[_tick % _tiles.length];
    setState(() {
      t.scaleIdx = (t.scaleIdx + 1) % _scales.length;
      t.scale = _scales[t.scaleIdx];
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
        body: Column(children: [
          Container(
            width: double.infinity,
            color: const Color(0xFF0B1220),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(children: [
              Expanded(
                child: Text('REAL-SITE SOAK (rapid zoom on heavy pages)  tick=$_tick',
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
              padding: const EdgeInsets.all(12),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              children: [for (var i = 0; i < _tiles.length; i++) _tileView(i)],
            ),
          ),
        ]),
      ),
    );
  }

  Widget _tileView(int i) {
    final t = _tiles[i];
    return Container(
      color: const Color(0xFF2A3340),
      alignment: Alignment.center,
      child: Stack(alignment: Alignment.topLeft, children: [
        SizedBox(
          width: 320,
          height: 220,
          child: CefWebView(
            url: _urls[i] ?? 'about:blank',
            controller: t.controller,
            renderScale: t.scale,
          ),
        ),
        Container(
          color: Colors.black54,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          child: Text('T$i ${_urls[i] == null ? "trivial" : Uri.parse(_urls[i]!).host} s=${t.scale.toStringAsFixed(0)}',
              style: const TextStyle(color: Colors.white, fontSize: 9)),
        ),
      ]),
    );
  }
}
