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
//     processGone('crashed') while the other keeps painting and answering;
//   * a tile whose renderer hangs ends alone, too: its page loops forever, the
//     liveness ping goes unanswered, and it gets processGone('crashed'). A
//     page on the same host that only breaks evals is left alone, because the
//     ping is answered by the renderer, not the page;
//   * a GPU process that Chromium replaces (chrome://gpucrash) leaves the
//     host's tiles painting.
//
// The result is a `CEF_PROBE_RESULT PASS|FAIL` line on stdout and, because a
// Windows GUI app's stdout isn't reliably captured, also in the file named by
// the FLUTTER_CEF_PROBE_OUT env var when it is set.
//
// Run:  flutter build windows --debug -t lib/windows_smoke_probe.dart
//       set FLUTTER_CEF_PROBE_OUT=%TEMP%\smoke.txt
//       build\windows\x64\runner\Debug\flutter_cef_example.exe
import 'dart:async';
import 'dart:convert';
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

// A page with nothing to animate: it presents only when something changes.
const _static =
    '<!doctype html><body style="background:#234;color:#fff">'
    '<h1>static</h1>';

// The crash-loop and hang cases' tiles are served at different sites, so site
// isolation gives each its own renderer process, and killing or hanging one
// can't take the others with it.
const _sentinelUrl = 'https://flutter-cef-sentinel.test/';
const _hangUrl = 'https://flutter-cef-hang.test/';
const _noEvalsUrl = 'https://flutter-cef-no-evals.test/';

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
    await _hungRenderer();
    await _gpuProcessReplaced();
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

  /// A renderer that stops answering ends only its own tile, and a page that
  /// merely can't answer evals is left alone.
  Future<void> _hungRenderer() async {
    const tag = 'hung renderer';
    const group = 'windows-smoke-hang';
    final sentinel = CefWebController(hostGroup: group);
    final hung = CefWebController(hostGroup: group);
    final noEvals = CefWebController(hostGroup: group);
    final clock = Stopwatch()..start();
    void event(String what) =>
        _log('  $tag +${clock.elapsedMilliseconds}ms $what');
    final loaded = <CefWebController>{};
    String? sentinelGone;
    String? noEvalsGone;
    final hungGone = Completer<String>();
    sentinel.onProcessGone = (r) => sentinelGone ??= r;
    noEvals.onProcessGone = (r) {
      event('evals-breaking tile processGone($r)');
      noEvalsGone ??= r;
    };
    hung.onProcessGone = (r) {
      event('hung tile processGone($r)');
      if (!hungGone.isCompleted) hungGone.complete(r);
    };
    for (final c in [sentinel, hung, noEvals]) {
      c.onPageFinished = (_) => loaded.add(c);
    }
    try {
      for (final (c, url, html) in [
        (sentinel, _sentinelUrl, _html),
        (hung, _hangUrl, _static),
        (noEvals, _noEvalsUrl, _static),
      ]) {
        await c.create(
          url: url,
          html: html,
          htmlBaseUrl: url,
          width: 320,
          height: 240,
        );
      }
      _check(
        '$tag: the tiles load and paint',
        await _waitFor(() => loaded.length == 3, const Duration(seconds: 60)) &&
            await _presentsPast(hung, 0) &&
            await _presentsPast(noEvals, 0),
      );

      // Every eval's reply goes through JSON.stringify in the page, so once
      // that throws the page can't answer one. Broken after this eval has
      // answered.
      final one = await noEvals
          .runJavaScriptReturningResult(
            '(setTimeout(() => { JSON.stringify = () => { throw 0; }; }, 0), 1)',
          )
          .timeout(const Duration(seconds: 10));
      _check(
        '$tag: an eval answers before the page breaks them',
        '$one' == '1',
        one,
      );
      final broken = Stopwatch()..start();
      // This page never returns to its event loop, so its renderer's main
      // thread can't answer the ping.
      await hung.executeJavaScript('setTimeout(() => { for (;;) {} }, 0)');
      event('page hung');

      // The sweep pings a tile that has shown no new frame for 10 s, and a
      // renderer that leaves the ping unanswered for 15 s is hung.
      final gone = await hungGone.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () => '<none within 60 s>',
      );
      _check(
        '$tag: the hung tile gets processGone(crashed)',
        gone == 'crashed',
        gone,
      );
      // By 45 s the sweep has pinged the evals-breaking page too. Had the page
      // been asked rather than its renderer, it would be gone by now.
      final rest = const Duration(seconds: 45) - broken.elapsed;
      if (rest > Duration.zero) await Future<void>.delayed(rest);
      _check(
        '$tag: a page that can\'t answer evals is left alone',
        noEvalsGone == null,
        noEvalsGone,
      );

      final before = await _presents(sentinel);
      _check(
        '$tag: the other tiles keep painting',
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
      _check('$tag: the other tiles answer evals', '$four' == '4', four);
      _check(
        '$tag: the other tiles get no processGone',
        sentinelGone == null,
        sentinelGone,
      );
    } catch (e, st) {
      _check('$tag: ran to completion', false, '$e\n$st');
    }
    await sentinel.dispose();
    await hung.dispose();
    await noEvals.dispose();
  }

  /// A GPU process that Chromium replaces leaves the host's tiles painting,
  /// so Windows, unlike macOS, doesn't end a host for it.
  Future<void> _gpuProcessReplaced() async {
    const tag = 'gpu process replaced';
    const group = 'windows-smoke-gpu';
    final a = CefWebController(hostGroup: group);
    final b = CefWebController(hostGroup: group);
    String? gone;
    a.onProcessGone = (r) => gone ??= 'a: $r';
    b.onProcessGone = (r) => gone ??= 'b: $r';
    try {
      await a.create(
        url: _sentinelUrl,
        html: _html,
        htmlBaseUrl: _sentinelUrl,
        width: 320,
        height: 240,
      );
      await b.create(
        url: 'about:blank',
        html: _static,
        width: 320,
        height: 240,
      );
      _check(
        '$tag: the tiles paint',
        await _presentsPast(a, 0, within: const Duration(seconds: 60)) &&
            await _presentsPast(b, 0, within: const Duration(seconds: 60)),
      );
      final before = await _gpuProcesses();
      // chrome://gpucrash is a debug URL: Chromium crashes the GPU process
      // and starts a new one.
      await b.navigate('chrome://gpucrash');
      // Replaced: one of the GPU processes from before is gone, and a new one
      // is running.
      bool replaced(Set<int> after) =>
          !after.containsAll(before) && !before.containsAll(after);
      var after = before;
      final sw = Stopwatch()..start();
      while (sw.elapsed < const Duration(seconds: 15) && !replaced(after)) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        after = await _gpuProcesses();
      }
      _check(
        '$tag: chrome://gpucrash replaces the GPU process',
        replaced(after),
        'before $before, after $after',
      );
      final presented = await _presents(a);
      await Future<void>.delayed(const Duration(seconds: 2));
      final since = await _presents(a) - presented;
      _check(
        '$tag: the tiles keep painting',
        since > 30,
        '$since presents in 2 s',
      );
      final c = CefWebController(hostGroup: group);
      await c.create(url: 'about:blank', html: _html, width: 320, height: 240);
      _check(
        '$tag: a new tile on the host paints',
        await _presentsPast(c, 0, within: const Duration(seconds: 30)),
        await c.sessionStats(),
      );
      await c.dispose();
      _check('$tag: no processGone', gone == null, gone);
    } catch (e, st) {
      _check('$tag: ran to completion', false, '$e\n$st');
    }
    await a.dispose();
    await b.dispose();
  }

  /// The pids of the running GPU processes of every cef_host.
  Future<Set<int>> _gpuProcesses() async {
    const script =
        "Get-CimInstance Win32_Process -Filter \"Name='cef_host.exe'\" | "
        "Where-Object { \$_.CommandLine -like '*--type=gpu-process*' } | "
        "ForEach-Object { \$_.ProcessId }";
    // -EncodedCommand takes UTF-16LE, base64: no quoting to get wrong.
    final utf16 = <int>[];
    for (final u in script.codeUnits) {
      utf16
        ..add(u & 0xff)
        ..add(u >> 8);
    }
    final r = await Process.run('powershell', [
      '-NoProfile',
      '-EncodedCommand',
      base64Encode(utf16),
    ]);
    return {
      for (final w in '${r.stdout}'.split(RegExp(r'\s+'))) ?int.tryParse(w),
    };
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
