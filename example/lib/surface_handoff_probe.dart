// Tile surfaces are private to this app — END-TO-END probe (macOS).
//
// Auto-running, no-interaction regression test. cef_host paints each tile into
// an IOSurface and hands it to the plugin by Mach port. The surfaces used to be
// global, so any local process could look one up by id and read the page.
//   * a tile paints, and keeps painting through resizes and scale changes (each
//     one is a new surface handed over);
//   * the surface id from getFrameSurface resolves with IOSurfaceLookup in this
//     process (as Campus's video export does);
//   * the same id does not resolve from another process.
//
// A `CEF_PROBE_RESULT PASS|FAIL` line is printed to stdout at the end.
//
// Run:  FLUTTER_CEF_HOST=<.../cef_host.app/Contents/MacOS/cef_host> \
//         flutter run -d macos -t lib/surface_handoff_probe.dart
import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cef/flutter_cef.dart';

const _page =
    '<!doctype html><body style="margin:0;background:#1a6">'
    '<h1 id=t>0</h1><script>var n=0;setInterval(function(){'
    'document.getElementById("t").textContent=++n;},50);</script>';

final _ioSurface = DynamicLibrary.open(
  '/System/Library/Frameworks/IOSurface.framework/IOSurface',
);
final _cf = DynamicLibrary.open(
  '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation',
);
final _lookup = _ioSurface
    .lookupFunction<
      Pointer<Void> Function(Uint32),
      Pointer<Void> Function(int)
    >('IOSurfaceLookup');
final _release = _cf
    .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
      'CFRelease',
    );

bool _resolvesHere(int id) {
  final s = _lookup(id);
  if (s == nullptr) return false;
  _release(s);
  return true;
}

Future<bool> _resolvesElsewhere(int id) async {
  final r = await Process.run('/usr/bin/xcrun', [
    'swift',
    '-e',
    'import IOSurface\nprint(IOSurfaceLookup($id) == nil ? "no" : "yes")',
  ]);
  if (r.exitCode != 0) throw StateError('swift failed: ${r.stderr}');
  return '${r.stdout}'.trim() == 'yes';
}

void main() => runApp(const MaterialApp(home: ProbeApp()));

class ProbeApp extends StatefulWidget {
  const ProbeApp({super.key});
  @override
  State<ProbeApp> createState() => _ProbeAppState();
}

class _ProbeAppState extends State<ProbeApp> {
  final List<String> _lines = [];
  bool _pass = true;

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

  /// Waits for a surface of [w]x[h] physical pixels that has been presented.
  Future<CefSurfaceInfo?> _surfaceOf(
    CefWebController c,
    int w,
    int h,
    int presentsBefore,
  ) async {
    final sw = Stopwatch()..start();
    while (sw.elapsed.inSeconds < 10) {
      final s = await c.getFrameSurface();
      final presents = (await c.sessionStats())?.presentCount ?? 0;
      if (s != null &&
          s.surfaceId != 0 &&
          s.width == w &&
          s.height == h &&
          presents > presentsBefore) {
        return s;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return c.getFrameSurface();
  }

  Future<void> _run() async {
    try {
      final c = CefWebController();
      await c.create(url: 'about:blank', html: _page, width: 320, height: 240);
      var s = await _surfaceOf(c, 320, 240, 0);
      _check('the tile paints', s != null && s.width == 320, s?.width);

      final sizes = [
        (400, 300, 1.0),
        (400, 300, 2.0),
        (257, 311, 2.0),
        (640, 480, 1.5),
        (320, 240, 1.0),
      ];
      var ok = 0;
      for (final (w, h, dpr) in sizes) {
        final before = (await c.sessionStats())?.presentCount ?? 0;
        await c.resize(w, h, dpr: dpr);
        s = await _surfaceOf(c, (w * dpr).round(), (h * dpr).round(), before);
        if (s != null &&
            s.width == (w * dpr).round() &&
            s.height == (h * dpr).round()) {
          ok++;
        } else {
          _log('resize to ${w}x$h@$dpr landed ${s?.width}x${s?.height}');
        }
      }
      _check(
        'every resize lands on a surface of the new size',
        ok == sizes.length,
        ok,
      );

      final id = s?.surfaceId ?? 0;
      _check('the surface id resolves in this process', _resolvesHere(id), id);
      _check(
        'the surface id does not resolve from another process',
        !await _resolvesElsewhere(id),
        id,
      );
      await c.dispose();
    } catch (e, st) {
      _check('probe ran to completion', false, '$e\n$st');
    }
    // ignore: avoid_print
    print('CEF_PROBE_RESULT ${_pass ? "PASS" : "FAIL"}');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(_pass ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListView(
        children: [
          for (final l in _lines) Text(l, style: const TextStyle(fontSize: 11)),
        ],
      ),
    );
  }
}
