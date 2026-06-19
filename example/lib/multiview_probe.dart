// P2-step2 LIVE probe (cef-multiview PLAN Tests A + D + E) — flutter_cef side.
//
// Auto-running, headless-friendly self-test: mounts TWO CefWebViews on ONE shared
// named profile (an isolated 'p2probe' — deliberately NOT Campus's real 'campus-web'
// so it can't touch a running Campus's profile/cookie jar) with agentControl, then —
// with no user interaction — enables agent-control on BOTH and drives a real CDP
// isolation check over the two brokered relays. Results are written to
// /tmp/cef_multiview_probe.json and printed as a `CEF_PROBE_RESULT …` line.
//
// Run (cef_host must be built; CEF cached):
//   FLUTTER_CEF_HOST=<.../cef_host.app/Contents/MacOS/cef_host> \
//     flutter run -d macos -t lib/multiview_probe.dart        (or build + launch the binary)
//
// What it proves live (the unit boundary is already covered by CdpRelayFilterTests):
//   A. two views on one named profile both create on ONE shared cef_host (verify
//      `pgrep -f cef_host` == one host for the profile while this runs).
//   D. enableAgentControl on both yields TWO grants with DISTINCT ports + tokens.
//   E. each relay's Target.getTargets returns ONLY its own target (A can't see B),
//      and presenting tile A's token to tile B's port is rejected.
//   F. concurrency + lifecycle: enabling both CONCURRENTLY brings up two isolated
//      relays (the per-browserId dict, not the P1 scalar); disabling A kills only
//      A's grant (its endpoint goes dead) while B keeps driving; and A can be
//      RE-ENABLED after disable — a fresh port+token, the torn-down grant stays dead.
//
// Not covered here — reader-stall isolation (PLAN Test G, the SO_SNDTIMEO reaping of
// a wedged client + no sibling starvation): a faithful repro needs a real CDP driver
// that completes the flatten auto-attach handshake and drives pipe-routed commands
// (this probe's Target.getTargets is synthesized client-side and bypasses the shared
// reader, and stalling the client precludes reading the sessionId needed to generate
// pipe traffic). That belongs on the canvas side, driven by agent-browser over two
// real tiles.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cef/flutter_cef.dart';

const _profile = 'p2probe'; // isolated; NOT Campus's real 'campus-web' profile
const _resultPath = '/tmp/cef_multiview_probe.json';

void main() => runApp(const ProbeApp());

class ProbeApp extends StatefulWidget {
  const ProbeApp({super.key});
  @override
  State<ProbeApp> createState() => _ProbeAppState();
}

class _ProbeAppState extends State<ProbeApp> {
  final CefWebController _a = CefWebController(profile: _profile);
  final CefWebController _b = CefWebController(profile: _profile);
  final Map<String, bool> _checks = {};
  String _status = 'starting…';

  void _check(String name, bool cond) {
    _checks[name] = cond;
    // ignore: avoid_print
    print('CEF_PROBE_CHECK ${cond ? "PASS" : "FAIL"}  $name');
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  /// enableAgentControl needs the shared host up + the browser's CDP targetId
  /// resolved (a round-trip). Retry until a grant comes back or we give up.
  Future<({String wsUrl, String token, int port})?> _enable(
    CefWebController c, {
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final g = await c.enableAgentControl();
        if (g != null) return g;
      } catch (_) {/* host still spawning — retry */}
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return null;
  }

  /// One CDP request/response over a fresh WebSocket to a relay grant. Throws if
  /// the upgrade is rejected (e.g. a bad/foreign token → 401) or on timeout.
  Future<Map<String, dynamic>> _cdp(
    String wsUrl, {
    required int id,
    required String method,
    Map<String, dynamic>? params,
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final ws = await WebSocket.connect(wsUrl).timeout(timeout);
    final done = Completer<Map<String, dynamic>>();
    final sub = ws.listen((data) {
      try {
        final m = jsonDecode(data as String) as Map<String, dynamic>;
        if (m['id'] == id && !done.isCompleted) done.complete(m);
      } catch (_) {/* ignore non-JSON / unrelated frames */}
    }, onError: (Object e) {
      if (!done.isCompleted) done.completeError(e);
    }, onDone: () {
      if (!done.isCompleted) done.completeError(StateError('socket closed'));
    });
    ws.add(jsonEncode({'id': id, 'method': method, 'params': ?params}));
    try {
      return await done.future.timeout(timeout);
    } finally {
      await sub.cancel();
      await ws.close();
    }
  }

  /// The targetIds a relay's synthesized Target.getTargets exposes to its client.
  Future<List<String>> _targets(String wsUrl) async {
    final r = await _cdp(wsUrl, id: 1, method: 'Target.getTargets');
    final infos = (r['result']?['targetInfos'] as List?) ?? const [];
    return infos
        .map((e) => (e as Map)['targetId'] as String?)
        .whereType<String>()
        .toList();
  }

  Future<void> _run() async {
    final out = <String, dynamic>{};
    try {
      setState(() => _status = 'enabling agent-control on both views CONCURRENTLY…');
      // F — concurrent enable: fire BOTH at once (not sequentially). The P1 scalar
      // relay/relayBrowserId would have lost this race; the per-browserId dict +
      // cdpHandlerLock must bring up two isolated relays under simultaneous enable.
      final grants = await Future.wait([_enable(_a), _enable(_b)]);
      final gA = grants[0], gB = grants[1];
      out['grantA'] = gA == null ? null : {'port': gA.port, 'token8': gA.token.substring(0, 8)};
      out['grantB'] = gB == null ? null : {'port': gB.port, 'token8': gB.token.substring(0, 8)};
      _check('F: concurrent enable — both grants obtained', gA != null && gB != null);

      if (gA != null && gB != null) {
        // D — two independent grants.
        _check('D: distinct relay ports', gA.port != gB.port);
        _check('D: distinct relay tokens', gA.token != gB.token);

        // E — each relay sees only its own page target.
        setState(() => _status = 'probing CDP isolation…');
        final ta = await _targets(gA.wsUrl);
        final tb = await _targets(gB.wsUrl);
        out['targetsA'] = ta;
        out['targetsB'] = tb;
        _check('E: relay A exposes exactly one target', ta.length == 1);
        _check('E: relay B exposes exactly one target', tb.length == 1);
        _check('E: A and B targets differ (no shared view)',
            ta.isNotEmpty && tb.isNotEmpty && ta.first != tb.first);

        // E — tile A's token must not open tile B's port (token is relay-bound).
        bool crossRejected = false;
        try {
          await _targets('ws://127.0.0.1:${gB.port}/devtools/browser?token=${gA.token}');
        } catch (_) {
          crossRejected = true;
        }
        _check("E: tile A's token rejected on tile B's port", crossRejected);

        // F — teardown invalidation + per-tile independence: disabling A frees ONLY
        // A's relay (listener + token); A's old endpoint must go dead while B stays
        // fully drivable on its own untouched relay.
        setState(() => _status = 'teardown invalidation…');
        await _a.disableAgentControl();
        await Future<void>.delayed(const Duration(milliseconds: 400));
        bool staleDead = false;
        try {
          await _targets(gA.wsUrl);
        } catch (_) {
          staleDead = true; // listener gone / token invalid → connect fails
        }
        _check("F: A's grant is dead after disableAgentControl(A)", staleDead);
        bool bUnaffected = false;
        try {
          final t = await _targets(gB.wsUrl);
          bUnaffected = t.length == 1 && t.first == tb.first;
        } catch (_) {}
        _check('F: sibling B unaffected by A teardown (still drives its own target)',
            bUnaffected);

        // F — re-enable after disable (a tile gets driven again later): yields a
        // FRESH, independent grant (new port+token) and the torn-down one stays dead.
        // Needs cef_host's per-probe monotonic DevTools id (a fixed id dropped the 2nd
        // resolve on the same browser) + resolveTargetId's epoch-guarded timer.
        setState(() => _status = 're-enable after teardown…');
        final gA2 = await _enable(_a);
        out['grantA2'] =
            gA2 == null ? null : {'port': gA2.port, 'token8': gA2.token.substring(0, 8)};
        _check('F: A re-enables after disable (fresh grant)', gA2 != null);
        if (gA2 != null) {
          _check('F: re-enabled grant differs from the torn-down one',
              gA2.port != gA.port || gA2.token != gA.token);
          final ta2 = await _targets(gA2.wsUrl);
          _check('F: re-enabled relay drives A again (one own target)',
              ta2.length == 1 && ta2.first == ta.first);
          bool oldStillDead = false;
          try {
            await _targets(gA.wsUrl);
          } catch (_) {
            oldStillDead = true;
          }
          _check('F: the torn-down grant stays dead after re-enable', oldStillDead);
        }
      }
    } catch (e, st) {
      out['fatal'] = '$e';
      out['stack'] = '$st';
    }

    out['checks'] = _checks;
    final pass = _checks.isNotEmpty && _checks.values.every((v) => v);
    out['pass'] = pass;
    try {
      File(_resultPath).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(out));
    } catch (_) {}
    // ignore: avoid_print
    print('CEF_PROBE_RESULT ${jsonEncode(out)}');
    if (mounted) {
      setState(() => _status = pass
          ? 'ALL PASS (${_checks.length} checks) — results at $_resultPath'
          : 'FAIL — see $_resultPath');
    }
  }

  @override
  void dispose() {
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text('P2-step2 probe — $_status',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: CefWebView(
                        key: const ValueKey('A'),
                        url: 'https://example.com',
                        controller: _a,
                        profile: _profile,
                        agentControl: true,
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: CefWebView(
                        key: const ValueKey('B'),
                        url: 'https://flutter.dev',
                        controller: _b,
                        profile: _profile,
                        agentControl: true,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
