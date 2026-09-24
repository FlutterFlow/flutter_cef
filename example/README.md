# flutter_cef example

A small browser built on `CefWebView` + `CefWebController`: URL bar,
back/forward/reload, loading bar, live page title, content zoom, JS eval,
a cookies dump, DevTools, and the emoji picker — a manual test bed for every
input path (typing, CJK composition, ⌃⌘Space, trackpad scrolling).

## Run it

```sh
flutter run -d macos     # or: flutter run -d windows
```

On macOS, `pod install` fetches the prebuilt `cef_host.app` published for this
checkout's native sources. If none is published (you changed the native code,
or main is ahead of the last release), build the renderer yourself and point
the plugin at it:

```sh
cd ../packages/flutter_cef_macos
FLUTTER_CEF_STOCK_FRAMEWORK=1 native/build_cef_host.sh   # fetches CEF + builds cef_host.app
export FLUTTER_CEF_HOST="$PWD/native/cef_host/build/cef_host.app/Contents/MacOS/cef_host"
cd ../../example && flutter run -d macos
```

Without a `cef_host`, the view stays on its placeholder. On Windows, `flutter
build windows` fetches CEF and builds `cef_host` itself.

The macOS Runner is not App-Sandboxed and carries the CEF-required
entitlements (`disable-library-validation`, JIT); see
`macos/Runner/*.entitlements` for the reference set.

## Probes

`lib/*_probe.dart` are self-running regression checks against a real
`cef_host`. Each is built as the app's entry point and prints
`CEF_PROBE_RESULT PASS|FAIL`; see [CONTRIBUTING](../CONTRIBUTING.md) for how
to run them.
