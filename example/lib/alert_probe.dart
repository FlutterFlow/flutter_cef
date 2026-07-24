// Minimal alert-dismiss probe: does answering a JS alert unblock the renderer?
// Uses document.title (OnTitleChange, independent of the eval router) as the
// liveness signal. After alert() is answered, the page sets title='resumed'.
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cef/flutter_cef.dart';

const _html = r'''<!doctype html><meta charset="utf-8"><body>
<script>
  document.title = 'before';
  alert('hi');
  document.title = 'resumed';
</script>''';

void main() => runApp(const AlertProbe());

class AlertProbe extends StatefulWidget {
  const AlertProbe({super.key});
  @override
  State<AlertProbe> createState() => _S();
}

class _S extends State<AlertProbe> {
  final CefWebController _c = CefWebController();
  bool _loaded = false, _alertFired = false, _done = false;
  final List<String> _titles = [];

  @override
  void initState() {
    super.initState();
    _c.onJavaScriptAlertDialog = (r) async {
      _alertFired = true;
      print('ALERT_PROBE alert fired: ${r.message}');
    };
    _c.title.addListener(() {
      _titles.add(_c.title.value);
      print('ALERT_PROBE title=${_c.title.value}');
      if (_c.title.value == 'resumed' && !_done) {
        _done = true;
        _postAlert();
      }
    });
    _c.onPageStarted = (u) {
      if (!_loaded) {
        _loaded = true;
        _c.loadHtmlString(_html);
      }
    };
    Timer(const Duration(seconds: 12), () {
      if (!_done) {
        _done = true;
        _finish(false);
      }
    });
  }

  Future<void> _postAlert() async {
    // Does the Dart event loop / method channel keep working AFTER a dialog?
    print('POST_ALERT begin');
    await Future<void>.delayed(const Duration(milliseconds: 800));
    print('POST_ALERT delay-ok');
    try {
      final v = await _c
          .runJavaScriptReturningResult('6*7')
          .timeout(const Duration(seconds: 4));
      print('POST_ALERT eval=$v');
    } catch (e) {
      print('POST_ALERT eval-FAILED $e');
    }
    _finish(true);
  }

  void _finish(bool ok) {
    final out = {
      'pass': ok,
      'alert_fired': _alertFired,
      'titles': _titles,
    };
    try {
      File('/tmp/cef_alert_probe.json').writeAsStringSync(jsonEncode(out));
    } catch (_) {}
    print('ALERT_PROBE_RESULT ${jsonEncode(out)}');
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
      home: Scaffold(body: CefWebView(url: 'about:blank', controller: _c)));
}
