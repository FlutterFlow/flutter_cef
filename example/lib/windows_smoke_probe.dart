// Windows runtime smoke test — END-TO-END probe (Windows, run by CI).
//
// Auto-running, no-interaction. The windows-build CI job builds the example
// with this entry point and runs it against the cef_host it just built, so a
// change that compiles but can't paint, round-trip or recover fails CI instead
// of merging. It checks, on one view:
//   * the first frame reaches the texture (sessionStats().presentCount > 0);
//     CI runs the probe twice, the second time with
//     FLUTTER_CEF_SOFTWARE_COMPOSITING=1, so the software paint path is
//     covered too;
//   * the page finishes loading, then runJavaScriptReturningResult and a JS
//     channel round-trip;
//   * a resize is followed by frames at the new size;
//   * setAudioMuted / setFrameInterval are accepted, and a verb Windows can't
//     serve fails with PlatformException('unsupported');
//   * freeze() then thaw() brings frames back on the same texture;
//   * dispose;
//   * a tile whose renderer keeps crashing ends alone: two tiles share a host,
//     one is sent to chrome://kill until the host gives up on it, and it gets
//     processGone('crashed') while the other keeps painting and answering.
//
// The result is a `CEF_PROBE_RESULT PASS|FAIL` line on stdout and, because a
// Windows GUI app's stdout isn't reliably captured, also in the file named by
// the FLUTTER_CEF_PROBE_OUT env var when it is set.
//
// Run:  flutter build windows --debug -t lib/windows_smoke_probe.dart
//       set FLUTTER_CEF_PROBE_OUT=%TEMP%\smoke.txt
//       build\windows\x64\runner\Debug\flutter_cef_example.exe
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cef/flutter_cef.dart';

// Animates on the compositor, so a visible page presents every frame.
const _html = '''<!doctype html><meta charset="utf-8">
<style>
  body { margin: 0; background: #111; }
  #s { width: 120px; height: 120px; margin: 20px; animation: spin 1s linear infinite;
       background: linear-gradient(90deg, #f43f5e, #3b82f6); }
  @keyframes spin { to { transform: rotate(360deg); } }
</style>
<div id="s"></div>''';

// The crash-loop case's two tiles are served at different sites, so site
// isolation gives each its own renderer process and killing one can't take
// the other with it.
const _sentinelUrl = 'https://flutter-cef-sentinel.test/';

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

  Future<int> _presents(CefWebController c) async =>
      (await c.sessionStats())?.presentCount ?? -1;

  /// Waits until [c] has presented more than [floor] frames.
  Future<bool> _presentsPast(
    CefWebController c,
    int floor, {
    Duration within = const Duration(seconds: 30),
  }) async {
    final sw = Stopwatch()..start();
    while (sw.elapsed < within) {
      if (await _presents(c) > floor) return true;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return false;
  }

  Future<void> _run() async {
    final c = CefWebController();
    var gone = '';
    c.onProcessGone = (reason) => gone = reason;
    // The browser paints a blank frame before the document's load starts (on
    // the software path it often does), and a load that starts under an
    // in-flight eval fails that eval. So evals wait for the page to finish.
    final loaded = Completer<bool>();
    c.onPageFinished = (_) {
      if (!loaded.isCompleted) loaded.complete(true);
    };
    try {
      final received = Completer<String>();
      await c.addJavaScriptChannel(
        'smoke',
        onMessageReceived: (m) {
          if (!received.isCompleted) received.complete(m);
        },
      );
      final texture = await c.create(
        url: 'about:blank',
        html: _html,
        width: 320,
        height: 240,
      );
      _check('create returns a texture', texture != null, texture);

      // A cold CEF start on a CI runner can take a while.
      _check(
        'first frame reaches the texture',
        await _presentsPast(c, 0, within: const Duration(seconds: 90)),
        await c.sessionStats(),
      );
      final stats = await c.sessionStats();
      _check(
        'sessionStats reports the first present',
        stats != null && stats.firstPresentSeen && !stats.frozen,
        stats,
      );
      _check(
        'the page finishes loading',
        await loaded.future.timeout(
          const Duration(seconds: 60),
          onTimeout: () => false,
        ),
      );

      final two = await c
          .runJavaScriptReturningResult('1 + 1')
          .timeout(const Duration(seconds: 10));
      _check('eval round-trip', '$two' == '2', two);

      await c.executeJavaScript('smoke.postMessage("hello")');
      final msg = await received.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => '<timeout>',
      );
      _check('JS channel round-trip', msg == 'hello', msg);

      await c.resize(400, 300);
      final beforeResize = await _presents(c);
      var resized = false;
      final sw = Stopwatch()..start();
      while (!resized && sw.elapsed.inSeconds < 15) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final surface = await c.getFrameSurface();
        resized =
            await _presents(c) > beforeResize &&
            surface != null &&
            surface.width == 400 &&
            surface.height == 300;
      }
      _check(
        'frames at the new size after resize',
        resized,
        await c.getFrameSurface(),
      );

      await c.setAudioMuted(true);
      await c.setFrameInterval(33);
      _check('setAudioMuted / setFrameInterval accepted', true);

      Object? unsupported;
      try {
        await c.showEmojiPicker();
      } catch (e) {
        unsupported = e;
      }
      _check(
        'an unsupported verb fails as unsupported',
        unsupported is PlatformException && unsupported.code == 'unsupported',
        unsupported,
      );

      _check('freeze', await c.freeze(), await c.sessionStats());
      _check(
        'sessionStats says frozen',
        (await c.sessionStats())?.frozen == true,
        await c.sessionStats(),
      );
      final frozenAt = await _presents(c);
      _check('thaw', await c.thaw(), await c.sessionStats());
      _check(
        'frames resume after thaw',
        await _presentsPast(c, frozenAt),
        await c.sessionStats(),
      );

      _check('no processGone', gone.isEmpty, gone);
    } catch (e, st) {
      _check('probe ran to completion', false, '$e\n$st');
    }
    await c.dispose();
    await _crashLoops();
    _finish();
  }

  /// Polls [done] until it is true or [within] has passed.
  Future<bool> _waitFor(bool Function() done, Duration within) async {
    final sw = Stopwatch()..start();
    while (!done()) {
      if (sw.elapsed >= within) return false;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return true;
  }

  /// A tile whose renderer keeps crashing ends alone; its neighbour on the
  /// same host carries on. FLUTTER_CEF_SMOKE_CRASH_ROUNDS runs it more than
  /// once, each round on a fresh host.
  Future<void> _crashLoops() async {
    final rounds =
        int.tryParse(
          Platform.environment['FLUTTER_CEF_SMOKE_CRASH_ROUNDS'] ?? '',
        ) ??
        1;
    for (var round = 1; round <= rounds; round++) {
      await _crashLoop(round);
    }
  }

  Future<void> _crashLoop(int round) async {
    final tag = 'crash loop $round';
    final group = 'windows-smoke-crash-loop-$round';
    final sentinel = CefWebController(hostGroup: group);
    final victim = CefWebController(hostGroup: group);
    // A timeline of the victim's side, printed with the result.
    final clock = Stopwatch()..start();
    void event(String what) =>
        _log('  $tag +${clock.elapsedMilliseconds}ms $what');
    String? sentinelGone;
    final victimGone = Completer<String>();
    var sentinelLoaded = false;
    var victimFinishes = 0;
    sentinel.onProcessGone = (r) => sentinelGone ??= r;
    sentinel.onPageFinished = (_) => sentinelLoaded = true;
    victim.onProcessGone = (r) {
      event('victim processGone($r)');
      if (!victimGone.isCompleted) victimGone.complete(r);
    };
    victim.onPageFinished = (_) {
      victimFinishes++;
      event('victim pageFinished');
    };
    victim.onLoadError = (e) => event('victim loadError ${e.errorText}');
    try {
      // The sentinel is served at an https origin and the victim is a data:
      // page: different sites, so each gets its own renderer. A data: page
      // also reloads without the network. (An authored victim loses its
      // document at the first navigate, so its reloads went to DNS and came
      // back as error pages, which report no pageStarted.)
      await sentinel.create(
        url: _sentinelUrl,
        html: _html,
        htmlBaseUrl: _sentinelUrl,
        width: 320,
        height: 240,
      );
      await victim.create(
        url: 'about:blank',
        html: _html,
        width: 320,
        height: 240,
      );
      _check(
        '$tag: both tiles load',
        await _waitFor(
          () => sentinelLoaded && victimFinishes > 0,
          const Duration(seconds: 60),
        ),
      );

      // chrome://kill is a renderer debug URL: Chromium ends the tile's
      // renderer (exit code 1, no crash dump) and cef_host reloads the page.
      // Each kill waits for that reload to finish, or for processGone, before
      // the next, so every kill lands on a live, loaded page; one that shows
      // neither within 5 s is sent again. Four deaths within 10 s and the host
      // gives up on the tile.
      var kills = 0;
      while (!victimGone.isCompleted &&
          clock.elapsed < const Duration(seconds: 90)) {
        final finishes = victimFinishes;
        kills++;
        event('kill $kills');
        await victim.navigate('chrome://kill');
        await _waitFor(
          () => victimGone.isCompleted || victimFinishes > finishes,
          const Duration(seconds: 5),
        );
      }
      final gone = victimGone.isCompleted
          ? await victimGone.future
          : '<none after $kills kills>';
      _check(
        '$tag: the crash-looping tile gets processGone(crashed)',
        gone == 'crashed',
        gone,
      );

      final before = await _presents(sentinel);
      _check(
        '$tag: the other tile on the host keeps painting',
        await _presentsPast(
          sentinel,
          before,
          within: const Duration(seconds: 10),
        ),
        await sentinel.sessionStats(),
      );
      final four = await sentinel
          .runJavaScriptReturningResult('2 + 2')
          .timeout(const Duration(seconds: 10));
      _check('$tag: the other tile answers evals', '$four' == '4', four);
      _check(
        '$tag: the other tile gets no processGone',
        sentinelGone == null,
        sentinelGone,
      );
    } catch (e, st) {
      _check('$tag: ran to completion', false, '$e\n$st');
    }
    await sentinel.dispose();
    await victim.dispose();
  }

  void _finish() {
    final result = 'CEF_PROBE_RESULT ${_pass ? "PASS" : "FAIL"}';
    // ignore: avoid_print
    print(result);
    final out = Platform.environment['FLUTTER_CEF_PROBE_OUT'];
    if (out != null && out.isNotEmpty) {
      File(out).writeAsStringSync('${_lines.join('\n')}\n$result\n');
    }
    Future<void>.delayed(
      const Duration(milliseconds: 300),
    ).then((_) => exit(_pass ? 0 : 1));
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
