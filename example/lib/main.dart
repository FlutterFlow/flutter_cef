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

/// Minimal browser: a URL bar driving one [CefWebView]. The first page loads
/// via the `url` argument; subsequent navigations go through the controller.
class BrowserDemo extends StatefulWidget {
  const BrowserDemo({super.key});

  @override
  State<BrowserDemo> createState() => _BrowserDemoState();
}

class _BrowserDemoState extends State<BrowserDemo> {
  static const _startUrl = 'https://flutter.dev';
  final CefWebController _controller = CefWebController();
  final TextEditingController _urlBar =
      TextEditingController(text: _startUrl);

  void _go() => _controller.navigate(_normalize(_urlBar.text.trim()));

  String _normalize(String s) => s.isEmpty
      ? 'about:blank'
      : (s.startsWith('http://') || s.startsWith('https://') ? s : 'https://$s');

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
            Expanded(
              child: CefWebView(url: _startUrl, controller: _controller),
            ),
          ],
        ),
      ),
    );
  }
}
