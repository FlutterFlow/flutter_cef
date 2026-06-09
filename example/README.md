# flutter_cef example

A small browser built on `CefWebView` + `CefWebController`: URL bar,
back/forward/reload, loading bar, live page title, content zoom, JS eval,
a cookies dump, DevTools, and the emoji picker — a manual test bed for every
input path (typing, CJK composition, ⌃⌘Space, trackpad scrolling).

## Run it

CEF (~200 MB) is fetched, not vendored — build the renderer once, point the
plugin at it, then run:

```sh
cd ../packages/flutter_cef_macos          # the macOS implementation package
native/build_cef_host.sh                  # fetches CEF + builds cef_host.app (one-time)
export FLUTTER_CEF_HOST="$PWD/native/cef_host/build/cef_host.app/Contents/MacOS/cef_host"
cd ../../example && flutter run -d macos
```

Without `FLUTTER_CEF_HOST` (or a bundled `cef_host.app` — see the root
README's "Bundling into a distributable app"), the view stays on its
placeholder: the plugin has no renderer to spawn.

macOS only. The Runner is not App-Sandboxed and carries the CEF-required
entitlements (`disable-library-validation`, JIT) — see
`macos/Runner/*.entitlements` for the reference set.
