## 0.1.0

* Multi-process CEF by default — crash-isolated, so heavy SPAs (e.g. Google
  sign-in) render and survive. Software OSR (`OnPaint` readback +
  `--disable-gpu-compositing`); the zero-copy GPU path is on the roadmap.
* Fixed a multi-process blank-render bug (resize-race: geometry is re-synced
  when the renderer connects) and hardened the IPC (pre-connect frame queue).
* Page-lifecycle callbacks: `onPageStarted`, `onPageFinished`, `onProgress`,
  `onUrlChange`; new-window routing via `onCreateWindow`.
* JavaScript bridge over `CefMessageRouter`: `runJavaScriptReturningResult`
  (JSON round-trip — primitives, lists, maps) and `addJavaScriptChannel`
  (`window.<name>.postMessage` → Dart).
* JS dialogs: `onJavaScriptAlertDialog` / `onJavaScriptConfirmDialog` /
  `onJavaScriptTextInputDialog`.
* Content zoom (`setZoomLevel`), find-in-page (`find` / `stopFind` /
  `onFindResult`), `loadHtmlString` / `loadFile`.
* Cookies (`setCookie` / `clearCookies`), scrolling (`scrollTo` / `scrollBy` /
  `getScrollPosition`), `getTitle` / `getUserAgent`, `clearLocalStorage`.
* Downloads (`onDownload` + the native Save panel) and a low-level IME
  composition API (`imeSetComposition` / `imeCommitText` /
  `imeCancelComposition`).
* Verbose CEF logging is now gated behind the `FLUTTER_CEF_DEBUG` env var.
* Hardening (security/concurrency audit): validate JS channel names before
  injection; fail pending `runJavaScriptReturningResult` completers on
  navigation/dispose; deterministic session teardown that joins the reader
  thread (no use-after-free on dispose); per-user/per-process CEF cache +
  randomized IPC socket (off the world-readable `/tmp`); null main-frame and
  resize-dimension guards in the host.

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
