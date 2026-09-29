// Switching a view's device frame keeps it painting — END-TO-END probe (macOS).
//
// FlutterFlow's Test Mode lays its preview out at the emulated device's logical
// size inside a FittedBox and renders it at devicePixelRatio × zoom, where zoom
// fits the device into the panel. Switching the device frame therefore changes
// the view's size AND its render scale at once. When the slot that hosts the
// preview remounts, the preview is first parked for a frame (hidden, at a
// fallback size and zoom 1) and then shown at the new device.
//
// Each round switches to the next device one of three ways:
//   plain  size + render scale change in one frame
//   blip   one parked frame (hidden, 393×852, zoom 1), then the new device shown
//   anim   size + render scale lerp over ~15 frames
// and checks that, within LIMIT_MS, the page reports the new viewport and
// density, and that it still presents a frame after a DOM change.
//
// The regression: a scale change that reached CEF while it was still waiting
// to paint an earlier resize was applied later under the renderer's old surface
// id. viz rejected the renderer's next frame and dropped its frame sink, and the
// view never painted again: no crash, no stall report, JS still answering, and
// neither hide/show nor reload brought it back. A page slow to relayout (like a
// debug web build) makes that wait long, so by default the page blocks its main
// thread for PAGE_SLOW_MS on every resize and the app's UI thread is kept busy
// for JANK_MS per frame around each switch. With FIXED_DPR=true switches change
// only the size, which never wedged.
//
// cef_host logs `resize: no paint at WxH ... kick N` when a resize waits a
// second without a paint at its size. A healthy run has none; if they're back,
// cef_host has stopped asking for a fresh capture while a resize waits.
//
// Run:  FLUTTER_CEF_HOST=<.../cef_host.app/Contents/MacOS/cef_host> \
//         flutter run -d macos -t lib/device_frame_probe.dart
//       [--dart-define=ROUNDS=30 --dart-define=LIMIT_MS=4000
//        --dart-define=PAGE_SLOW_MS=600 --dart-define=JANK_MS=40
//        --dart-define=FIXED_DPR=true --dart-define=PAGE_URL=<a served web app>]
import 'dart:async';
import 'dart:io';
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_cef/flutter_cef.dart';

const _rounds = int.fromEnvironment('ROUNDS', defaultValue: 30);
const _limitMs = int.fromEnvironment('LIMIT_MS', defaultValue: 4000);
const _slowMs = String.fromEnvironment('PAGE_SLOW_MS', defaultValue: '600');
const _jankMs = int.fromEnvironment('JANK_MS', defaultValue: 40);
const _fixedDpr = bool.fromEnvironment('FIXED_DPR');
// A page to preview instead of the built-in one, e.g. a served Flutter web app.
// It has to repaint on its own (a ticking clock) for the liveness check.
const _pageUrl = String.fromEnvironment('PAGE_URL');

// Like a Flutter web app: a WebGL canvas that redraws only on resize or on
// request, so it is static between switches.
const _page = '''<!doctype html><meta charset="utf-8">
<style>
  html, body { margin: 0; height: 100%; overflow: hidden; background: #000; }
  canvas { position: absolute; inset: 0; width: 100%; height: 100%; }
  #n { position: absolute; left: 8px; top: 8px; color: #fff; font: 600 14px system-ui; }
</style>
<canvas id="c"></canvas><div id="n">0</div>
<script>
  const c = document.getElementById('c');
  const gl = c.getContext('webgl2') || c.getContext('webgl');
  let pending = false, draws = 0;
  function draw() {
    pending = false;
    const w = Math.round(innerWidth * devicePixelRatio);
    const h = Math.round(innerHeight * devicePixelRatio);
    if (c.width !== w || c.height !== h) { c.width = w; c.height = h; }
    gl.viewport(0, 0, w, h);
    draws++;
    gl.clearColor((draws % 7) / 7, 0.3, 0.6, 1);
    gl.clear(gl.COLOR_BUFFER_BIT);
  }
  window.__redraw = () => { if (!pending) { pending = true; requestAnimationFrame(draw); } };
  addEventListener('resize', () => {
    const t = performance.now();
    while (performance.now() - t < $_slowMs) {}
    window.__redraw();
  });
  window.__redraw();
</script>''';

class _Device {
  const _Device(this.name, this.w, this.h);
  final String name;
  final double w, h;
}

const _devices = [
  _Device('iPhone 16', 393, 852),
  _Device('iPad Air', 820, 1180),
  _Device('Desktop', 1440, 1024),
  _Device('Pixel 8', 412, 915),
  _Device('iPhone landscape', 852, 393),
  _Device('Custom', 600, 700),
];

// The fallback size a parked FlutterFlow preview is laid out at.
const _parked = _Device('parked', 393, 852);

void main() => runApp(const MaterialApp(home: ProbeApp()));

class ProbeApp extends StatefulWidget {
  const ProbeApp({super.key});
  @override
  State<ProbeApp> createState() => _ProbeAppState();
}

class _ProbeAppState extends State<ProbeApp> {
  final List<String> _lines = [];
  bool _pass = true;
  final _controller = CefWebController();

  // What the view is laid out at right now.
  _Device _device = _devices[0];
  // Override [_device] while an animated switch runs.
  Size? _animSize;
  double? _animZoom;
  bool _parkedNow = false;
  Size _panel = const Size(800, 600);
  double _screenDpr = 1.0;

  void _check(String name, bool cond, [Object? got]) {
    if (!cond) _pass = false;
    _log('${cond ? "PASS" : "FAIL"}  $name${cond ? "" : "  (got: $got)"}');
  }

  void _log(String s) {
    _lines.add(s);
    // ignore: avoid_print
    print('CEF_PROBE_LOG  $s');
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double _fitZoom(_Device d) =>
      0.9 * [_panel.width / d.w, _panel.height / d.h].reduce((a, b) => a < b ? a : b);

  double _renderScale(double zoom) => _screenDpr * (_fixedDpr ? 1.0 : zoom);

  Future<void> _frame() => SchedulerBinding.instance.endOfFrame;

  Future<String> _eval(String code) async {
    try {
      return '${await _controller.runJavaScriptReturningResult(code).timeout(const Duration(seconds: 3))}';
    } catch (e) {
      return 'eval failed: $e';
    }
  }

  Future<int> _presents() async => (await _controller.sessionStats())?.presentCount ?? -1;

  /// Milliseconds until [cond] holds, or null past [limitMs].
  Future<int?> _until(Future<bool> Function() cond, int limitMs) async {
    final sw = Stopwatch()..start();
    while (sw.elapsedMilliseconds < limitMs) {
      if (await cond()) return sw.elapsedMilliseconds;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return null;
  }

  Future<String> _viewport() =>
      _eval('innerWidth + "x" + innerHeight + "@" + devicePixelRatio.toFixed(3)');

  /// Whether the page presents a frame within 2 s of a DOM change.
  Future<bool> _painting(String mark) async {
    final before = await _presents();
    await _eval('(document.getElementById("n").textContent = "$mark", window.__redraw(), "ok")');
    return await _until(() async => await _presents() > before, 2000) != null;
  }

  /// Keeps the UI thread busy for [_jankMs] after every frame until [until].
  void _jankUntil(DateTime until) {
    if (_jankMs <= 0 || DateTime.now().isAfter(until)) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      final sw = Stopwatch()..start();
      while (sw.elapsedMilliseconds < _jankMs) {}
      _jankUntil(until);
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  Future<void> _switchTo(_Device next, String how) async {
    _jankUntil(DateTime.now().add(const Duration(milliseconds: 1500)));
    switch (how) {
      case 'plain':
        setState(() => _device = next);
        await _frame();
      case 'blip':
        // As SandboxAppPreviewHost does when its slot remounts: parked (hidden,
        // fallback size, zoom 1) for a frame, then the new device shown.
        setState(() => _parkedNow = true);
        await _controller.setVisible(false);
        await _frame();
        await _frame();
        setState(() {
          _parkedNow = false;
          _device = next;
        });
        await _controller.setVisible(true);
        await _frame();
      case 'anim':
        final from = Size(_device.w, _device.h);
        final fromZoom = _fitZoom(_device);
        const steps = 15;
        for (var i = 1; i <= steps; i++) {
          final t = Curves.easeInOut.transform(i / steps);
          setState(() {
            _animSize = Size.lerp(from, Size(next.w, next.h), t);
            _animZoom = lerpDouble(fromZoom, _fitZoom(next), t);
          });
          await _frame();
        }
        setState(() {
          _animSize = null;
          _animZoom = null;
          _device = next;
        });
        await _frame();
    }
  }

  Future<void> _run() async {
    final host = Platform.environment['FLUTTER_CEF_HOST'];
    _check('FLUTTER_CEF_HOST is set', host != null && host.isNotEmpty, host);
    final painted = await _until(() async => await _presents() > 0, 20000);
    if (painted == null) {
      _check('the view paints', false, '${await _controller.sessionStats()}');
      return _finish();
    }
    await _until(
        () async =>
            await _eval(_pageUrl.isEmpty
                ? 'typeof window.__redraw'
                : 'String(!!document.querySelector("flutter-view, flt-glass-pane"))') ==
            (_pageUrl.isEmpty ? 'function' : 'true'),
        15000);
    _log('first frame after ${painted}ms; screen dpr $_screenDpr; '
        'page slow ${_slowMs}ms, jank ${_jankMs}ms${_fixedDpr ? ", fixed dpr" : ""}');
    const hows = ['plain', 'blip', 'anim'];
    var failed = 0;
    final times = <int>[];
    for (var i = 1; i <= _rounds; i++) {
      final how = hows[(i - 1) % hows.length];
      final next = _devices[i % _devices.length];
      final dpr = _renderScale(_fitZoom(next)).clamp(0.5, 8.0);
      final want = '${next.w.round()}x${next.h.round()}@${dpr.toStringAsFixed(3)}';
      final label = 'round $i $how → ${next.name} $want';
      await _switchTo(next, how);
      // The page sees the new viewport and density...
      final sized = await _until(() async {
        final p = (await _eval('[innerWidth, innerHeight, devicePixelRatio].join(",")'))
            .split(',')
            .map(double.tryParse)
            .toList();
        return p.length == 3 &&
            p.every((v) => v != null) &&
            (p[0]! - next.w).abs() <= 1.5 &&
            (p[1]! - next.h).abs() <= 1.5 &&
            (p[2]! - dpr).abs() < 0.01;
      }, _limitMs);
      // ...and still paints.
      final live = await _painting('$i');
      if (sized != null && live) {
        times.add(sized);
        _log('$label: ${sized}ms');
        continue;
      }
      failed++;
      _log('$label: STUCK — viewport ${sized == null ? "stale" : "ok"}, '
          'presents ${live ? "ok" : "stopped"}; page ${await _viewport()}, '
          '${await _controller.sessionStats()}');
      // A view that stopped painting stays stopped; the rounds after it prove nothing.
      if (!live) break;
    }
    times.sort();
    final median = times.isEmpty ? 0 : times[times.length ~/ 2];
    final max = times.isEmpty ? 0 : times.last;
    _log('$failed of $_rounds switches stuck; others: median ${median}ms, max ${max}ms');
    _check('every device switch repaints at the new size within ${_limitMs}ms', failed == 0,
        '$failed of $_rounds');
    return _finish();
  }

  Future<void> _finish() async {
    // ignore: avoid_print
    print('CEF_PROBE_RESULT ${_pass ? "PASS" : "FAIL"}');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(_pass ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    _screenDpr = MediaQuery.devicePixelRatioOf(context);
    final d = _parkedNow ? _parked : _device;
    final size = _animSize ?? Size(d.w, d.h);
    final zoom = _parkedNow ? 1.0 : (_animZoom ?? _fitZoom(d));
    return Scaffold(
      body: Row(
        children: [
          Expanded(
            flex: 3,
            child: LayoutBuilder(builder: (context, c) {
              _panel = Size(c.maxWidth, c.maxHeight);
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: _parkedNow ? -10000 : 20,
                    top: _parkedNow ? -10000 : 20,
                    width: size.width * zoom,
                    height: size.height * zoom,
                    child: FittedBox(
                      fit: BoxFit.fill,
                      child: MediaQuery(
                        data: MediaQuery.of(context).copyWith(size: size),
                        child: SizedBox(
                          width: size.width,
                          height: size.height,
                          child: CefWebView(
                            url: _pageUrl.isEmpty ? 'about:blank' : _pageUrl,
                            html: _pageUrl.isEmpty ? _page : null,
                            controller: _controller,
                            renderScale: _renderScale(zoom),
                            enableZoomShortcuts: false,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            }),
          ),
          Expanded(
            flex: 2,
            child: ListView(
              children: [for (final l in _lines) Text(l, style: const TextStyle(fontSize: 10))],
            ),
          ),
        ],
      ),
    );
  }
}
