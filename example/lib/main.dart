import 'dart:io' show Platform;

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
  // The name of the persistent, shared profile this demo runs in, or null for
  // the default ephemeral (throwaway) session. Toggle it from the toolbar; the
  // view is rebuilt with a fresh controller so the new profile takes effect (a
  // profile is fixed at create() time). A non-null profile is mutually exclusive
  // with enableCdp, so CDP is only requested in the ephemeral (null) case.
  String? _profile;
  late CefWebController _controller = _newController();
  /// Anchors the context menu: the page reports click coords relative to the
  /// view, which must be mapped through this box to global coords.
  final GlobalKey _viewKey = GlobalKey();
  final FocusNode _webFocus = FocusNode(debugLabel: 'web');
  final TextEditingController _urlBar = TextEditingController(text: _startUrl);
  double _zoom = 0;

  // Find-in-page bar, opened by ⌘F / Ctrl+F via [CefWebView.onFind]. The view
  // has no find UI of its own; the host owns it and drives controller.find /
  // stopFind, reading results back on onFindResult.
  final TextEditingController _findBar = TextEditingController();
  final FocusNode _findFocus = FocusNode(debugLabel: 'find');
  bool _findVisible = false;
  CefFindResult? _findResult;

  CefWebController _newController() => CefWebController(profile: _profile);

  @override
  void initState() {
    super.initState();
    _wireController();
  }

  /// Draw the page context menu and return the chosen command id (null =
  /// dismissed). The view is a texture, so the menu is ordinary Flutter UI
  /// positioned at the click point.
  Future<int?> _showContextMenu(CefContextMenuRequest req) async {
    final box = _viewKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !mounted) return null;
    final origin = box.localToGlobal(Offset(req.x, req.y));
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return null;
    debugPrint('context menu: ${req.items.length} items, link="${req.linkUrl}" '
        'sel="${req.selectionText}" misspelled="${req.misspelledWord}"');
    return showMenu<int>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(origin.dx, origin.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: _menuEntries(req.items),
    );
  }

  List<PopupMenuEntry<int>> _menuEntries(List<CefContextMenuItem> items) {
    final out = <PopupMenuEntry<int>>[];
    for (final item in items) {
      switch (item.type) {
        case CefContextMenuItemType.separator:
          out.add(const PopupMenuDivider());
        case CefContextMenuItemType.submenu:
          // Flattened with a header for the demo; a real host would nest.
          out.add(PopupMenuItem<int>(
            enabled: false,
            child: Text(item.label,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ));
          out.addAll(_menuEntries(item.items));
        case CefContextMenuItemType.command:
        case CefContextMenuItemType.check:
        case CefContextMenuItemType.radio:
          out.add(PopupMenuItem<int>(
            value: item.commandId,
            // Chromium's own enabled state — Paste greys out with an empty
            // clipboard without the host deriving anything.
            enabled: item.enabled,
            child: Text(item.checked ? '\u2713 ${item.label}' : item.label),
          ));
      }
    }
    return out;
  }

  /// Attach the demo's listeners/callbacks to the current [_controller]. Called
  /// once at init and again whenever a profile toggle swaps the controller.
  void _wireController() {
    // Keep the URL bar showing the page's actual address as it navigates.
    _controller.url.addListener(() {
      final u = _controller.url.value;
      if (u.isNotEmpty && u != _urlBar.text) _urlBar.text = u;
    });
    _controller.onLoadError = (e) =>
        debugPrint('load error ${e.errorCode} ${e.url}: ${e.errorText}');
    // Right-click: Chromium built the menu, we draw it. A plain Material menu
    // here on purpose — this demonstrates the seam, not a design.
    _controller.onContextMenu = _showContextMenu;
    // Links that open a new window (target=_blank / window.open) load in place
    // rather than spawning a separate native window.
    _controller.onCreateWindow = (url) {
      _urlBar.text = url;
      _controller.navigate(url);
    };
    // A page->host JS channel: the page calls window.flutterCef.postMessage(...)
    // (see the "channel" toolbar button, which pokes the page to do exactly
    // that) and the message surfaces here. Registered per-controller, so it is
    // re-wired when a profile toggle swaps the controller.
    _controller.addJavaScriptChannel('flutterCef',
        onMessageReceived: (m) => _snack('JS channel -> $m'));
    // Find-in-page result updates, driven by the find bar (opened with ⌘F /
    // Ctrl+F). Guarded on mounted since the callback can outlive a rebuild.
    _controller.onFindResult = (r) {
      if (mounted) setState(() => _findResult = r);
    };
  }

  /// Toggle between the default ephemeral session and a persistent, shared
  /// `'work'` profile. A profile is bound at create() time, so we dispose the
  /// current controller and build a fresh one for the new profile; the keyed
  /// [CefWebView] recreates its session against it.
  void _toggleProfile() {
    final old = _controller;
    setState(() {
      _profile = _profile == null ? 'work' : null;
      _controller = _newController();
    });
    old.dispose();
    _wireController();
    _urlBar.text = _startUrl;
    _snack(_profile == null
        ? 'Ephemeral session (no profile) — login does not persist.'
        : "Persistent profile '$_profile' — login is shared + survives relaunch "
            '(CDP is disabled while a profile is active).');
  }

  void _setZoom(double z) {
    setState(() => _zoom = z.clamp(-3.0, 3.0));
    _controller.setZoomLevel(_zoom);
  }

  /// Poke the page to post a message back through the `flutterCef` JS channel
  /// registered in [_wireController] — exercises the page->host bridge.
  void _pingChannel() => _controller.executeJavaScript(
      "window.flutterCef && window.flutterCef.postMessage("
      "'hello from ' + location.host)");

  void _openFindBar() {
    setState(() => _findVisible = true);
    _findFocus.requestFocus();
  }

  /// (Re)issue the current find query. An empty query stops the search.
  /// [findNext] advances to the next/previous match of the same query.
  void _runFind({bool findNext = false, bool forward = true}) {
    final q = _findBar.text;
    if (q.isEmpty) {
      _controller.stopFind();
      setState(() => _findResult = null);
      return;
    }
    _controller.find(q, forward: forward, findNext: findNext);
  }

  void _closeFindBar() {
    _controller.stopFind();
    _findBar.clear();
    setState(() {
      _findVisible = false;
      _findResult = null;
    });
    _webFocus.requestFocus();
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
    _findBar.dispose();
    _findFocus.dispose();
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
                    icon: const Icon(Icons.forum_outlined),
                    tooltip: 'Post a message from the page over a JS channel',
                    onPressed: _pingChannel,
                  ),
                  IconButton(
                    icon: const Icon(Icons.search),
                    tooltip: 'Find in page (also ⌘F / Ctrl+F)',
                    onPressed: _openFindBar,
                  ),
                  IconButton(
                    icon: const Icon(Icons.bug_report_outlined),
                    tooltip: 'openDevTools()',
                    onPressed: _controller.openDevTools,
                  ),
                  // macOS-only: showEmojiPicker drives the AppKit Character
                  // Palette; there is no supported Win32 equivalent (PLAN §6),
                  // so the button is hidden per-platform.
                  if (Platform.isMacOS)
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
                  IconButton(
                    icon: Icon(_profile == null
                        ? Icons.person_off_outlined
                        : Icons.person_outline),
                    tooltip: _profile == null
                        ? "Switch to a persistent 'work' profile"
                        : "Profile '$_profile' — switch back to ephemeral",
                    onPressed: _toggleProfile,
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
            if (_findVisible) _buildFindBar(),
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
              child: KeyedSubtree(
                key: _viewKey,
                child: CefWebView(
                // Key on the profile so toggling it rebuilds the view against
                // the fresh controller (a profile is fixed at create() time).
                key: ValueKey(_profile),
                url: _startUrl,
                controller: _controller,
                focusNode: _webFocus,
                // ⌘F / Ctrl+F opens the host's find bar (the view has none of
                // its own); it drives controller.find / stopFind.
                onFind: _openFindBar,
                allowedSchemes: _allowedSchemes,
                // Persistent, shared profile: login survives relaunch and is
                // shared by every view with the same name. Null (default) is an
                // ephemeral throwaway session. Toggle it from the toolbar.
                profile: _profile,
                // Demo: expose CDP so the page can be driven by a CDP client
                // (the bound port is on _controller.cdpPort). CDP is mutually
                // exclusive with a named profile, so only request it when none
                // is active.
                enableCdp: _profile == null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The host-owned find bar (⌘F / Ctrl+F). Drives [CefWebController.find] /
  /// `stopFind` and shows the `active/total` match count from `onFindResult`.
  Widget _buildFindBar() {
    final r = _findResult;
    final label = (r == null || _findBar.text.isEmpty)
        ? ''
        : '${r.activeMatchOrdinal}/${r.numberOfMatches}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _findBar,
              focusNode: _findFocus,
              autofocus: true,
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                hintText: 'Find in page',
                suffixText: label,
              ),
              onChanged: (_) => _runFind(),
              onSubmitted: (_) => _runFind(findNext: true),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_up),
            tooltip: 'Previous match',
            onPressed: () => _runFind(findNext: true, forward: false),
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down),
            tooltip: 'Next match',
            onPressed: () => _runFind(findNext: true),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Close find bar',
            onPressed: _closeFindBar,
          ),
        ],
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
