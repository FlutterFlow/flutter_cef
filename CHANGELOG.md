## 0.1.0

* Multi-process CEF by default — crash-isolated, so heavy SPAs (e.g. Google
  sign-in) render and survive. **GPU-accelerated OSR**: CEF's GPU process
  composites the page and hands it to `OnAcceleratedPaint` as a shared IOSurface,
  which moves compositing off the CPU (the bottleneck for video / animation).
  This runs multi-process without Developer-ID signing by disabling the
  MachPort peer-requirement validation that otherwise `-67030`s the GPU→browser
  handoff. The composited surface is still copied into the shared surface (cheap
  on unified-memory Macs); true zero-copy is on the roadmap.
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
* Cookies (`setCookie` / `clearCookies`, plus `getCookies` to read/enumerate —
  optionally scoped to a URL — and `deleteCookie`), scrolling (`scrollTo` /
  `scrollBy` / `getScrollPosition`), `getTitle` / `getUserAgent`,
  `clearLocalStorage`.
* Downloads (`onDownload` + the native Save panel).
* `openDevTools` — opens the Chrome DevTools inspector for the view in its own
  window (Elements / Console / Network / Sources, inspecting the live page).
* Automatic IME / text input: while focused, `CefWebView` holds a platform
  `TextInputConnection`, so dead keys, CJK composition, and emoji all reach the
  page. Committed text is sent as full UTF-8 (fixes the prior surrogate-pair
  truncation that mangled emoji / astral characters), composition is relayed and
  visibly underlined, and the OS candidate window is positioned under the caret
  (`OnImeCompositionRangeChanged` readback). The low-level
  `imeSetComposition` / `imeCommitText` / `imeCancelComposition` controller verbs
  remain for direct use.
* The macOS emoji & symbols picker (⌃⌘Space) now opens cold over the page —
  previously it only worked after the shortcut had been used in another (native)
  text field first. Two fixes: the key router no longer swallows ⌃⌘Space (it
  carries no `character`, so it was being treated as a consumed non-text key
  instead of falling through to the platform input context), and a caret rect is
  now always pushed while focused (seeded at the last click), so the picker —
  and the candidate / accent popups — anchor at the text instead of the screen
  corner. New `showEmojiPicker()` opens the same picker programmatically.
* Keyboard activation: typed characters now reach the page as real
  `keydown → keypress → keyup` events (a CHAR key event) like a browser, instead
  of an IME commit that fired no key events. So a focused control activates from
  the keyboard: **Enter** clicks a button / submits a form, **Space** toggles a
  checkbox / radio or clicks a button, and the page's own keypress handlers fire.
  (Composition results and multi-unit inserts — emoji, paste — still commit via
  the IME, which is correct: they have no keypress.) Space also now carries its
  `character` on keydown/keyup so Blink resolves the activation key.
* Input fidelity: editing / navigation keys (Backspace, arrows, …) no longer
  double-apply (one Backspace deleted two characters; one arrow moved two
  options in a `<select>`) — the host now sets the macOS `character` /
  `unmodified_character` on every key, which de-duplicates the edit command on
  CEF's OSR path (known CEF behavior). `<select>` dropdowns now position and
  click correctly on Retina — the popup composite offset is scaled by the device
  pixel ratio. Key routing also stops Flutter's own shortcuts from eating arrow
  keys while the view is focused.
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
