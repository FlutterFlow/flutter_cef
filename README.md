# flutter_cef

Embed a **live Chromium browser** (via the [Chromium Embedded Framework](https://bitbucket.org/chromiumembedded/cef/)) as a Flutter widget — rendered into a `Texture`, so it composites, transforms, clips, and zooms like any other widget, and **keeps rendering even when off-screen / not focused**. Pointer, scroll, and keyboard input are forwarded; the page cursor drives a `MouseRegion`.

> Status: **experimental, macOS only.** Real Chromium (any site — JS/CSS/WebGL/video). Single-process OSR today (simple to sign; see Roadmap for the GPU/multi-process upgrade). No mobile (iOS bans third-party engines); desktop by nature.

```dart
import 'package:flutter_cef/flutter_cef.dart';

CefWebView(url: 'https://flutter.dev')
```

Script it via a controller:

```dart
final controller = CefWebController();
CefWebView(url: startUrl, controller: controller);
// later: controller.navigate('https://example.com');
```

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

For a **distributable** app, `cef_host.app` + the CEF framework must be bundled into your `.app` and signed by your build (the plugin auto-resolves a bundled copy under `Contents/Frameworks`). Your entitlements need at least `com.apple.security.cs.disable-library-validation` (and JIT entitlements under hardened runtime). The build-phase bundling is the next infra item — see Roadmap.

## Roadmap

- **GPU zero-copy** (`OnAcceleratedPaint` → shared IOSurface) instead of the CPU `OnPaint` copy — removes latency/blur. Needs multi-process.
- **Multi-process + signed helpers** (stability; unlocks the GPU path) instead of `--single-process`.
- **JS bridge** (`evaluateJavaScript` + page↔host messaging), IME/composition (CJK/emoji), dialogs, downloads, context menus.
- **Windows / Linux** (the federated structure is ready; each needs its own host + shared-texture path).

## Credits

Built on [CEF](https://bitbucket.org/chromiumembedded/cef/). Patterns drawn from CEF's `cefclient` OSR sample, [JCEF](https://github.com/chromiumembedded/java-cef), and [CefSharp](https://github.com/cefsharp/CefSharp).
