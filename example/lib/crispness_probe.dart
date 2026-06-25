// Crispness probe — verifies renderScale keeps an OSR webview sharp when the view
// is visually SCALED by an ancestor transform (the infinite-canvas zoom case).
//
// A single CefWebView is wrapped in a Transform.scale to mimic a canvas zoom: the
// widget's logical size is unchanged, the transform just magnifies it. Without
// renderScale the OSR buffer stays at 1x-zoom resolution and the transform upscales
// it (blurry); with renderScale = screenDpr * zoom the page re-renders at the
// on-screen pixel density (crisp).
//
// Controls: + / -  zoom in/out;  R  toggle renderScale (crisp) vs none (blurry).
//
// Run:
//   FLUTTER_CEF_HOST=<.../cef_host> FLUTTER_CEF_ALLOW_INSECURE_PROFILE=1 \
//     flutter run -d macos -t lib/crispness_probe.dart
import 'package:flutter/material.dart';
import 'package:flutter_cef/flutter_cef.dart';

// A text-heavy page — blur shows up most clearly on small text + thin rules.
const _textHtml = '''<!doctype html><meta charset="utf-8">
<body style="margin:0;font:13px/1.5 -apple-system,system-ui;padding:16px;color:#111">
<h1 style="font-size:20px">Crispness test</h1>
<p>The quick brown fox jumps over the lazy dog. 0123456789.
Small text and <a href="#">thin hairlines</a> reveal upscaling blur.</p>
<hr>
<p style="font-size:11px">Zoom in: with renderScale this text re-rasterizes sharp;
without it, the 1x texture is magnified and goes soft.</p>
<table border=1 cellspacing=0 cellpadding=4 style="border-collapse:collapse;font-size:11px">
<tr><th>Col A</th><th>Col B</th><th>Col C</th></tr>
<tr><td>row 1</td><td>1.0</td><td>crisp</td></tr>
<tr><td>row 2</td><td>2.0</td><td>edges</td></tr>
</table>
</body>''';

void main() => runApp(const CrispApp());

class CrispApp extends StatefulWidget {
  const CrispApp({super.key});
  @override
  State<CrispApp> createState() => _CrispAppState();
}

class _CrispAppState extends State<CrispApp> {
  final _controller = CefWebController();
  double _zoom = 1.0;
  bool _crisp = true;

  @override
  void initState() {
    super.initState();
    _controller.onPageStarted = (_) => _controller.loadHtmlString(_textHtml);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenDpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 2.0;
    // The whole point: when crisp, render at screenDpr*zoom so the buffer has enough
    // pixels for the transform's magnification; otherwise leave it at screenDpr (blurry).
    final renderScale = _crisp ? screenDpr * _zoom : null;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF202733),
        body: Column(
          children: [
            Container(
              width: double.infinity,
              color: const Color(0xFF0B1220),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'zoom=${_zoom.toStringAsFixed(2)}   '
                      'renderScale=${renderScale?.toStringAsFixed(2) ?? "OFF (blurry)"}',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                  _btn('−', () => setState(
                      () => _zoom = (_zoom - 0.25).clamp(0.5, 4.0))),
                  const SizedBox(width: 6),
                  _btn('+', () => setState(
                      () => _zoom = (_zoom + 0.25).clamp(0.5, 4.0))),
                  const SizedBox(width: 14),
                  _btn(_crisp ? 'crisp ✓' : 'blurry',
                      () => setState(() => _crisp = !_crisp),
                      wide: true),
                ],
              ),
            ),
            Expanded(
              child: Center(
                // Fixed logical size, magnified by Transform.scale — exactly the
                // infinite-canvas case where `size` doesn't change on zoom.
                child: Transform.scale(
                  scale: _zoom,
                  child: SizedBox(
                    width: 360,
                    height: 300,
                    child: CefWebView(
                      url: 'about:blank',
                      controller: _controller,
                      renderScale: renderScale,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _btn(String label, VoidCallback onTap, {bool wide = false}) =>
      ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          minimumSize: Size(wide ? 90 : 44, 36),
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
        child: Text(label),
      );
}
