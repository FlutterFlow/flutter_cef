import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cef/flutter_cef.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(
    title: 'flutter_cef',
    debugShowCheckedModeBanner: false,
    home: BrowserDemo(),
  );
}

/// A small browser built on one [CefWebView] + its [CefWebController]: a URL
/// bar, back/forward/reload wired to the controller's history state, a loading
/// bar, and the live page title.
class BrowserDemo extends StatefulWidget {
  const BrowserDemo({super.key});

  @override
  State<BrowserDemo> createState() => _BrowserDemoState();
}

class _BrowserDemoState extends State<BrowserDemo> {
  static const _startUrl = 'https://flutter.dev';
  // Demonstrates the navigation scheme allowlist: this view may only navigate
  // to http(s) (and about:, which is always permitted). Try the "block test"
  // toolbar button — a file:// navigation is refused in the renderer's
  // OnBeforeBrowse and the page stays put. Pass `null` to allow every scheme.
  static const _allowedSchemes = {'http', 'https'};
  final CefWebController _controller = CefWebController();
  final FocusNode _webFocus = FocusNode(debugLabel: 'web');
  final TextEditingController _urlBar = TextEditingController(text: _startUrl);
  double _zoom = 0;

  @override
  void initState() {
    super.initState();
    // Keep the URL bar showing the page's actual address as it navigates.
    _controller.url.addListener(() {
      final u = _controller.url.value;
      if (u.isNotEmpty && u != _urlBar.text) _urlBar.text = u;
    });
    _controller.onLoadError = (e) =>
        debugPrint('load error ${e.errorCode} ${e.url}: ${e.errorText}');
    // Links that open a new window (target=_blank / window.open) load in place
    // rather than spawning a separate native window.
    _controller.onCreateWindow = (url) {
      _urlBar.text = url;
      _controller.navigate(url);
    };
  }

  void _setZoom(double z) {
    setState(() => _zoom = z.clamp(-3.0, 3.0));
    _controller.setZoomLevel(_zoom);
  }

  Future<void> _runJs() async {
    try {
      final r = await _controller.runJavaScriptReturningResult(
        'document.title + " @ " + location.host',
      );
      _snack('JS → $r');
    } catch (e) {
      _snack('JS error: $e');
    }
  }

  /// Read every cookie the page can see and surface a quick summary — exercises
  /// the host cookie visitor end-to-end.
  Future<void> _dumpCookies() async {
    try {
      final cookies = await _controller.getCookies();
      final preview = cookies
          .take(3)
          .map((c) => '${c.name}=${c.value}')
          .join(', ');
      _snack(
        '${cookies.length} cookie(s)${preview.isEmpty ? '' : ' → $preview'}',
      );
    } catch (e) {
      _snack('cookies error: $e');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 4)),
    );
  }

  /// Load a tiny form to exercise text input: focus a field, switch to a CJK
  /// input source (or press ⌃⌘Space for emoji), and the composition + committed
  /// text should land in the page intact.
  void _loadImeTest() {
    _urlBar.text = 'IME test';
    _controller.loadHtmlString('''
<!doctype html><meta charset="utf-8">
<style>
  body{font:20px system-ui;margin:24px;color:#111;background:#fff}
  h1{font-size:22px} label{display:block;margin:16px 0 4px;color:#444}
  input,textarea{font:20px system-ui;width:100%;box-sizing:border-box;padding:8px}
  .echo{margin-top:12px;color:#666;font-size:16px}
</style>
<h1>IME / text-input test</h1>
<p>Switch to a CJK input source (or press ⌃⌘Space for emoji) and type. The
composition should underline, the candidate window should sit under the caret,
and committed text — including emoji — should appear intact.</p>
<label>Single-line input</label>
<input id="a" autofocus placeholder="type here…">
<label>Textarea</label>
<textarea id="b" rows="4" placeholder="type here…"></textarea>
<label>Dropdown (focus it, then use arrow keys / type to select)</label>
<select id="s">
  <option>Apple</option><option>Banana</option><option>Cherry</option>
  <option>Date</option><option>Elderberry</option><option>Fig</option>
</select>
<p><button id="btn" type="button">Button (Tab to it, Enter or Space)</button></p>
<p><label><input type="checkbox" id="cb"> Checkbox (Tab to it, Space toggles)</label></p>
<div class="echo">last value: <span id="e">—</span></div>
<script>
  const e = document.getElementById('e');
  for (const el of [a, b]) {
    el.addEventListener('input', ev => { e.textContent = JSON.stringify(ev.target.value); });
  }
  s.addEventListener('change', ev => { e.textContent = 'select → ' + JSON.stringify(ev.target.value); });
  let n = 0;
  btn.addEventListener('click', () => { e.textContent = 'button clicked ×' + (++n); });
  cb.addEventListener('change', () => { e.textContent = 'checkbox ' + (cb.checked ? 'on' : 'off'); });
</script>''');
  }

  void _go() => _controller.navigate(_normalize(_urlBar.text.trim()));

  /// Exercise [_allowedSchemes]: attempt a file:// navigation, which is not in
  /// the allowlist and so should be refused in the renderer's OnBeforeBrowse —
  /// the page should NOT change to the file listing.
  void _tryBlockedScheme() {
    const blocked = 'file:///etc/hosts';
    _snack('Navigating to $blocked — should be REFUSED (allowed: '
        '${_allowedSchemes.join(", ")}). The page should not change.');
    _controller.navigate(blocked);
  }

  String _normalize(String s) => s.isEmpty
      ? 'about:blank'
      : (s.startsWith('http') || s.contains(':') ? s : 'https://$s');

  /// Re-focus the page (a toolbar tap moves focus to the button), then open the
  /// macOS emoji picker — it targets whatever is focused, so the page must be.
  Future<void> _emojiPicker() async {
    _webFocus.requestFocus();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await _controller.showEmojiPicker();
  }

  @override
  void dispose() {
    _webFocus.dispose();
    _urlBar.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  _navButton(
                    Icons.arrow_back,
                    _controller.canGoBack,
                    _controller.goBack,
                  ),
                  _navButton(
                    Icons.arrow_forward,
                    _controller.canGoForward,
                    _controller.goForward,
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: _controller.reload,
                  ),
                  IconButton(
                    icon: const Icon(Icons.zoom_out),
                    onPressed: () => _setZoom(_zoom - 0.5),
                  ),
                  IconButton(
                    icon: const Icon(Icons.zoom_in),
                    onPressed: () => _setZoom(_zoom + 0.5),
                  ),
                  IconButton(
                    icon: const Icon(Icons.code),
                    tooltip: 'runJavaScriptReturningResult(document.title)',
                    onPressed: _runJs,
                  ),
                  IconButton(
                    icon: const Icon(Icons.cookie_outlined),
                    tooltip: 'getCookies() for the current page',
                    onPressed: _dumpCookies,
                  ),
                  IconButton(
                    icon: const Icon(Icons.bug_report_outlined),
                    tooltip: 'openDevTools()',
                    onPressed: _controller.openDevTools,
                  ),
                  IconButton(
                    icon: const Icon(Icons.emoji_emotions_outlined),
                    tooltip: 'showEmojiPicker() (focus a field first)',
                    onPressed: _emojiPicker,
                  ),
                  IconButton(
                    icon: const Icon(Icons.keyboard),
                    tooltip: 'Load the IME / text-input test page',
                    onPressed: _loadImeTest,
                  ),
                  IconButton(
                    icon: const Icon(Icons.block),
                    tooltip: 'Try a blocked file:// navigation (allowedSchemes)',
                    onPressed: _tryBlockedScheme,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _urlBar,
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                        hintText: 'Enter a URL',
                      ),
                      onSubmitted: (_) => _go(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: _go, child: const Text('Go')),
                ],
              ),
            ),
            ValueListenableBuilder<bool>(
              valueListenable: _controller.isLoading,
              builder: (_, loading, _) => loading
                  ? const LinearProgressIndicator(minHeight: 2)
                  : const SizedBox(height: 2),
            ),
            ValueListenableBuilder<String>(
              valueListenable: _controller.title,
              builder: (_, title, _) => Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Text(
                    title.isEmpty ? '—' : title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
            Expanded(
              child: CefWebView(
                url: _startUrl,
                controller: _controller,
                focusNode: _webFocus,
                allowedSchemes: _allowedSchemes,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _navButton(
    IconData icon,
    ValueListenable<bool> enabled,
    VoidCallback go,
  ) {
    return ValueListenableBuilder<bool>(
      valueListenable: enabled,
      builder: (_, can, _) =>
          IconButton(icon: Icon(icon), onPressed: can ? go : null),
    );
  }
}
