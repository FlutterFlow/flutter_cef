# flutter_cef

Embed a **live Chromium browser** (via the [Chromium Embedded Framework](https://bitbucket.org/chromiumembedded/cef/)) as a Flutter widget — rendered into a `Texture`, so it composites, transforms, clips, and zooms like any other widget, and **keeps rendering even when off-screen / not focused**. Pointer, scroll, and trackpad two-finger pans are forwarded by coordinate (pans are caught even when an ancestor opts into Flutter's trackpad gesture API, as canvas hosts do), and keyboard input reaches the page as real `keydown → keypress → keyup` events (Enter activates a focused button / submits a form, Space toggles a checkbox) — including platform IME composition for CJK / emoji and the ⌃⌘Space emoji picker. Text input is bound to the hosting `FlutterView` (as `EditableText` does), so it **works in multi-view / multi-window apps**; the page cursor drives a `MouseRegion`.

> Status: **experimental, macOS 12+ only** (CEF 144 runtime floor). Real Chromium (any site — JS/CSS/WebGL/video). **Multi-process by default** (GPU-accelerated OSR — `OnAcceleratedPaint` GPU compositing into a shared IOSurface, Retina-crisp; renderer/utility crashes isolated, so heavy SPAs like Google sign-in render and survive); `CEF_MULTI_PROCESS=OFF packages/flutter_cef_macos/native/build_cef_host.sh` for the simpler single-process build. No mobile (iOS bans third-party engines); desktop by nature.

```dart
import 'package:flutter_cef/flutter_cef.dart';

CefWebView(url: 'https://flutter.dev')
```

Drive and observe it via a controller:

```dart
final c = CefWebController();
CefWebView(url: startUrl, controller: c);

// navigation + history + loading
c.navigate('https://example.com');
c.reload(); c.stop(); c.goBack(); c.goForward();
c.loadHtmlString('<h1>hi</h1>'); c.loadFile('/abs/page.html');
c.setZoomLevel(1.0);                 // 1.2^level (0 = 100%)
c.find('term'); c.stopFind();        // results on c.onFindResult

// JavaScript: run, return a value, and talk back from the page
c.executeJavaScript('document.body.style.zoom = 1.2');
final title = await c.runJavaScriptReturningResult('document.title'); // String/num/List/Map
c.addJavaScriptChannel('Native', onMessageReceived: (m) => print('JS says $m'));
// then in the page: window.Native.postMessage('hello')

// page state (ValueListenables) + lifecycle/dialog callbacks
c.isLoading;  c.url;  c.title;  c.canGoBack;  c.canGoForward;
c.onPageStarted = (u) {}; c.onPageFinished = (u) {}; c.onProgress = (p) {};
c.onUrlChange = (u) {}; c.onCreateWindow = (u) => c.navigate(u); // target=_blank
c.onLoadError = (e) => print('${e.errorCode} ${e.url}');
c.onConsoleMessage = (m) => print(m.message);
c.onJavaScriptConfirmDialog = (req) async => askUser(req.message); // alert/confirm/prompt

// cookies + scroll + storage
c.setCookie(url: 'https://example.com/', name: 'sid', value: 'abc');
final cookies = await c.getCookies(); // read/enumerate; pass url: to scope
c.deleteCookie(url: 'https://example.com/', name: 'sid'); c.clearCookies();
c.scrollTo(0, 200); c.scrollBy(0, -50); await c.getScrollPosition();
c.clearLocalStorage(); await c.getTitle(); await c.getUserAgent();
c.onDownload = (suggestedName) {}; // downloads land in ~/Downloads

// open the Chrome DevTools inspector for this view in its own window
c.openDevTools();

// open the macOS emoji & symbols picker over the focused page (same as ⌃⌘Space)
c.showEmojiPicker();
```

See `example/` for a full browser chrome (URL bar, back/forward/reload, loading
bar, live title).

## How it works

```
Dart  CefWebView + CefWebController   (MethodChannel "flutter_cef")
  → macOS plugin (FlutterCefPlugin / CefWebSession):
      allocates a global IOSurface + CVPixelBuffer, registers a FlutterTexture,
      spawns one cef_host.app per view, relays input + cursor over a Unix socket
  → cef_host.app: CEF windowless (OSR), multi-process — the GPU/Viz process
      composites the page and hands OnAcceleratedPaint a shared-texture
      IOSurface, which cef_host copies into the host-shared IOSurface →
      "present" → the texture re-samples. (OnPaint software blit is the
      single-process fallback.)
```

Same pattern JCEF (JetBrains) and CefSharp use to render Chromium into a non-native toolkit — adapted to Flutter's `Texture` + `IOSurface`.

## Building

CEF (~200 MB) is **fetched**, not vendored. Build the renderer once:

```sh
# The macOS implementation lives in packages/flutter_cef_macos.
cd packages/flutter_cef_macos
native/build_cef_host.sh            # fetches CEF + builds cef_host.app
export FLUTTER_CEF_HOST="$PWD/native/cef_host/build/cef_host.app/Contents/MacOS/cef_host"
cd ../../example && flutter run -d macos
```

### Bundling into a distributable app

For a shipped `.app` (no dev env var), `cef_host.app` must live in your bundle's
`Contents/Frameworks` and be signed by your build. The plugin resolves it there
automatically (`$FLUTTER_CEF_HOST` → pod resources → `Contents/Frameworks` →
`Contents/Helpers`). After `flutter build macos`, run:

```sh
packages/flutter_cef_macos/tool/bundle_cef_host.sh "build/macos/.../YourApp.app" "" "<signing-identity>"
```

or wire it as a Run Script build phase on your Runner target (snippet in
`packages/flutter_cef_macos/tool/bundle_cef_host.sh`) so it runs before Xcode's
code-sign phase. Your host
app **must not be App-Sandboxed** (CEF spawns the helper, shares a global
IOSurface, writes a cache); entitlements need
`com.apple.security.cs.disable-library-validation` + JIT — see
`example/macos/Runner/*.entitlements` for the reference set. Sign everything with
one identity (framework → cef_host → app, inside-out) and library validation can
stay on.

## Security

`flutter_cef` embeds a full Chromium that runs arbitrary web content with JIT.
Treat any page you load as untrusted code. The security posture is driven by one
build flag, `CEF_HOST_ADHOC` (default `ON`):

| | `CEF_HOST_ADHOC=ON` (default, dev/CI) | `CEF_HOST_ADHOC=OFF` (signed release) |
| --- | --- | --- |
| Chromium renderer/GPU sandbox | off (`no_sandbox=true`) | **on** — helper calls `CefScopedSandboxContext` |
| Mach-port peer validation | bypassed (env var + `--disable-features`) | **enforced** |
| Cookie-at-rest encryption | mock keychain / `password-store=basic` | **real Keychain / OSCrypt** |
| `get-task-allow` entitlement | present (local debugging) | **absent** (`entitlements.release.plist`) |

The `OFF` posture only *validates* under correct **inside-out Developer-ID
signing** of the `cef_host` tree (deepest helper → `libcef_sandbox.dylib` + CEF
framework → host, depth-first, Hardened Runtime + trusted timestamp). Build it
with `CEF_HOST_ADHOC=OFF CODESIGN_ID="<Developer ID>"
packages/flutter_cef_macos/native/build_cef_host.sh`,
or — when bundled into a host app — let the app's own signing re-sign the tree
with those entitlements. Ad-hoc/dev builds run unsandboxed by necessity (the
sandbox can't validate without proper signing), which is why `ON` is the default.

Other always-on protections:

- **Hardened-runtime relaxations** (`disable-library-validation`, `allow-jit`,
  `allow-unsigned-executable-memory`) are kept in both entitlements files — CEF's
  JIT renderer + dlopen'd framework require them.
- **Navigation scheme allowlist** (`CefWebView(allowedSchemes:)`) — gate which
  schemes a page may navigate to (main-frame nav, programmatic `navigate()`,
  clicks, redirects); host content-injection (`loadHtmlString`/`loadFile`) is
  exempt. Off by default (allow-all).
- **JS channel names are validated** as JS identifiers before injection, and
  **`runJavaScriptReturningResult` expects a single expression** from trusted
  app code.
- **Per-user, per-process CEF cache** (under the 0700 temp dir, not a fixed
  world-readable `/tmp` path) and a **randomized control-socket name**.

## Roadmap

Known limitation: the IOSurface is single-buffered, so very fast-updating pages
can tear slightly under the compositor; double-buffering is planned. Working
today: **multi-process, GPU-accelerated** OSR render (on/off-screen,
HiDPI/Retina-crisp, GPU compositing via `OnAcceleratedPaint`, heavy SPAs render +
survive),
pointer/scroll/trackpad-pan/keyboard input, **IME text input** (CJK composition
+ emoji, the candidate window tracked under the caret, and the ⌃⌘Space emoji
picker — `showEmojiPicker()`) **in single- and multi-view (multi-window) hosts**
(the connection carries `TextInputConfiguration.viewId` and is re-shown on every
click, EditableText-style), `<select>` popups, page cursor;
navigation + history, page-lifecycle events (start/finish/progress/url-change),
new-window routing (`onCreateWindow`), loading/title/url/error/console state; JS
dialogs (alert/confirm/prompt), a JS bridge (`addJavaScriptChannel` +
`runJavaScriptReturningResult` over `CefMessageRouter`), `executeJavaScript`;
content zoom, find-in-page, `loadHtmlString`/`loadFile`, cookies
(set/clear plus read/enumerate via `getCookies` + `deleteCookie`), scroll,
title/user-agent getters, downloads, and a Chrome DevTools inspector window
(`openDevTools`).

Next:

- **True zero-copy GPU render.** Rendering is now GPU-accelerated:
  `OnAcceleratedPaint` (GPU compositing) is on by default, multi-process and
  crash-isolated. The `-67030` that used to gate the GPU→browser handoff (Chromium
  144 validating cef_host's ad-hoc signature) is cleared by disabling the
  `MachPortRendezvous*PeerRequirements` features — no Developer-ID signing needed.
  We still **copy** the GPU surface into the shared surface (cheap on
  unified-memory Macs, where compositing — not the copy — was the bottleneck).
  TRUE zero-copy — handing the GPU IOSurface to Flutter with no copy — needs
  cross-process Mach-port surface transfer (CEF's GPU surfaces aren't resolvable
  by global id from another process), and mostly helps discrete-GPU Macs and
  scenes with many simultaneously-animating webviews; deferred until measured.
- **Double-buffer the IOSurface** to remove the residual tearing on
  fast-updating pages (JCEF's named-mutex 2-slot buffer is a good reference).
- **The CEF feature tail** that CefSharp/JCEF expose: `loadRequest` with custom
  headers / POST body, `setUserAgent`, request / resource interception, custom
  scheme handlers, a typed DevTools/CDP client (the inspector window already
  ships via `openDevTools`; this is the programmatic CDP surface), and `CefPermissionHandler`
  (WebRTC camera/mic prompts).
- **Windows / Linux** — the package is **federated** (`flutter_cef` +
  `flutter_cef_platform_interface` + `flutter_cef_macos`); a new platform is a
  sibling `flutter_cef_<os>` package. The CEF logic + IPC protocol are portable;
  each OS supplies its own host plugin + shared-texture / transport / sandbox
  glue. See [`PORTING.md`](PORTING.md) for the full contract and seam map.

## Credits

Built on [CEF](https://bitbucket.org/chromiumembedded/cef/). Patterns drawn from CEF's `cefclient` OSR sample, [JCEF](https://github.com/chromiumembedded/java-cef), and [CefSharp](https://github.com/cefsharp/CefSharp).
