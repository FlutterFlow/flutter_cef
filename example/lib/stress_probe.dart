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
const int kInitialViews = 12;
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
    for (var i = 0; i < kInitialViews; i++) {
      _add();
    }
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _report = Timer.periodic(const Duration(seconds: 2), (_) => _emit());
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

  void _add() {
    final id = _nextId++;
    final c = CefWebController(profile: kProfile);
    c.onPageStarted = (_) {
      if (_loaded.add(id)) c.loadHtmlString(_animHtml);
    };
    setState(() => _controllers.add(c));
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
              child: GridView.count(
                crossAxisCount: cols,
                children: [
                  for (final c in _controllers)
                    Padding(
                      padding: const EdgeInsets.all(2),
                      child: CefWebView(
                          key: ValueKey(c.sessionId),
                          url: 'about:blank',
                          controller: c,
                          profile: kProfile),
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
