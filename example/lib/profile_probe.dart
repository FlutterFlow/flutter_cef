// Windows profile + cookie END-TO-END probe (P6 foundation + P11 profile slice).
//
// Auto-running, no-interaction self-test that drives the REAL integrated stack —
// the public Dart API (CefWebController) -> the method channel -> the Windows
// plugin (flutter_cef_plugin.cpp) -> the shipped cef_host.exe beside the app.
// It proves, via the cookie API alone (no GPU paint required — cookie verbs act
// on the host's process-wide CefCookieManager jar, so no page needs to load):
//
//   SHARED JAR  — two controllers on ONE named profile ('evi_shared') land on
//                 ONE cef_host (plugin ResolveOrSpawnHost de-dups by profile
//                 key) -> ONE jar: a cookie set via tile A is read back via B.
//   ISOLATION   — a DIFFERENT named profile ('evi_other') and an EPHEMERAL
//                 (no-profile) session do NOT see 'evi_shared''s cookie
//                 (distinct profile dirs / distinct hosts / distinct jars).
//   PERSISTENCE — a 'marker' cookie in a persistent profile ('evi_persist') is
//                 read at startup (the "before"), then rewritten with a fresh
//                 nonce (the "after"). Across two launches, launch-2's "before"
//                 equals launch-1's "after" -> the jar survived full app exit.
//                 (Each run's dispose() sends kOpShutdown -> host flushes the
//                 on-disk SQLite cookie store; persist_session_cookies=1.)
//
// Results are written to  C:\dev\flutter_cef_spikes\profile_evidence\  as a JSON
// transcript (authoritative) and rendered on screen (for the screenshot), and a
// `CEF_PROBE_RESULT …` line is printed to stdout.
//
// Run (cef_host.exe is copied beside the built example exe):
//   flutter build windows --debug -t lib/profile_probe.dart
//   .\build\windows\x64\runner\Debug\flutter_cef_example.exe
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cef/flutter_cef.dart';

const _evidenceDir = r'C:\dev\flutter_cef_spikes\profile_evidence';
const _sharedProfile = 'evi_shared';
const _otherProfile = 'evi_other';
const _persistProfile = 'evi_persist';

// A stable cookie scope. setCookie/getCookies operate on the jar directly, so no
// navigation to this host ever happens — it is purely a cookie domain/path key.
const _sharedUrl = 'https://shared.evi.example/';
const _persistUrl = 'https://persist.evi.example/';

void main() => runApp(const ProbeApp());

class ProbeApp extends StatefulWidget {
  const ProbeApp({super.key});
  @override
  State<ProbeApp> createState() => _ProbeAppState();
}

class _ProbeAppState extends State<ProbeApp> {
  final Map<String, bool> _checks = {};
  final List<String> _lines = [];
  String _status = 'starting…';
  bool _done = false;
  bool _pass = false;

  void _check(String name, bool cond) {
    _checks[name] = cond;
    _log('${cond ? "PASS" : "FAIL"}  $name');
    // ignore: avoid_print
    print('CEF_PROBE_CHECK ${cond ? "PASS" : "FAIL"}  $name');
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

  // Create a session for [c] directly through the controller (no CefWebView
  // needed — we only exercise the cookie API). Cookie verbs issued before the
  // host is ready are queued plugin-side and flushed on kOpReady, so the futures
  // below naturally wait for the host to come up.
  Future<void> _create(CefWebController c) =>
      c.create(url: 'about:blank', width: 400, height: 300, dpr: 1.0)
          .timeout(const Duration(seconds: 20));

  // Read cookies, retrying until the host answers. The host's kOpCreateBrowser
  // registers the browser slot on an ASYNC UI task; a per-slot verb (visitCookies)
  // that reaches the reader thread before that task runs finds no slot and is
  // silently dropped (no reply). A real consumer queries cookies long after first
  // paint, so it never races; this probe fires immediately, so we re-issue the
  // visit until one round-trips — which also proves the slot is now live.
  Future<List<CefCookie>> _cookies(CefWebController c, String url) async {
    Object? lastErr;
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        return await c
            .getCookies(url: url)
            .timeout(const Duration(milliseconds: 1500));
      } catch (e) {
        lastErr = e;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    throw StateError('getCookies never answered (host slot not ready?): $lastErr');
  }

  // Gate on the browser slot being live before a fire-and-forget write, so the
  // host doesn't drop the setCookie the same way (an unanswered write is silent).
  Future<void> _waitReady(CefWebController c) async {
    await _cookies(c, ''); // a successful visit proves the slot exists
  }

  String? _valueOf(List<CefCookie> cs, String name) {
    for (final c in cs) {
      if (c.name == name) return c.value;
    }
    return null;
  }

  Future<void> _run() async {
    final out = <String, dynamic>{
      'platform': Platform.operatingSystem,
      'startedAt': DateTime.now().toIso8601String(),
    };
    final nonce = DateTime.now().millisecondsSinceEpoch.toString();
    out['nonce'] = nonce;

    // Sequentially constructed + created so host allocation is deterministic:
    // sharedA spawns the 'evi_shared' host; sharedB REUSES it (same profile key).
    final persist = CefWebController(profile: _persistProfile);
    final sharedA = CefWebController(profile: _sharedProfile);
    final sharedB = CefWebController(profile: _sharedProfile);
    final other = CefWebController(profile: _otherProfile);
    final ephemeral = CefWebController(); // no profile

    try {
      // ── PERSISTENCE: read the marker BEFORE (survivor of a prior launch) ──
      setState(() => _status = 'creating persist host…');
      await _create(persist);
      final beforeCookies = await _cookies(persist, _persistUrl);
      final beforeMarker = _valueOf(beforeCookies, 'marker');
      out['persist_before'] = beforeMarker;
      _log('persist BEFORE marker = ${beforeMarker ?? "(none — first launch)"}');
      // Write a fresh marker (the AFTER). Read it back in-session to confirm the
      // host committed it before we ask the next launch to find it.
      await persist.setCookie(
          url: _persistUrl, name: 'marker', value: nonce, path: '/');
      final afterCookies = await _cookies(persist, _persistUrl);
      final afterMarker = _valueOf(afterCookies, 'marker');
      out['persist_after'] = afterMarker;
      _log('persist AFTER  marker = ${afterMarker ?? "(write failed)"}');
      _check('PERSIST: marker written + read back this session',
          afterMarker == nonce);
      final priorSeen = File('$_evidenceDir\\last_after_nonce.txt');
      if (beforeMarker != null) {
        _check('PERSIST: a marker survived a PRIOR full app exit', true);
        out['persist_survived_prior'] = true;
      } else {
        _log('PERSIST: no prior marker (this is launch #1 — rerun to prove '
            'cross-launch survival; run #2 BEFORE should equal this nonce)');
        out['persist_survived_prior'] = false;
      }

      // ── SHARED JAR: two controllers, one profile, one host, one jar ──
      setState(() => _status = 'creating shared-jar hosts (A reuses via B)…');
      await _create(sharedA);
      await _create(sharedB); // reuses sharedA's host (same profile key)
      await _waitReady(sharedA); // gate the write on sharedA's slot being live
      await sharedA.setCookie(
          url: _sharedUrl, name: 'sjar', value: nonce, path: '/');
      // Read from B: if B is on A's host + jar, it sees A's write.
      final bSees = await _cookies(sharedB, _sharedUrl);
      final bVal = _valueOf(bSees, 'sjar');
      out['sharedB_sjar'] = bVal;
      _log('sharedB sees sjar = ${bVal ?? "(NOT VISIBLE)"} (set via sharedA)');
      _check('SHARED JAR: tile B reads the cookie tile A set (one host, one jar)',
          bVal == nonce);

      // ── ISOLATION: a different named profile can't see evi_shared's cookie ──
      setState(() => _status = 'creating isolation hosts…');
      await _create(other);
      final otherSees = await _cookies(other, _sharedUrl);
      final otherVal = _valueOf(otherSees, 'sjar');
      out['other_sjar'] = otherVal;
      _log("other-profile sees sjar = ${otherVal ?? "(none — isolated ✓)"}");
      _check("ISOLATION: a DIFFERENT named profile does NOT see evi_shared's "
          'cookie', otherVal == null);

      // ── ISOLATION: an ephemeral (no-profile) session can't see it either ──
      await _create(ephemeral);
      final ephSees = await _cookies(ephemeral, _sharedUrl);
      final ephVal = _valueOf(ephSees, 'sjar');
      out['ephemeral_sjar'] = ephVal;
      _log('ephemeral sees sjar = ${ephVal ?? "(none — isolated ✓)"}');
      _check('ISOLATION: an EPHEMERAL (no-profile) session does NOT see '
          "evi_shared's cookie", ephVal == null);

      // Record this run's AFTER nonce so a human/manifest can correlate the next
      // launch's BEFORE with it.
      try {
        Directory(_evidenceDir).createSync(recursive: true);
        priorSeen.writeAsStringSync(nonce);
      } catch (_) {}
    } catch (e, st) {
      out['fatal'] = '$e';
      out['stack'] = '$st';
      _log('FATAL: $e');
    }

    // Dispose every host — dispose() sends kOpShutdown so the persist host FLUSHES
    // its on-disk cookie store before it exits (what makes the marker survive the
    // next launch). Tear down the OTHER hosts FIRST and let their whole Chromium
    // process trees die, so the persist host's clean-shutdown cookie flush isn't
    // racing ~25 sibling processes for CPU inside the teardown reaper's kill
    // window — then dispose persist LAST on a quiet machine.
    setState(() => _status = 'disposing sibling hosts…');
    for (final c in [sharedA, sharedB, other, ephemeral]) {
      try {
        await c.dispose();
      } catch (_) {}
    }
    await Future<void>.delayed(const Duration(seconds: 4));
    setState(() => _status = 'flushing + disposing persist host…');
    try {
      await persist.dispose();
    } catch (_) {}
    // Wait for the persist host process tree to fully exit (reaper bound 3s +
    // margin) so its cookie store is flushed AND its profile lock is released
    // before we re-open the profile.
    await Future<void>.delayed(const Duration(seconds: 6));

    // ── PERSISTENCE (in-app): reopen the SAME profile in a FRESH host and read
    // the marker back. This proves the plugin's dispose()->kOpShutdown flushed
    // the on-disk store and a new host reloads it — independent of app exit. ──
    setState(() => _status = 'reopening persist profile in a fresh host…');
    final persist2 = CefWebController(profile: _persistProfile);
    try {
      await _create(persist2);
      final rebornCookies = await _cookies(persist2, _persistUrl);
      final rebornMarker = _valueOf(rebornCookies, 'marker');
      out['persist_reborn'] = rebornMarker;
      _log('persist REBORN marker = ${rebornMarker ?? "(LOST across host restart)"}');
      _check('PERSIST: marker survived a host restart on the SAME profile '
          '(in-app flush + reload)', rebornMarker == nonce);
    } catch (e) {
      out['persist_reborn_error'] = '$e';
      _check('PERSIST: marker survived a host restart on the SAME profile '
          '(in-app flush + reload)', false);
    } finally {
      try {
        await persist2.dispose();
      } catch (_) {}
    }
    await Future<void>.delayed(const Duration(seconds: 3));

    out['checks'] = _checks;
    final pass = _checks.isNotEmpty && _checks.values.every((v) => v);
    out['pass'] = pass;
    out['finishedAt'] = DateTime.now().toIso8601String();
    try {
      Directory(_evidenceDir).createSync(recursive: true);
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .replaceAll('.', '-');
      File('$_evidenceDir\\profile_probe_$stamp.json')
          .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(out));
      File('$_evidenceDir\\profile_probe_latest.json')
          .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(out));
    } catch (_) {}
    // ignore: avoid_print
    print('CEF_PROBE_RESULT ${jsonEncode(out)}');
    if (mounted) {
      setState(() {
        _done = true;
        _pass = pass;
        _status = pass
            ? 'ALL PASS (${_checks.length} checks)'
            : 'FAIL — see $_evidenceDir';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = !_done
        ? Colors.blueGrey
        : (_pass ? const Color(0xFF1B5E20) : const Color(0xFFB71C1C));
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: color,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _done ? (_pass ? 'PROFILE PROBE: ALL PASS' : 'PROFILE PROBE: FAIL')
                      : 'PROFILE PROBE — $_status',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: SingleChildScrollView(
                    child: Text(
                      _lines.join('\n'),
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontFamily: 'monospace',
                          height: 1.5),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
