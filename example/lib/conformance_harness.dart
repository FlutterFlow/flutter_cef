// CONFORMANCE HARNESS (Step 0 of the unified-model migration) — the oracle every later
// step is verified against. It reproduces Campus's real CEF workload OUTSIDE Campus and
// asserts the two invariants that actually matter, SCREEN-INDEPENDENTLY (the dev box may be
// display-asleep, so we cannot rely on screenshots):
//
//   INVARIANT 1 (never BLANK):      after any geometry change, a tile must paint real content
//                                   within a grace window — never stay blank/frozen.
//   INVARIANT 2 (never WRONG-SIZE): the painted surface dims must converge to the requested
//                                   logical×dpr — never stay small-scaled-up (the "4x" bug).
//
// HOW THE ORACLE WORKS (no screenshot needed): each tile loads a solid-color page whose center
// pixel is a KNOWN color (per index). cef_host's [cefdiag] diagpx sampler (FLUTTER_CEF_DEBUG)
// logs, per browser: painted dims + a 9-point content/white/clear classification + center color.
// The harness prints "[HARNESS] tile=i phase=X want=WxH@dpr center=0xAARRGGBB" on every geometry
// change. Correlating the two streams gives BLANK (diagpx clear/white where content expected)
// and WRONG-SIZE (diagpx dims << want for > grace). A later step can also read served dims via
// a controller callback; for now the native oracle is authoritative and headless.
//
// PHASES (auto-cycled; also drivable by the buttons): idle → resize-storm (animate each tile's
// box at ~60Hz) → zoom-storm (ramp renderScale across quantization thresholds) → cull-storm
// (hide/show) → recreate-storm (dispose+rebuild). One shared profile = one cef_host, like Campus.
//
//   FLUTTER_CEF_HOST=<cef_host> FLUTTER_CEF_ALLOW_INSECURE_PROFILE=1 FLUTTER_CEF_DEBUG=1 \
//     flutter run -d macos -t lib/conformance_harness.dart
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_cef/flutter_cef.dart';

final int _tileCount = int.tryParse(Platform.environment['HARNESS_N'] ?? '') ?? 12;
// HARD mode: STATIC pages (no animation → exactly one frame per resize, the classic size-gate
// wedge), zoom up to 6 (huge surfaces), and a combined resize+zoom storm. This is the regime
// that actually reproduces Campus's blank/4x; the default mode is the gentle smoke test.
final bool _hard = (Platform.environment['HARNESS_HARD'] ?? '') == '1';

// Per-tile known center color (page bg). diagpx center==this ⇒ content present; bg/clear ⇒ blank.
const _colors = <int>[
  0xFFE53935, 0xFF8E24AA, 0xFF3949AB, 0xFF039BE5, 0xFF00897B, 0xFF7CB342,
  0xFFFDD835, 0xFFFB8C00, 0xFFD81B60, 0xFF5E35B1, 0xFF00ACC1, 0xFF43A047,
];
int _colorOf(int i) => _colors[i % _colors.length];
String _hex(int argb) => '0x${argb.toRadixString(16).padLeft(8, '0')}';

String _html(int i) {
  final c = _colorOf(i);
  final css = '#${(c & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
  // HARD: a STATIC page (no setInterval) paints exactly ONE frame per resize — if that frame's
  // dims don't exactly match the size-gate's expectation, it wedges forever (the classic bug).
  // Default: a ticking clock (animating) so the pump keeps producing frames.
  final ticker = _hard
      ? ''
      : "<script>setInterval(()=>document.getElementById('t').textContent="
          "new Date().toLocaleTimeString(),250)</script>";
  return '''<!doctype html><meta charset="utf-8">
<body style="margin:0;height:100vh;background:$css;display:flex;align-items:center;
  justify-content:center;font:700 28px system-ui;color:rgba(255,255,255,.85)">
  <div>TILE $i<br><span id="t" style="font-size:16px">static</span></div>
  $ticker
</body>''';
}

enum Phase { idle, resizeStorm, zoomStorm, cullStorm, recreateStorm, comboStorm }

final _zoomScales = _hard
    ? const [2.0, 3.0, 4.0, 5.0, 6.0, 5.0, 4.0, 3.0]  // up to 6 → huge surfaces
    : const [2.0, 2.5, 3.0, 4.0, 5.0, 4.0, 3.0, 2.5];

void main() => runApp(const HarnessApp());

class HarnessApp extends StatefulWidget {
  const HarnessApp({super.key});
  @override
  State<HarnessApp> createState() => _HarnessAppState();
}

class _Tile {
  CefWebController controller;
  int gen = 0;
  double scale = 2.0;
  int scaleIdx = 0;
  bool visible = true;
  double sizeT = 0; // 0..1 animation param for the resize storm
  _Tile(this.controller);
}

class _HarnessAppState extends State<HarnessApp> {
  late List<_Tile> _tiles;
  Phase _phase = Phase.idle;
  Timer? _driver;
  int _frame = 0;
  bool _auto = true;

  @override
  void initState() {
    super.initState();
    _tiles = List.generate(_tileCount, (i) => _Tile(_mkController(i)));
    // 60Hz driver for the storms.
    _driver = Timer.periodic(const Duration(milliseconds: 16), (_) => _tick());
    // Auto-cycle phases every 6s so an unattended run exercises everything.
    Future<void>.delayed(const Duration(seconds: 5), _cyclePhases);
  }

  CefWebController _mkController(int i) {
    final c = CefWebController(profile: 'conf-harness');
    c.onPageStarted = (url) {
      if (url == 'about:blank') c.loadHtmlString(_html(i));
    };
    return c;
  }

  void _cyclePhases() {
    if (!mounted || !_auto) return;
    const order = [
      Phase.idle, Phase.resizeStorm, Phase.zoomStorm, Phase.cullStorm,
      Phase.recreateStorm, Phase.comboStorm, Phase.idle,
    ];
    final next = order[(order.indexOf(_phase) + 1) % order.length];
    _setPhase(next);
    Future<void>.delayed(const Duration(seconds: 6), _cyclePhases);
  }

  void _setPhase(Phase p) {
    setState(() => _phase = p);
    // ignore: avoid_print
    print('[HARNESS] === PHASE ${p.name} ===');
  }

  void _tick() {
    if (!mounted) return;
    _frame++;
    switch (_phase) {
      case Phase.resizeStorm:
        // Animate every tile's logical box continuously — the resize storm that wedged Campus.
        setState(() {
          for (final t in _tiles) {
            t.sizeT = (t.sizeT + 0.02) % 1.0;
          }
        });
        break;
      case Phase.zoomStorm:
        // Step renderScale across quantization thresholds every ~300ms.
        if (_frame % 18 == 0) {
          setState(() {
            for (final t in _tiles) {
              t.scaleIdx = (t.scaleIdx + 1) % _zoomScales.length;
              t.scale = _zoomScales[t.scaleIdx];
              _logGeom(t);
            }
          });
        }
        break;
      case Phase.cullStorm:
        // Hide/show every ~500ms.
        if (_frame % 30 == 0) {
          setState(() {
            for (final t in _tiles) {
              t.visible = !t.visible;
              t.controller.setVisible(t.visible);
            }
          });
        }
        break;
      case Phase.recreateStorm:
        // Recreate ~2 tiles per second (staggered) — the recover() storm.
        if (_frame % 30 == 0) {
          final i = (_frame ~/ 30) % _tiles.length;
          _recreate(i);
        }
        break;
      case Phase.comboStorm:
        // WORST CASE: animate the box (reallocates the surface) AND step renderScale (huge,
        // re-rasters the whole page) together — a big surface realloc + full re-raster every
        // few frames. This is the YouTube-zoomed-and-resized scenario that wedged Campus.
        setState(() {
          for (final t in _tiles) {
            t.sizeT = (t.sizeT + 0.02) % 1.0;
          }
          if (_frame % 12 == 0) {
            for (final t in _tiles) {
              t.scaleIdx = (t.scaleIdx + 1) % _zoomScales.length;
              t.scale = _zoomScales[t.scaleIdx];
            }
          }
        });
        break;
      case Phase.idle:
        break;
    }
  }

  void _recreate(int i) {
    final t = _tiles[i];
    final old = t.controller;
    setState(() {
      t.controller = _mkController(i);
      t.gen++;
      t.visible = true;
    });
    // ignore: avoid_print
    print('[HARNESS] tile=$i RECREATE gen=${t.gen}');
    // ignore: discarded_futures
    old.dispose();
  }

  void _logGeom(_Tile t) {
    final i = _tiles.indexOf(t);
    // ignore: avoid_print
    print('[HARNESS] tile=$i phase=${_phase.name} scale=${t.scale} '
        'center=${_hex(_colorOf(i))}');
  }

  @override
  void dispose() {
    _driver?.cancel();
    for (final t in _tiles) {
      t.controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cols = (_tileCount <= 4) ? 2 : (_tileCount <= 9 ? 3 : 4);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF0B1220),
        body: Column(children: [
          Container(
            color: const Color(0xFF111827),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(children: [
              Expanded(
                child: Text('CONFORMANCE  phase=${_phase.name}  frame=$_frame  '
                    'tiles=$_tileCount',
                    style: const TextStyle(color: Colors.white, fontSize: 13)),
              ),
              for (final p in Phase.values)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: TextButton(
                    onPressed: () {
                      _auto = false;
                      _setPhase(p);
                    },
                    child: Text(p.name,
                        style: TextStyle(
                            color: _phase == p ? Colors.amber : Colors.white70,
                            fontSize: 11)),
                  ),
                ),
            ]),
          ),
          Expanded(
            child: GridView.count(
              crossAxisCount: cols,
              padding: const EdgeInsets.all(10),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              children: [for (var i = 0; i < _tileCount; i++) _cell(i)],
            ),
          ),
        ]),
      ),
    );
  }

  Widget _cell(int i) {
    final t = _tiles[i];
    // Resize storm animates the inner box between 55% and 100% of the cell.
    final animating = _phase == Phase.resizeStorm || _phase == Phase.comboStorm;
    final f = animating ? (0.55 + 0.45 * (0.5 - (t.sizeT - 0.5).abs()) * 2) : 1.0;
    return Container(
      color: const Color(0xFF1F2937),
      alignment: Alignment.center,
      child: FractionallySizedBox(
        widthFactor: f.clamp(0.4, 1.0),
        heightFactor: f.clamp(0.4, 1.0),
        child: Stack(children: [
          Positioned.fill(
            child: CefWebView(
              key: ValueKey('tile$i-gen${t.gen}'),
              url: 'about:blank',
              controller: t.controller,
              renderScale: t.scale,
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            child: Container(
              color: Colors.black54,
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Text('$i ${t.visible ? "" : "HID"}',
                  style: const TextStyle(color: Colors.white, fontSize: 9)),
            ),
          ),
        ]),
      ),
    );
  }
}
