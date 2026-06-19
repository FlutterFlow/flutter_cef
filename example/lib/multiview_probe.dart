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
//      `pgrep -f cef_host` == one host for campus-web while this runs).
//   D. enableAgentControl on both yields TWO grants with DISTINCT ports + tokens.
//   E. each relay's Target.getTargets returns ONLY its own target (A can't see B),
//      and presenting tile A's token to tile B's port is rejected.
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
    ws.add(jsonEncode({'id': id, 'method': method, if (params != null) 'params': params}));
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
      setState(() => _status = 'enabling agent-control on both views…');
      final gA = await _enable(_a);
      final gB = await _enable(_b);
      out['grantA'] = gA == null ? null : {'port': gA.port, 'token8': gA.token.substring(0, 8)};
      out['grantB'] = gB == null ? null : {'port': gB.port, 'token8': gB.token.substring(0, 8)};
      _check('A: both grants obtained', gA != null && gB != null);

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
