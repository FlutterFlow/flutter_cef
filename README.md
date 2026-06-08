# flutter_cef

Embed a **live Chromium browser** (via the [Chromium Embedded Framework](https://bitbucket.org/chromiumembedded/cef/)) as a Flutter widget — rendered into a `Texture`, so it composites, transforms, clips, and zooms like any other widget, and **keeps rendering even when off-screen / not focused**. Pointer, scroll, and keyboard input are forwarded; the page cursor drives a `MouseRegion`.

> Status: **experimental, macOS 12+ only** (CEF 144 runtime floor). Real Chromium (any site — JS/CSS/WebGL/video). **Multi-process by default** (software OSR — `OnPaint` CPU readback into a shared IOSurface, Retina-crisp; renderer/utility crashes isolated, so heavy SPAs like Google sign-in render and survive); `-DCEF_MULTI_PROCESS=OFF` for the simpler single-process build. No mobile (iOS bans third-party engines); desktop by nature.

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
c.scrollTo(0, 200); await c.getScrollPosition(); c.clearLocalStorage();
```

See `example/` for a full browser chrome (URL bar, back/forward/reload, loading
bar, live title).

## How it works

```
Dart  CefWebView + CefWebController   (MethodChannel "flutter_cef")
  → macOS plugin (FlutterCefPlugin / CefWebSession):
      allocates a global IOSurface + CVPixelBuffer, registers a FlutterTexture,
      spawns one cef_host.app per view, relays input + cursor over a Unix socket
  → cef_host.app: CEF windowless (OSR) → OnPaint copies the frame into the
      shared IOSurface → "present" → the texture re-samples
```

Same pattern JCEF (JetBrains) and CefSharp use to render Chromium into a non-native toolkit — adapted to Flutter's `Texture` + `IOSurface`.

## Building

CEF (~200 MB) is **fetched**, not vendored. Build the renderer once:

```sh
native/build_cef_host.sh            # fetches CEF + builds cef_host.app
export FLUTTER_CEF_HOST="$PWD/native/cef_host/build/cef_host.app/Contents/MacOS/cef_host"
cd example && flutter run -d macos
```

### Bundling into a distributable app

For a shipped `.app` (no dev env var), `cef_host.app` must live in your bundle's
`Contents/Frameworks` and be signed by your build. The plugin resolves it there
automatically (`$FLUTTER_CEF_HOST` → pod resources → `Contents/Frameworks` →
`Contents/Helpers`). After `flutter build macos`, run:

```sh
path/to/flutter_cef/tool/bundle_cef_host.sh "build/macos/.../YourApp.app" "" "<signing-identity>"
```

or wire it as a Run Script build phase on your Runner target (snippet in
`tool/bundle_cef_host.sh`) so it runs before Xcode's code-sign phase. Your host
app **must not be App-Sandboxed** (CEF spawns the helper, shares a global
IOSurface, writes a cache); entitlements need
`com.apple.security.cs.disable-library-validation` + JIT — see
`example/macos/Runner/*.entitlements` for the reference set. Sign everything with
one identity (framework → cef_host → app, inside-out) and library validation can
stay on.

## Roadmap

Working today: **multi-process** OSR render (on/off-screen, HiDPI/Retina-crisp,
software `OnPaint` readback into a shared IOSurface, heavy SPAs render + survive),
pointer/scroll/keyboard input, `<select>` popups, page cursor; navigation +
history, page-lifecycle events (start/finish/progress/url-change), new-window
routing (`onCreateWindow`), loading/title/url/error/console state; JS dialogs
(alert/confirm/prompt), a JS bridge (`addJavaScriptChannel` +
`runJavaScriptReturningResult` over `CefMessageRouter`), `executeJavaScript`;
content zoom, find-in-page, `loadHtmlString`/`loadFile`, cookies, scroll, and
title/user-agent getters.

Next:

- **Zero-copy GPU render (`OnAcceleratedPaint`).** Multi-process currently uses
  software OSR (`OnPaint` CPU readback) + `--disable-gpu-compositing`, because the
  GPU shared-texture path is blocked: Chromium 144 can't validate cef_host's
  ad-hoc signature (`-67030`), which gates the GPU→browser IOSurface handoff.
  Unblock it with **correct inside-out Developer-ID signing** (`--timestamp`, no
  `get-task-allow`, sign every Mach-O depth-first — how OBS/JCEF satisfy the same
  validation), then set `shared_texture_enabled = true` to switch on the
  zero-copy path (the `OnAcceleratedPaint` handler is already in place). Then
  notarize for distribution.
- **IME / composition** (CJK, emoji), **downloads**, `loadRequest` with
  custom headers / POST body, `setUserAgent`, devtools, and Windows / Linux
  hosts (the federated structure is ready; each needs its own shared-texture
  path).
- **Windows / Linux** — the federated structure is ready; each needs its own host
  + shared-texture path.

## Credits

Built on [CEF](https://bitbucket.org/chromiumembedded/cef/). Patterns drawn from CEF's `cefclient` OSR sample, [JCEF](https://github.com/chromiumembedded/java-cef), and [CefSharp](https://github.com/cefsharp/CefSharp).
