# flutter_cef_platform_interface

The common platform interface for the
[`flutter_cef`](https://github.com/FlutterFlow/flutter_cef) plugin.

It holds the shared Dart types (`CefCookie`, `CefLoadError`, the input
mappings, …) and the `FlutterCefPlatform` contract that each platform
implementation (macOS today, Windows / Linux later) speaks. The cross-platform
contract is the method-channel protocol — see
[`PORTING.md`](https://github.com/FlutterFlow/flutter_cef/blob/main/PORTING.md).

App developers should depend on `flutter_cef`, not this package directly. A new
platform implementation depends on this package and endorses the default
method-channel instance from its `registerWith`.
