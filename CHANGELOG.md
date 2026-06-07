## 0.0.1

* Initial macOS preview: `CefWebView` widget + `CefWebController`.
* Live Chromium (CEF) rendered off-screen into a Flutter `Texture` via a
  per-view `cef_host` subprocess and a shared IOSurface.
* Pointer, scroll, and keyboard input forwarding; page cursor drives a
  `MouseRegion`. Native `<select>` dropdowns composite over the view.
* Navigation + history: `navigate` / `reload` / `stop` / `goBack` /
  `goForward`, gated by `canGoBack` / `canGoForward`.
* Page state to Dart: `isLoading`, `title`, `url` (`ValueListenable`s) plus
  `onLoadError` and `onConsoleMessage` callbacks.
* `executeJavaScript(code)` (fire-and-forget).
* `native/build_cef_host.sh` fetches CEF and builds `cef_host.app`.
