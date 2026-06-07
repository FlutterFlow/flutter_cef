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
  final CefWebController _controller = CefWebController();
  final TextEditingController _urlBar = TextEditingController(text: _startUrl);

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
  }

  void _go() => _controller.navigate(_normalize(_urlBar.text.trim()));

  String _normalize(String s) => s.isEmpty
      ? 'about:blank'
      : (s.startsWith('http') || s.contains(':') ? s : 'https://$s');

  @override
  void dispose() {
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
                  _navButton(Icons.arrow_back, _controller.canGoBack,
                      _controller.goBack),
                  _navButton(Icons.arrow_forward, _controller.canGoForward,
                      _controller.goForward),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: _controller.reload,
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
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
              child: CefWebView(url: _startUrl, controller: _controller),
            ),
          ],
        ),
      ),
    );
  }

  Widget _navButton(IconData icon, ValueListenable<bool> enabled, VoidCallback go) {
    return ValueListenableBuilder<bool>(
      valueListenable: enabled,
      builder: (_, can, _) =>
          IconButton(icon: Icon(icon), onPressed: can ? go : null),
    );
  }
}
