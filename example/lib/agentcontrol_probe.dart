// Agent-control (P9) end-to-end probe — drives the Windows token-gated loopback
// CDP relay through a real CDP WebSocket client, entirely in-process (no
// Playwright / node / python needed: dart:io's WebSocket does the RFC-6455
// handshake and forwards a custom Authorization header).
//
// It:
//   1. creates a CefWebController with agentControl:true, loads a page,
//   2. calls enableAgentControl() -> {wsUrl, token, port} and writes it to
//      C:\tmp\cef_agentcontrol.json,
//   3. GATE 2a (401): connects a ws client WITHOUT the token -> asserts 401,
//   4. GATE 2b (evaluate=2): connects WITH `Authorization: Bearer <token>`,
//      drives Target.getTargets -> attachToTarget(flatten) -> Runtime.evaluate
//      ("1+1") and asserts the result is 2,
//   5. GATE 3 (teardown): disableAgentControl() then asserts a fresh connect
//      to the port fails (the relay is gone).
//
// Run (cef_host must be built + staged; CEF cached):
//   cd example
//   <flutter> run -d windows -t lib/agentcontrol_probe.dart
// Result: `CEF_AGENTCONTROL_RESULT …` on stdout + C:\tmp\cef_agentcontrol.json.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cef/flutter_cef.dart';

const _resultPath = r'C:\tmp\cef_agentcontrol.json';

void main() => runApp(const ProbeApp());

class ProbeApp extends StatefulWidget {
  const ProbeApp({super.key});
  @override
  State<ProbeApp> createState() => _ProbeAppState();
}

class _ProbeAppState extends State<ProbeApp> {
  final CefWebController _c = CefWebController();
  bool _started = false;
  String _status = 'starting…';
  final List<String> _log = [];

  void _note(String s) {
    // ignore: avoid_print
    print('CEF_AGENTCONTROL $s');
    _log.add(s);
    if (mounted) setState(() => _status = s);
  }

  @override
  void initState() {
    super.initState();
    _c.onPageStarted = (url) {
      _note('onPageStarted url=$url');
      if (!_started) {
        _started = true;
        // Give the page target a beat to commit, then drive the gates.
        Future<void>.delayed(const Duration(seconds: 2), _run);
      }
    };
    _c.onConsoleMessage = (m) => _note('console: ${m.message}');
  }

  Future<void> _run() async {
    final out = <String, dynamic>{
      'enable_ok': false,
      'gate_401': false,
      'gate_evaluate_2': false,
      'gate_teardown': false,
      'log': _log,
    };
    try {
      // ---- 1. enableAgentControl -> {wsUrl, token, port} ----
      final ep = await _c.enableAgentControl();
      if (ep == null) {
        _note('FAIL enableAgentControl returned null');
        _write(out);
        return;
      }
      out['enable_ok'] = true;
      out['wsUrl'] = ep.wsUrl;
      out['token'] = ep.token;
      out['port'] = ep.port;
      _note('enableAgentControl OK port=${ep.port} wsUrl=${ep.wsUrl}');

      final base = 'ws://127.0.0.1:${ep.port}/devtools/browser';

      // ---- GATE 2a: upgrade WITHOUT a token -> HTTP 401 ----
      // A raw upgrade request surfaces the exact status line (dart:io's
      // WebSocketException hides the code). Cross-check that the SAME request
      // WITH the token upgrades (101), proving the token is what gates it.
      final statusNoToken = await _rawUpgradeStatusLine(ep.port);
      final statusWithToken =
          await _rawUpgradeStatusLine(ep.port, token: ep.token);
      final is401 = statusNoToken.contains('401');
      out['gate_401'] = is401 && statusWithToken.contains('101');
      out['gate_401_no_token_status'] = statusNoToken;
      out['gate_401_with_token_status'] = statusWithToken;
      _note('GATE 401 no-token   -> "$statusNoToken"');
      _note('GATE 401 with-token -> "$statusWithToken"');
      _note('GATE 401 ${out['gate_401'] == true ? 'PASS' : 'FAIL'}');

      // ---- GATE 2b: connect WITH the bearer token, evaluate 1+1 == 2 ----
      // The with-token raw probe above briefly held the single-client slot;
      // give the relay a beat to release it so this real upgrade isn't 503'd.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final ws = await WebSocket.connect(
        base,
        headers: {'Authorization': 'Bearer ${ep.token}'},
      );
      _note('connected with bearer token');
      final cdp = _CdpConn(ws);

      final targets = await cdp.send('Target.getTargets');
      final infos = (targets['result']?['targetInfos'] as List?) ?? const [];
      _note('Target.getTargets -> ${infos.length} target(s)');
      final page = infos.cast<Map<String, dynamic>>().firstWhere(
            (t) => t['type'] == 'page',
            orElse: () => <String, dynamic>{},
          );
      final targetId = page['targetId'] as String?;
      if (targetId == null) {
        _note('FAIL — no page target in getTargets');
        await ws.close();
        _write(out);
        return;
      }
      _note('page targetId=$targetId');

      final attach = await cdp.send('Target.attachToTarget',
          params: {'targetId': targetId, 'flatten': true});
      final sessionId = attach['result']?['sessionId'] as String?;
      if (sessionId == null) {
        _note('FAIL — no sessionId from attachToTarget');
        await ws.close();
        _write(out);
        return;
      }
      _note('attached sessionId=$sessionId');

      final eval = await cdp.send('Runtime.evaluate',
          params: {'expression': '1+1'}, sessionId: sessionId);
      final value = eval['result']?['result']?['value'];
      final pass = value == 2;
      out['gate_evaluate_2'] = pass;
      out['evaluate_value'] = value;
      _note('Runtime.evaluate("1+1") -> value=$value  ${pass ? 'PASS' : 'FAIL'}');
      await ws.close();

      // ---- GATE 3: disableAgentControl tears down the port ----
      await _c.disableAgentControl();
      _note('disableAgentControl() called');
      // The port bounce can lag a hair; poll briefly for it to be gone.
      bool gone = false;
      for (var i = 0; i < 20 && !gone; i++) {
        try {
          final ws2 = await WebSocket.connect(
            base,
            headers: {'Authorization': 'Bearer ${ep.token}'},
          ).timeout(const Duration(seconds: 1));
          await ws2.close();
          await Future<void>.delayed(const Duration(milliseconds: 200));
        } catch (_) {
          gone = true;
        }
      }
      out['gate_teardown'] = gone;
      _note('GATE teardown ${gone ? 'PASS' : 'FAIL'} — '
          'post-disable connect ${gone ? 'refused' : 'still succeeded'}');
    } catch (e, st) {
      out['error'] = '$e';
      _note('EXCEPTION $e\n$st');
    }
    _write(out);
  }

  /// Send a raw RFC-6455 upgrade request (optionally with a bearer token) and
  /// return the HTTP status line the relay replies with — "HTTP/1.1 401
  /// Unauthorized" without a valid token, "HTTP/1.1 101 Switching Protocols"
  /// with one. Uses a fixed valid 16-byte Sec-WebSocket-Key.
  Future<String> _rawUpgradeStatusLine(int port, {String? token}) async {
    Socket? sock;
    try {
      sock = await Socket.connect('127.0.0.1', port,
          timeout: const Duration(seconds: 3));
      final req = StringBuffer()
        ..write('GET /devtools/browser HTTP/1.1\r\n')
        ..write('Host: 127.0.0.1:$port\r\n')
        ..write('Upgrade: websocket\r\n')
        ..write('Connection: Upgrade\r\n')
        ..write('Sec-WebSocket-Version: 13\r\n')
        ..write('Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n');
      if (token != null) req.write('Authorization: Bearer $token\r\n');
      req.write('\r\n');
      sock.add(utf8.encode(req.toString()));
      final bytes = <int>[];
      await for (final chunk in sock.timeout(const Duration(seconds: 3))) {
        bytes.addAll(chunk);
        if (String.fromCharCodes(bytes).contains('\r\n')) break;
      }
      final text = String.fromCharCodes(bytes);
      return text.split('\r\n').first.trim();
    } catch (e) {
      return 'ERROR: $e';
    } finally {
      sock?.destroy();
    }
  }

  void _write(Map<String, dynamic> out) {
    final pass = out['enable_ok'] == true &&
        out['gate_401'] == true &&
        out['gate_evaluate_2'] == true &&
        out['gate_teardown'] == true;
    out['PASS'] = pass;
    try {
      Directory(r'C:\tmp').createSync(recursive: true);
      File(_resultPath).writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(out));
    } catch (_) {}
    // ignore: avoid_print
    print('CEF_AGENTCONTROL_RESULT ${jsonEncode({
          'PASS': pass,
          'enable_ok': out['enable_ok'],
          'gate_401': out['gate_401'],
          'gate_evaluate_2': out['gate_evaluate_2'],
          'gate_teardown': out['gate_teardown'],
          'evaluate_value': out['evaluate_value'],
        })}');
    if (mounted) {
      setState(() => _status = pass ? 'ALL GATES PASS' : 'SOME GATES FAILED');
    }
  }

  @override
  void dispose() {
    _c.dispose();
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
                child: Text('agent-control probe — $_status',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              Expanded(
                child: CefWebView(
                  url: 'about:blank',
                  controller: _c,
                  agentControl: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Minimal CDP request/response multiplexer over one WebSocket: sends a command
/// with an auto-incremented id and completes on the response with a matching id
/// (events, which carry no id, are ignored).
class _CdpConn {
  _CdpConn(this._ws) {
    _ws.listen((data) {
      try {
        final msg = jsonDecode(data as String) as Map<String, dynamic>;
        final id = msg['id'];
        if (id is int) {
          _pending.remove(id)?.complete(msg);
        }
      } catch (_) {}
    }, onError: (_) {}, onDone: () {});
  }

  final WebSocket _ws;
  int _nextId = 0;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};

  Future<Map<String, dynamic>> send(String method,
      {Map<String, dynamic>? params, String? sessionId}) {
    final id = ++_nextId;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    final m = <String, dynamic>{'id': id, 'method': method};
    if (params != null) m['params'] = params;
    if (sessionId != null) m['sessionId'] = sessionId;
    _ws.add(jsonEncode(m));
    return c.future.timeout(const Duration(seconds: 10), onTimeout: () {
      _pending.remove(id);
      throw TimeoutException('CDP $method timed out');
    });
  }
}
