# flutter_cef_macos

The macOS implementation of the
[`flutter_cef`](https://github.com/FlutterFlow/flutter_cef) plugin.

It renders a live Chromium (CEF) browser off-screen in a `cef_host` subprocess
and presents it as a Flutter `Texture`. This is the **endorsed** macOS
implementation, pulled in automatically when you depend on `flutter_cef` — you
should depend on `flutter_cef`, not this package directly.

Native build + bundling lives here (`native/build_cef_host.sh`,
`tool/bundle_cef_host.sh`); see the root
[README](https://github.com/FlutterFlow/flutter_cef#building) for build,
bundling, and signing, and
[`PORTING.md`](https://github.com/FlutterFlow/flutter_cef/blob/main/PORTING.md)
for the platform-seam map.
