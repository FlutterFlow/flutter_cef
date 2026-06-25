// Performance stress probe — many concurrent CefWebViews, for measuring render
// smoothness, memory, process count, and fd footprint at scale.
//
// Mounts a grid of N CefWebViews each loading a continuously-animating page
// (CSS animation + rAF counter -> continuous OnAcceleratedPaint), reports Flutter
// frame timing (avg / p90 / jank%) every 2s to stdout + /tmp/cef_stress.jsonl,
// and offers +/- view and churn (create+dispose loop) controls. Pair with
// test/perf_sample.sh to sample `pgrep cef_host` / RSS / fd over the run.
//
// Profile knob: kProfile='stress' (shared host — the engine multi-view path) vs
// null (ephemeral — one cef_host per view, the process-blowup baseline).
//
// Run:
//   FLUTTER_CEF_HOST=<.../cef_host> FLUTTER_CEF_ALLOW_INSECURE_PROFILE=1 \
//     flutter run -d macos -t lib/stress_probe.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_cef/flutter_cef.dart';

// ── knobs ──────────────────────────────────────────────────────────────────
// --dart-define=CEF_EPHEMERAL=true => null profile (one cef_host per view, the
// process-blowup baseline); default => shared host (the engine multi-view path).
const String? kProfile =
    bool.fromEnvironment('CEF_EPHEMERAL') ? null : 'stress';
// Bounded host pool: bucket views across kPoolSize profiles (~kInitialViews/kPoolSize
// browsers per shared cef_host / GPU process) so no single GPU/Viz process is asked
// to drive too many accelerated OSR browsers at once (which leaves some never
// painting). kPoolSize=1 reproduces the single-host blank-tile bug.
const int kPoolSize = int.fromEnvironment('CEF_POOL', defaultValue: 4);
const int kInitialViews = int.fromEnvironment('CEF_INITIAL', defaultValue: 12);
// --dart-define=CEF_STATIC=true => load a STATIC page (paints once, no rAF/CSS
// animation) instead of the 60fps gradient — models real (mostly static) agent_ui
// content vs the continuous-animation worst case, to isolate sustained-compositing
// load from the create-time first-frame race.
const bool kStatic = bool.fromEnvironment('CEF_STATIC');
// --dart-define=CEF_CREATE_DELAY_MS=1500 => bring the initial views up GRADUALLY
// (one every N ms, like opening browser windows by hand) instead of all-at-once.
// Tests whether the never-paint stall is a create-burst surface-handshake race.
const int kCreateDelayMs =
    int.fromEnvironment('CEF_CREATE_DELAY_MS', defaultValue: 0);
// --dart-define=CEF_TILE_PX=140 => render each view at a FIXED small size (in a
// wrap) instead of the full-window grid. Separates a fill-rate / GPU-bandwidth
// limit (small tiles => more fit) from a per-browser sink-COUNT cap (fixed ~8
// regardless of size).
const int kTilePx = int.fromEnvironment('CEF_TILE_PX', defaultValue: 0);
// --dart-define=CEF_FORCE_REPAINT=true => drive a 60fps Flutter repaint (setState)
// so the Texture widgets are pulled every frame. Tests whether the "static" display
// is just idle Flutter not pulling produced frames (textureFrameAvailable not
// scheduling a frame), independent of GPU production.
const bool kForceRepaint = bool.fromEnvironment('CEF_FORCE_REPAINT');
// --dart-define=CEF_RECREATE_ON_STALL=true => when a tile's watchdog reports it never
// produced a first frame (onPaintStalled), dispose + recreate it (a fresh browser +
// capturer). Self-heals the intermittent OSR capturer-establishment failure.
const bool kRecreateOnStall = bool.fromEnvironment('CEF_RECREATE_ON_STALL');
// Max destructive recreates per tile before falling back to pump-patience (never churn).
const int kMaxRecreates = int.fromEnvironment('CEF_MAX_RECREATES', defaultValue: 2);
// --dart-define=CEF_LIVE_CAP=6 => MASKING approach: keep only N tiles CEF-visible
// (setVisible(true)) at a time; the rest are setVisible(false) (WasHidden → capturer
// idle, frozen on last frame), rotating so every tile gets a live turn to establish.
// Models the Campus "only live-render the most-relevant ~6 webviews" policy.
const int kLiveCap = int.fromEnvironment('CEF_LIVE_CAP', defaultValue: 0);
// --dart-define=CEF_ANIM_DELAY_MS=1000 => animated content that stays STATIC for the
// first N ms after load, THEN starts animating (rAF + CSS). Tests whether the blank is
// an animation-DURING-establishment race: if all establish their first frame while
// static, then start animating, the fix is "establish before animating".
const int kAnimDelayMs = int.fromEnvironment('CEF_ANIM_DELAY_MS', defaultValue: 0);
// --dart-define=CEF_REVEAL_MS=2000 => with cef_host FLUTTER_CEF_BORN_HIDDEN=1, reveal
// tiles ONE AT A TIME (setVisible(true)) every N ms so first-frame establishment is
// serialized (one concurrent first-frame allocation), the Chrome background-tab model.
const int kRevealMs = int.fromEnvironment('CEF_REVEAL_MS', defaultValue: 0);
// --dart-define=CEF_REAL_URLS=true => load REAL websites (heavy JS/WebGL/video, real
// network + first-paint timing) instead of the synthetic anim HTML, cycling the list
// below across the tiles. The hardest stress: real establishment latency + real GPU load.
const bool kRealUrls = bool.fromEnvironment('CEF_REAL_URLS');
const List<String> _realUrls = [
  'https://bruno-simon.com', // WebGL 3D driving-game portfolio (brutal)
  'https://www.shadertoy.com', // GPU fragment shaders
  'https://webglsamples.org/aquarium/aquarium.html', // animated WebGL aquarium
  'https://threejs.org', // WebGL
  'https://earth.google.com/web', // 3D globe (very heavy)
  'https://www.google.com/maps', // WebGL maps
  'https://www.windy.com', // animated WebGL weather maps
  'https://www.youtube.com', // video grid
  'https://www.twitch.tv', // live video
  'https://playcanvas.com', // WebGL 3D engine demos
  'https://pixijs.com', // WebGL 2D
  'https://www.apple.com/macbook-pro/', // scroll-driven video
  'https://www.nytimes.com', // heavy media/ads
  'https://www.reddit.com', // infinite scroll + media
  'https://www.amazon.com', // heavy commerce
  'https://www.airbnb.com', // maps + image grids
  'https://codepen.io/trending', // live code demos
  'https://www.tradingview.com/chart/', // live charts
  'https://www.flightradar24.com', // live animated map (moving planes)
  'https://www.spotify.com', // web player landing
];
const int kStep = 4;
// --dart-define=CEF_CHURN=true => oscillate create-all / dispose-all every 12s,
// to leak-test create/dispose reclamation (procs/RSS/FD must return to baseline).
const bool kChurn = bool.fromEnvironment('CEF_CHURN');
const String _statsPath = '/tmp/cef_stress.jsonl';

const _animHtml = '''<!doctype html><meta charset="utf-8">
<style>
  html,body{margin:0;height:100%;overflow:hidden;font:13px system-ui;color:#fff}
  body{display:grid;place-items:center;
    background:linear-gradient(45deg,#1e293b,#0ea5e9,#8b5cf6,#1e293b);
    background-size:400% 400%;animation:g 4s ease infinite}
  @keyframes g{0%{background-position:0% 50%}50%{background-position:100% 50%}100%{background-position:0% 50%}}
  #b{width:90px;height:90px;border-radius:18px;background:rgba(255,255,255,.9);
    animation:spin 1.2s linear infinite}
  @keyframes spin{to{transform:rotate(360deg)}}
  #f{position:absolute;top:6px;left:8px;opacity:.85}
</style>
<div id=b></div><div id=f>fps …</div>
<script>
  var n=0,last=performance.now(),acc=0,fps=document.getElementById('f');
  function loop(t){ n++; acc+=t-last; last=t;
    if(acc>=500){ fps.textContent=Math.round(n/(acc/1000))+' fps'; n=0; acc=0; }
    requestAnimationFrame(loop); }
  requestAnimationFrame(loop);
</script>''';

// Animated page that holds STATIC for [delayMs] after load, then starts the CSS
// animation + rAF loop. Models "establish the first frame before animating".
String _delayedAnimHtml(int delayMs) => '''<!doctype html><meta charset="utf-8">
<style>
  html,body{margin:0;height:100%;overflow:hidden;font:13px system-ui;color:#fff}
  body{display:grid;place-items:center;
    background:linear-gradient(45deg,#1e293b,#0ea5e9,#8b5cf6,#1e293b);
    background-size:400% 400%}
  body.go{animation:g 4s ease infinite}
  @keyframes g{0%{background-position:0% 50%}50%{background-position:100% 50%}100%{background-position:0% 50%}}
  #b{width:90px;height:90px;border-radius:18px;background:rgba(255,255,255,.9)}
  #b.go{animation:spin 1.2s linear infinite}
  @keyframes spin{to{transform:rotate(360deg)}}
  #f{position:absolute;top:6px;left:8px;opacity:.85}
</style>
<div id=b></div><div id=f>warming…</div>
<script>
  function start(){
    document.body.classList.add('go'); document.getElementById('b').classList.add('go');
    var n=0,last=performance.now(),acc=0,fps=document.getElementById('f');
    function loop(t){ n++; acc+=t-last; last=t;
      if(acc>=500){ fps.textContent=Math.round(n/(acc/1000))+' fps'; n=0; acc=0; }
      requestAnimationFrame(loop); }
    requestAnimationFrame(loop);
  }
  setTimeout(start, $delayMs);
</script>''';

// Static page: a gradient + a box, painted ONCE — no CSS animation, no rAF, no
// timers, so the compositor produces one frame then idles (models static content).
const _staticHtml = '''<!doctype html><meta charset="utf-8">
<body style="margin:0;height:100vh;display:grid;place-items:center;font:14px system-ui;
  color:#fff;background:linear-gradient(135deg,#0ea5e9,#8b5cf6)">
<div style="width:90px;height:90px;border-radius:18px;background:rgba(255,255,255,.9)"></div>
<div style="position:absolute;top:6px;left:8px;opacity:.85">static</div></body>''';

void main() => runApp(const StressApp());

class StressApp extends StatefulWidget {
  const StressApp({super.key});
  @override
  State<StressApp> createState() => _StressAppState();
}

class _StressAppState extends State<StressApp> {
  final List<CefWebController> _controllers = [];
  final Set<int> _loaded = {};
  int _nextId = 0;

  // rolling frame-timing window (microseconds of total span per frame).
  final List<int> _frameMicros = [];
  String _stats = 'warming up…';
  late final Stopwatch _sw = Stopwatch()..start();
  Timer? _report;

  @override
  void initState() {
    super.initState();
    if (kCreateDelayMs <= 0) {
      for (var i = 0; i < kInitialViews; i++) {
        _add();
      }
    } else {
      // Gradual bring-up: one view every kCreateDelayMs, mimicking a human opening
      // windows one at a time (never a 12-at-once create burst).
      _add();
      var created = 1;
      Timer.periodic(Duration(milliseconds: kCreateDelayMs), (t) {
        if (created >= kInitialViews) {
          t.cancel();
          return;
        }
        _add();
        created++;
      });
    }
    if (kRevealMs > 0) {
      // Serial reveal: ensure all hidden, then show one every kRevealMs (with cef_host
      // born-hidden, each establishes alone against an already-steady set).
      Timer(const Duration(milliseconds: 600), () {
        for (final c in _controllers) {
          c.setVisible(false);
        }
        var shown = 0;
        Timer.periodic(Duration(milliseconds: kRevealMs), (t) {
          if (shown >= _controllers.length) {
            t.cancel();
            return;
          }
          _controllers[shown].setVisible(true);
          shown++;
        });
      });
    } else if (kLiveCap > 0) {
      // Live-cap masking: after browsers come up, keep only kLiveCap visible at a time
      // and rotate. _liveStart is the index of the first visible tile in the rotating
      // window; reapply visibility on a cadence so each tile gets a live turn to paint.
      Timer(const Duration(milliseconds: 800), _applyLiveCap);
      Timer.periodic(const Duration(milliseconds: 2500), (_) {
        _liveStart = (_liveStart + kLiveCap) % kInitialViews;
        _applyLiveCap();
      });
    }
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _report = Timer.periodic(const Duration(seconds: 2), (_) => _emit());
    if (kForceRepaint) {
      // Force a Flutter frame ~60fps so the Texture widgets get pulled every frame.
      Timer.periodic(const Duration(milliseconds: 16), (_) {
        if (mounted) setState(() {});
      });
    }
    if (kChurn) {
      Timer.periodic(const Duration(seconds: 12), (_) {
        if (_controllers.isEmpty) {
          for (var i = 0; i < kInitialViews; i++) {
            _add();
          }
        } else {
          while (_controllers.isNotEmpty) {
            _remove();
          }
        }
      });
    }
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      _frameMicros.add(t.totalSpan.inMicroseconds);
    }
    if (_frameMicros.length > 600) {
      _frameMicros.removeRange(0, _frameMicros.length - 600);
    }
  }

  void _emit() {
    if (_frameMicros.isEmpty) return;
    final xs = List<int>.from(_frameMicros)..sort();
    final avg = xs.reduce((a, b) => a + b) / xs.length / 1000.0;
    final p90 = xs[(xs.length * 0.90).floor().clamp(0, xs.length - 1)] / 1000.0;
    final p99 = xs[(xs.length * 0.99).floor().clamp(0, xs.length - 1)] / 1000.0;
    // jank = frames slower than 1.5x a 60Hz budget (~25ms).
    final jank = xs.where((m) => m > 25000).length / xs.length * 100;
    final row = {
      'tMs': _sw.elapsedMilliseconds,
      'views': _controllers.length,
      'profile': kProfile ?? 'ephemeral',
      'avgMs': double.parse(avg.toStringAsFixed(2)),
      'p90Ms': double.parse(p90.toStringAsFixed(2)),
      'p99Ms': double.parse(p99.toStringAsFixed(2)),
      'jankPct': double.parse(jank.toStringAsFixed(1)),
    };
    // ignore: avoid_print
    print('CEF_STRESS ${jsonEncode(row)}');
    try {
      File(_statsPath).writeAsStringSync('${jsonEncode(row)}\n',
          mode: FileMode.append);
    } catch (_) {}
    _frameMicros.clear();
    if (mounted) {
      setState(() => _stats =
          'views=${_controllers.length}  avg=${row['avgMs']}ms  p90=${row['p90Ms']}ms  jank=${row['jankPct']}%');
    }
  }

  int _liveStart = 0;

  // Apply the rotating live window: tiles in [_liveStart, _liveStart+kLiveCap) are
  // CEF-visible (live), all others hidden (frozen on last frame). Re-applied on a timer.
  void _applyLiveCap() {
    final n = _controllers.length;
    if (n == 0) return;
    for (var i = 0; i < n; i++) {
      final inWindow = ((i - _liveStart + kInitialViews) % kInitialViews) < kLiveCap;
      _controllers[i].setVisible(inWindow);
    }
  }

  String? _poolProfile(int id) =>
      kProfile == null ? null : '$kProfile-${id % kPoolSize}';

  final Map<String, String> _urlBySession = {};
  final Map<String, int> _recreateCount = {};

  CefWebController _makeController() {
    final id = _nextId++;
    final c = CefWebController(profile: _poolProfile(id));
    if (kRealUrls) _urlBySession[c.sessionId] = _realUrls[id % _realUrls.length];
    String tag(String u) => u.length > 22 ? u.substring(0, 22) : u;
    c.onPageStarted = (url) {
      // ignore: avoid_print
      print('CEF_STRESS_LOAD view=$id pageStarted ${tag(url)}');
      // Real-URL mode: let the real page load (no synthetic HTML injection).
      if (!kRealUrls && _loaded.add(id)) {
        c.loadHtmlString(kStatic
            ? _staticHtml
            : kAnimDelayMs > 0
                ? _delayedAnimHtml(kAnimDelayMs)
                : _animHtml);
      }
    };
    c.onPageFinished = (url) {
      // ignore: avoid_print
      print('CEF_STRESS_LOAD view=$id pageFinished ${tag(url)}');
    };
    c.onLoadError = (e) {
      // ignore: avoid_print
      print('CEF_STRESS_LOAD view=$id loadError ${e.errorCode} ${tag(e.url)}');
    };
    c.onPaintStalled = () {
      // ignore: avoid_print
      print('CEF_STRESS_RECREATE view=$id stalled (attempt ${_recreateCount[c.sessionId] ?? 0})');
      if (!kRecreateOnStall) return; // patience-only mode: rely on the pump
      // Bounded, backed-off recreate. The paintStalled signal REPEATS while blank, so we
      // gate on a per-tile attempt count: recreate is destructive (restarts the page
      // load), so cap it — a still-loading heavy page paints on its own (patience); only a
      // genuinely-stuck tile needs the (serialized → low-contention → succeeds) recreate.
      final n = _recreateCount[c.sessionId] ?? 0;
      if (n >= kMaxRecreates) return; // exhausted → leave it to the pump, never churn
      final idx = _controllers.indexOf(c);
      if (idx < 0) return;
      final nc = _makeController();
      _recreateCount[nc.sessionId] = n + 1; // carry the count to the replacement
      setState(() => _controllers[idx] = nc);
      c.dispose();
    };
    return c;
  }

  void _add() {
    setState(() => _controllers.add(_makeController()));
  }

  void _remove() {
    if (_controllers.isEmpty) return;
    final c = _controllers.removeLast();
    setState(() {});
    c.dispose();
  }

  @override
  void dispose() {
    _report?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = _controllers.length;
    final cols = (n <= 1) ? 1 : (n <= 4) ? 2 : (n <= 9) ? 3 : (n <= 16) ? 4 : 5;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Column(
          children: [
            Container(
              color: const Color(0xFF0B1220),
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(
                    child: Text('stress — $_stats',
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600)),
                  ),
                  TextButton(
                      onPressed: () {
                        for (var i = 0; i < kStep; i++) {
                          _add();
                        }
                      },
                      child: const Text('+$kStep')),
                  TextButton(
                      onPressed: () {
                        for (var i = 0; i < kStep; i++) {
                          _remove();
                        }
                      },
                      child: const Text('-$kStep')),
                ],
              ),
            ),
            Expanded(
              child: kTilePx > 0
                  ? SingleChildScrollView(
                      child: Wrap(
                        children: [
                          for (final c in _controllers)
                            SizedBox(
                              width: kTilePx.toDouble(),
                              height: kTilePx.toDouble(),
                              child: Padding(
                                padding: const EdgeInsets.all(2),
                                child: CefWebView(
                                    key: ValueKey(c.sessionId),
                                    url: _urlBySession[c.sessionId] ?? 'about:blank',
                                    controller: c,
                                    profile: c.profile),
                              ),
                            ),
                        ],
                      ),
                    )
                  : GridView.count(
                      crossAxisCount: cols,
                      children: [
                        for (final c in _controllers)
                          Padding(
                            padding: const EdgeInsets.all(2),
                            child: CefWebView(
                                key: ValueKey(c.sessionId),
                                url: _urlBySession[c.sessionId] ?? 'about:blank',
                                controller: c,
                                profile: c.profile),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
