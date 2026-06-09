## 0.1.2

* **Navigation scheme allowlist**: `CefWebView(allowedSchemes: {...})` restricts
  which URL schemes the page may navigate to — the initial load, programmatic
  `navigate()`, in-page link clicks, and redirects are all gated in the
  renderer's `OnBeforeBrowse`. `about:` is always permitted. Pass e.g.
  `{'http', 'https'}` to keep an untrusted page off `file:` / `data:` /
  `chrome:` schemes — important when a host can drive navigation
  programmatically. Default (`null`) preserves the previous allow-all behavior,
  so this is a non-breaking, opt-in addition. The host's explicit
  content-injection APIs — `loadHtmlString` (a `data:` URL) and `loadFile` (a
  `file:` URL) — are exempt from the allowlist, since the host (not the page)
  chose that content; only navigation (the page's, and `navigate()`) is gated.

## 0.1.1

* **Multi-view host support**: the IME connection now carries
  `TextInputConfiguration.viewId` (as `EditableText` does). In a host that
  enables Flutter's multi-view mode the implicit view 0 does not exist, so a
  config without `viewId` bound the IME to a nil view and `show()` silently
  failed — pages received keydown/keyup but never characters. Typing, CJK
  composition, and the emoji picker now work in multi-view (multi-window) apps.
* Re-issue `TextInput.show()` on every click into an already-focused view
  (mirrors `EditableText.requestKeyboard`), so hosts that move macOS first
  responder around between clicks can't strand the IME view; also re-seeds the
  emoji/accent-picker caret anchor at the latest click.
* Trackpad scrolling inside hosts that opt into Flutter's trackpad gesture API
  (e.g. canvas apps): two-finger pans arrive as `PointerPanZoom*` events rather
  than `PointerScrollEvent`s — they are now forwarded to the page as scrolls,
  with a gain factor to approximate native browser scroll distance.

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
