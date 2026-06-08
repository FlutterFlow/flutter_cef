# flutter_cef

Embed a **live Chromium browser** (via the [Chromium Embedded Framework](https://bitbucket.org/chromiumembedded/cef/)) as a Flutter widget — rendered into a `Texture`, so it composites, transforms, clips, and zooms like any other widget, and **keeps rendering even when off-screen / not focused**. Pointer, scroll, and keyboard input are forwarded; the page cursor drives a `MouseRegion`.

> Status: **experimental, macOS 12+ only** (CEF 144 runtime floor). Real Chromium (any site — JS/CSS/WebGL/video). **Multi-process by default** (GPU `OnAcceleratedPaint` → shared IOSurface, Retina-crisp, renderer/utility crashes isolated, so heavy SPAs like Google sign-in render and survive); `-DCEF_MULTI_PROCESS=OFF` for the simpler single-process build. No mobile (iOS bans third-party engines); desktop by nature.

```dart
import 'package:flutter_cef/flutter_cef.dart';

CefWebView(url: 'https://flutter.dev')
```

Drive and observe it via a controller:

```dart
final c = CefWebController();
CefWebView(url: startUrl, controller: c);

// navigation + history
c.navigate('https://example.com');
c.reload(); c.goBack(); c.goForward();
c.executeJavaScript('document.body.style.zoom = 1.2');

// page state (all ValueListenables) + callbacks
ValueListenableBuilder(valueListenable: c.title, builder: (_, t, __) => Text('$t'));
c.isLoading;  c.url;  c.canGoBack;  c.canGoForward;
c.onLoadError = (e) => print('${e.errorCode} ${e.url}');
c.onConsoleMessage = (m) => print(m.message);
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
GPU `OnAcceleratedPaint` → shared IOSurface, heavy SPAs render + survive),
pointer/scroll/keyboard input, `<select>` popups, page cursor, navigation +
history, loading/title/url/error/console events, `executeJavaScript`.

Next:

- **Drop the Mach-port validation env-var crutch.** Multi-process renders today
  by setting `MACH_PORT_RENDEZVOUS_PEER_VALDATION=0` (Chromium's typo) so the
  process tree skips Chromium 144's peer validation — that env var is
  transitional and will be removed upstream. The durable fix is **correct
  inside-out Developer-ID signing** (`--timestamp`, no `get-task-allow`, sign
  every Mach-O depth-first) — that's how OBS/JCEF satisfy the same validation
  with no flag. Then notarize for distribution.
- **`evaluateJavaScript`** (V8 round-trip return value), IME/composition
  (CJK/emoji), dialogs, downloads, context menus, find, zoom, cookies, devtools.
- **Windows / Linux** — the federated structure is ready; each needs its own host
  + shared-texture path.

## Credits

Built on [CEF](https://bitbucket.org/chromiumembedded/cef/). Patterns drawn from CEF's `cefclient` OSR sample, [JCEF](https://github.com/chromiumembedded/java-cef), and [CefSharp](https://github.com/cefsharp/CefSharp).
