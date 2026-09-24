// An agent can't reach a sibling tile through its own page session — END-TO-END
// probe (macOS).
//
// Auto-running, no-interaction regression test for the agent-control relay's
// per-tile boundary. Two tiles, A and B, share one cef_host. An agent is given
// control of A and tries to reach B with Target.* commands sent on A's page
// session, which the relay used to forward without checking:
//   * Target.getTargets on A's session must not list B;
//   * Target.attachToTarget(B) on A's session must fail, and nothing must let the
//     agent evaluate script in B.
// A's own page must stay fully drivable (Runtime.evaluate on A's session).
//
// A `CEF_PROBE_RESULT PASS|FAIL` line is printed to stdout at the end.
//
// Run:  FLUTTER_CEF_HOST=<.../cef_host.app/Contents/MacOS/cef_host> \
//         flutter run -d macos -t lib/relay_isolation_probe.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cef/flutter_cef.dart';

String _page(String secret) =>
    '<!doctype html><body><h1>$secret</h1>'
    '<script>window.secret = "$secret";</script>';

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

  Future<CefWebController> _open(String secret) async {
    final c = CefWebController(hostGroup: 'relay_isolation');
    await c.create(
      url: 'about:blank',
      html: _page(secret),
      width: 320,
      height: 240,
      agentControl: true,
    );
    final sw = Stopwatch()..start();
    while (((await c.sessionStats())?.presentCount ?? 0) <= 0 &&
        sw.elapsed.inSeconds < 15) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return c;
  }

  /// Connects to [c]'s relay and attaches to its page the way Playwright does.
  Future<(_CdpConn, String targetId, String sessionId)> _drive(
    CefWebController c,
  ) async {
    final ep = await c.enableAgentControl();
    if (ep == null) throw StateError('enableAgentControl returned null');
    final ws = await WebSocket.connect(
      ep.wsUrl,
      headers: {'Authorization': 'Bearer ${ep.token}'},
    );
    final cdp = _CdpConn(ws);
    final attached = cdp.nextEvent('Target.attachedToTarget');
    await cdp.send(
      'Target.setAutoAttach',
      params: {
        'autoAttach': true,
        'waitForDebuggerOnStart': false,
        'flatten': true,
      },
    );
    final params = (await attached)['params'] as Map<String, dynamic>;
    final info = params['targetInfo'] as Map<String, dynamic>;
    return (cdp, info['targetId'] as String, params['sessionId'] as String);
  }

  Future<void> _run() async {
    _CdpConn? cdpA, cdpB;
    try {
      final a = await _open('A');
      final b = await _open('B-SECRET');
      final String tidB;
      final String sessA;
      (cdpA, _, sessA) = await _drive(a);
      (cdpB, tidB, _) = await _drive(b);

      final own = await cdpA.send(
        'Runtime.evaluate',
        params: {'expression': 'window.secret', 'returnByValue': true},
        sessionId: sessA,
      );
      _check(
        "the agent drives its own tile's page",
        own['result']?['result']?['value'] == 'A',
        own,
      );

      final listed = await cdpA.send('Target.getTargets', sessionId: sessA);
      final infos = (listed['result']?['targetInfos'] as List?) ?? const [];
      _check(
        "Target.getTargets on A's session doesn't list B",
        !infos.any((t) => (t as Map)['targetId'] == tidB),
        listed,
      );

      final attach = await cdpA.send(
        'Target.attachToTarget',
        params: {'targetId': tidB, 'flatten': true},
        sessionId: sessA,
      );
      final sessB = attach['result']?['sessionId'] as String?;
      _check(
        "Target.attachToTarget(B) on A's session fails",
        sessB == null,
        attach,
      );
      if (sessB != null) {
        final stolen = await cdpA.send(
          'Runtime.evaluate',
          params: {'expression': 'window.secret', 'returnByValue': true},
          sessionId: sessB,
        );
        _check(
          "the agent can't evaluate script in B",
          stolen['result']?['result']?['value'] != 'B-SECRET',
          stolen,
        );
      }

      final discover = await cdpA.send(
        'Target.setDiscoverTargets',
        params: {'discover': true},
        sessionId: sessA,
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      _check(
        "no event on A's connection names B",
        !cdpA.events.any((e) => jsonEncode(e).contains(tidB)),
        [discover, cdpA.events.where((e) => jsonEncode(e).contains(tidB))],
      );
      await a.dispose();
      await b.dispose();
    } catch (e, st) {
      _check('probe ran to completion', false, '$e\n$st');
    }
    await cdpA?.close();
    await cdpB?.close();
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

/// A CDP client over one WebSocket: commands complete on the reply with their
/// id; events are kept in [events].
class _CdpConn {
  _CdpConn(this._ws) {
    _ws.listen((data) {
      final msg = jsonDecode(data as String) as Map<String, dynamic>;
      final id = msg['id'];
      if (id is int) {
        _pending.remove(id)?.complete(msg);
        return;
      }
      events.add(msg);
      for (final w in List.of(_waiters)) {
        if (w.$1 == msg['method']) {
          _waiters.remove(w);
          w.$2.complete(msg);
        }
      }
    });
  }

  final WebSocket _ws;
  int _nextId = 0;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  final List<(String, Completer<Map<String, dynamic>>)> _waiters = [];
  final List<Map<String, dynamic>> events = [];

  Future<Map<String, dynamic>> nextEvent(String method) {
    final c = Completer<Map<String, dynamic>>();
    _waiters.add((method, c));
    return c.future.timeout(const Duration(seconds: 10));
  }

  Future<Map<String, dynamic>> send(
    String method, {
    Map<String, dynamic>? params,
    String? sessionId,
  }) {
    final id = ++_nextId;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    _ws.add(
      jsonEncode({
        'id': id,
        'method': method,
        'params': ?params,
        'sessionId': ?sessionId,
      }),
    );
    return c.future.timeout(const Duration(seconds: 10));
  }

  Future<void> close() => _ws.close();
}
