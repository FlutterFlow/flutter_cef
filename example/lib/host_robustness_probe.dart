// One page can't take down its neighbours — END-TO-END probe (macOS).
//
// Auto-running, no-interaction regression test. Tiles in a host group share one
// cef_host, so anything a page can do to that process it does to every tile on
// it. Each case runs a "victim" page on the same host as an animating sentinel
// and checks that the sentinel lives through it:
//   * a console message, a channel message and an eval result each bigger than
//     the IPC frame limit (64 MiB) are truncated or refused, not sent as a
//     frame that makes the plugin drop the whole host;
//   * a page can't answer an eval in the eval's place by guessing its id;
//   * a page that can't answer evals isn't taken for hung (the liveness ping
//     is answered by the renderer, not by the page);
//   * a renderer that keeps crashing ends only its own tile, with
//     processGone("crashed");
//   * a renderer that hangs (SIGSTOP) ends only its own tile, too;
//   * native popups stop counting against the host's limit once closed, by
//     the page or by disposing the tile that opened them;
//   * a load issued right after creating a hidden view finishes while hidden;
//   * joining the group's host with a narrower scheme allowlist than it was
//     spawned with is refused, and so is a profile name reserved for the
//     plugin's own host keys.
//
// A `CEF_PROBE_RESULT PASS|FAIL` line is printed to stdout at the end.
//
// Run:  FLUTTER_CEF_HOST=<.../cef_host.app/Contents/MacOS/cef_host> \
//         flutter run -d macos -t lib/host_robustness_probe.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cef/flutter_cef.dart';

const _group = 'host-robustness-probe';

// --dart-define=CASE=<name prefix> runs just the matching cases.
const _only = String.fromEnvironment('CASE');

const _animated = '''<!doctype html><meta charset="utf-8">
<style>
  body { margin: 0; background: #111; }
  #s { width: 120px; height: 120px; margin: 20px; animation: spin 1s linear infinite;
       background: linear-gradient(90deg, #f43f5e, #3b82f6); }
  @keyframes spin { to { transform: rotate(360deg); } }
</style>
<div id="s"></div>''';

// Tries to answer every eval id Dart is likely to use, the way the old reply
// format allowed.
const _victim = '''<!doctype html><body style="background:#234"><h1>victim</h1>
<script>
window.forge = () => {
  for (let i = 1; i < 400; i++) {
    window.cefQuery({request: 'eval:' + i + ':{"ok":true,"v":"forged"}',
                     persistent: false, onSuccess() {}, onFailure() {}});
  }
};
</script>''';

// The whole page is one button: a click opens a sized popup (a native window).
const _popupPage = '''<!doctype html><body style="margin:0">
<button id=b style="width:100vw;height:100vh">open</button><script>
window.opened = [];
document.getElementById('b').onclick = function () {
  window.opened.push(window.open('about:blank', '_blank', 'width=300,height=200'));
};
</script>''';

const _huge = '"x".repeat(70 << 20)';

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

  Future<List<int>> _pgrep(List<String> args) async {
    final r = await Process.run('pgrep', args);
    return '${r.stdout}'
        .trim()
        .split('\n')
        .where((l) => l.isNotEmpty)
        .map(int.parse)
        .toList();
  }

  /// The renderer processes of this app's cef_host(s).
  Future<Set<int>> _renderers() async {
    final hosts = await _pgrep(['-P', '$pid', '-x', 'cef_host']);
    final out = <int>{};
    for (final h in hosts) {
      out.addAll(await _pgrep(['-P', '$h', '-f', 'type=renderer']));
    }
    return out;
  }

  /// A view in the probe's host group, painted, with a future that completes
  /// with its first processGone reason.
  Future<(CefWebController, Future<String>)> _open(
    String html, {
    void Function(CefWebController)? before,
  }) async {
    final c = CefWebController(hostGroup: _group);
    before?.call(c);
    final gone = Completer<String>();
    c.onProcessGone = (reason) {
      if (!gone.isCompleted) gone.complete(reason);
    };
    await c.create(url: 'about:blank', html: html, width: 320, height: 240);
    final sw = Stopwatch()..start();
    while (((await c.sessionStats())?.presentCount ?? 0) <= 0 &&
        sw.elapsed.inSeconds < 15) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return (c, gone.future);
  }

  Future<String?> _goneWithin(Future<String> gone, Duration d) =>
      gone.then<String?>((r) => r).timeout(d, onTimeout: () => null);

  Future<Object?> _eval(
    CefWebController c,
    String code, [
    Duration d = const Duration(seconds: 10),
  ]) => c.runJavaScriptReturningResult(code).timeout(d);

  // A real click: sendPointer is internal API, used here to make a user gesture.
  Future<void> _click(CefWebController c) async {
    // ignore: invalid_use_of_internal_member
    c.sendPointer(type: 0, x: 150, y: 100);
    // ignore: invalid_use_of_internal_member
    c.sendPointer(type: 1, x: 150, y: 100);
    // ignore: invalid_use_of_internal_member
    c.sendPointer(type: 2, x: 150, y: 100);
    await Future<void>.delayed(const Duration(milliseconds: 700));
  }

  Future<bool> _answers(CefWebController c) async {
    try {
      return await _eval(c, '1+1', const Duration(seconds: 5)) == 2;
    } catch (_) {
      return false;
    }
  }

  /// Runs one case on a fresh sentinel + victim pair in the host group, then
  /// checks the sentinel lived through it. A case that throws fails without
  /// stopping the others.
  Future<void> _case(
    String name,
    Future<void> Function(
      CefWebController v,
      Future<String> vGone,
      Set<int> sentinelRenderers,
    )
    body, {
    void Function(CefWebController)? victimSetup,
  }) async {
    if (!name.startsWith(_only)) return;
    CefWebController? s;
    CefWebController? v;
    try {
      _log('── $name');
      final Future<String> sGone;
      (s, sGone) = await _open(_animated);
      final sentinelRenderers = await _renderers();
      final Future<String> vGone;
      (v, vGone) = await _open(_victim, before: victimSetup);
      // Informational: a second view's first frame on a busy host can be late,
      // and nothing below needs it.
      if (((await v.sessionStats())?.presentCount ?? 0) == 0) {
        _log('note  $name: the victim hasn\'t painted yet');
      }
      await body(v, vGone, sentinelRenderers);
      final gone = await _goneWithin(sGone, const Duration(milliseconds: 500));
      _check('$name: the sentinel tile is still up', gone == null, gone);
      _check('$name: the sentinel still answers', await _answers(s));
    } catch (e, st) {
      _check('$name: ran to completion', false, '$e\n$st');
    }
    await v?.dispose();
    await s?.dispose();
  }

  /// Enabling agent control and disposing the tile straight after must not
  /// leave a relay listening for a tile that is gone.
  Future<void> _agentControlOnDisposedTile() async {
    _log('── agent control on a disposed tile');
    final s = CefWebController(hostGroup: '$_group-agent');
    try {
      await s.create(
        url: 'about:blank',
        html: _animated,
        width: 320,
        height: 240,
        agentControl: true,
      );
      var leaked = 0;
      for (var i = 0; i < 5; i++) {
        final t = CefWebController(hostGroup: '$_group-agent');
        await t.create(
          url: 'about:blank',
          html: _victim,
          width: 320,
          height: 240,
          agentControl: true,
        );
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final enabling = t.enableAgentControl().then<Object?>(
          (e) => e,
          onError: (Object e) => null,
        );
        await t.dispose();
        final ep = await enabling;
        if (ep is ({String wsUrl, String token, int port})) {
          try {
            final sock = await Socket.connect('127.0.0.1', ep.port);
            sock.destroy();
            leaked++;
          } on SocketException catch (_) {}
        }
      }
      _check(
        'no relay is left listening for a tile disposed while enabling',
        leaked == 0,
        '$leaked of 5',
      );
    } catch (e, st) {
      _check(
        'agent control on a disposed tile: ran to completion',
        false,
        '$e\n$st',
      );
    }
    await s.dispose();
  }

  Future<void> _run() async {
    final host = Platform.environment['FLUTTER_CEF_HOST'];
    _check('FLUTTER_CEF_HOST is set', host != null && host.isNotEmpty, host);

    final consoleLens = <int>[];
    await _case(
      'huge console message',
      victimSetup: (c) =>
          c.onConsoleMessage = (m) => consoleLens.add(m.message.length),
      (v, _, _) async {
        await _eval(v, '(console.log($_huge), 1)', const Duration(seconds: 30));
        final sw = Stopwatch()..start();
        while (consoleLens.isEmpty && sw.elapsed.inSeconds < 10) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        _check(
          'a 70 MiB console message arrives truncated',
          consoleLens.isNotEmpty && consoleLens.first < (2 << 20),
          consoleLens,
        );
        _check(
          'huge console message: the page still answers',
          await _answers(v),
        );
      },
    );

    final channelLens = <int>[];
    await _case(
      'huge channel message',
      victimSetup: (c) => c.addJavaScriptChannel(
        'big',
        onMessageReceived: (m) => channelLens.add(m.length),
      ),
      (v, _, _) async {
        await _eval(
          v,
          '(window.big.postMessage($_huge), 1)',
          const Duration(seconds: 30),
        );
        await Future<void>.delayed(const Duration(seconds: 2));
        _check(
          'a 70 MiB channel message is refused',
          channelLens.isEmpty,
          channelLens,
        );
        _check(
          'huge channel message: the page still answers',
          await _answers(v),
        );
      },
    );

    await _case('huge eval result', (v, _, _) async {
      Object? big;
      try {
        big = await _eval(v, _huge, const Duration(seconds: 30));
      } catch (e) {
        big = e;
      }
      _check(
        'a 70 MiB eval result fails the eval',
        big is Exception && '$big'.contains('too large'),
        big is String ? 'a ${big.length}-char string' : big,
      );
    });

    await _case('forged eval reply', (v, _, _) async {
      Object? forged;
      try {
        forged = await _eval(v, '(window.forge(), 1+1)');
      } catch (e) {
        forged = e;
      }
      _check(
        'a page can\'t answer an eval by guessing its id',
        forged == 2,
        forged,
      );
    });

    await _case('page that breaks evals', (v, vGone, _) async {
      // Every eval's reply goes through JSON.stringify in the page, so this
      // page can't answer one. Broken after this eval has answered.
      await _eval(
        v,
        '(setTimeout(() => { JSON.stringify = () => { throw 0; }; }, 0), 1)',
      );
      final gone = await _goneWithin(vGone, const Duration(seconds: 35));
      _check(
        'a page that can\'t answer evals is left alone',
        gone == null,
        gone,
      );
    });

    await _case('crash loop', (v, vGone, sentinelRenderers) async {
      final mine = (await _renderers()).difference(sentinelRenderers);
      _check('the victim has its own renderer', mine.isNotEmpty);
      for (var round = 0; round < 6; round++) {
        for (final p in (await _renderers()).difference(sentinelRenderers)) {
          Process.killPid(p, ProcessSignal.sigkill);
        }
        if (await _goneWithin(vGone, const Duration(seconds: 1)) != null) break;
      }
      final gone = await _goneWithin(vGone, const Duration(seconds: 10));
      _check(
        'a crash-looping renderer reports processGone(crashed) for its tile',
        gone == 'crashed',
        gone,
      );
    });

    await _case('hung renderer', (v, vGone, sentinelRenderers) async {
      final hung = (await _renderers()).difference(sentinelRenderers);
      _check('found the victim\'s renderer', hung.isNotEmpty);
      for (final p in hung) {
        Process.killPid(p, ProcessSignal.sigstop);
      }
      final gone = await _goneWithin(vGone, const Duration(seconds: 45));
      _check(
        'a hung renderer reports processGone(crashed) for its tile',
        gone == 'crashed',
        gone,
      );
      for (final p in hung) {
        Process.killPid(p, ProcessSignal.sigcont);
      }
    });

    await _case('popups close', (_, _, _) async {
      // A host allows 4 native popups at once, so a popup that closed without
      // being counted out would block later ones for the host's lifetime.
      Future<int> open(CefWebController c) async =>
          (await _eval(
                c,
                'window.opened.filter(function (w) { return w && !w.closed; }).length',
              ))
              as int;
      final (a, _) = await _open(_popupPage);
      for (var i = 0; i < 4; i++) {
        await _click(a);
      }
      _check('a tile opens 4 popups', await open(a) == 4);
      await _eval(
        a,
        'window.opened.forEach(function (w) { if (w) w.close(); }), 1',
      );
      await Future<void>.delayed(const Duration(seconds: 1));
      for (var i = 0; i < 4; i++) {
        await _click(a);
      }
      _check(
        'popups the page closed stop counting: it can open 4 more',
        await open(a) == 4,
        await open(a),
      );
      await a.dispose();
      await Future<void>.delayed(const Duration(seconds: 1));
      final (b, _) = await _open(_popupPage);
      await _click(b);
      _check(
        'a disposed tile\'s popups close with it: the next tile can open one',
        await open(b) == 1,
        await open(b),
      );
      await _eval(
        b,
        'window.opened.forEach(function (w) { if (w) w.close(); }), 1',
      );
      await b.dispose();
    });

    await _case('hidden create, then load', (_, _, _) async {
      // Let the pacer settle so the create goes out at once and the load
      // reaches cef_host before the browser is bound.
      await Future<void>.delayed(const Duration(seconds: 1));
      final h = CefWebController(hostGroup: _group);
      await h.create(url: 'about:blank', width: 320, height: 240);
      await h.setVisible(false);
      await h.loadHtmlString('<title>loaded-hidden</title><p>hidden');
      String? title;
      final sw = Stopwatch()..start();
      while (title != 'loaded-hidden' && sw.elapsed.inSeconds < 10) {
        try {
          title =
              '${await _eval(h, 'document.title', const Duration(seconds: 2))}';
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      _check(
        'a load issued right after a hidden create finishes while hidden',
        title == 'loaded-hidden',
        title,
      );
      await h.dispose();
    });

    await _case('joining with weaker settings', (_, _, _) async {
      final strict = CefWebController(hostGroup: _group);
      Object? joined;
      try {
        joined = await strict.create(
          url: 'about:blank',
          width: 100,
          height: 100,
          allowedSchemes: {'https'},
        );
      } catch (e) {
        joined = e;
      }
      _check(
        'a session asking for an allowlist can\'t join an allow-everything host',
        joined is PlatformException && joined.code == 'host_config_mismatch',
        joined,
      );
      await strict.dispose();

      final reserved = CefWebController(profile: '~group~$_group');
      Object? result;
      try {
        result = await reserved.create(
          url: 'about:blank',
          width: 100,
          height: 100,
        );
      } catch (e) {
        result = e;
      }
      _check(
        'a profile name reserved for host keys is refused',
        result is PlatformException && result.code == 'bad_args',
        result,
      );
      await reserved.dispose();
    });

    if ('agent control on a disposed tile'.startsWith(_only)) {
      await _agentControlOnDisposedTile();
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
