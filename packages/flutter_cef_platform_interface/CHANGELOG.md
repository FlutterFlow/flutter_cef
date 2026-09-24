## Unreleased

* `FlutterCefPlatform` gains a typed method for every method-channel call
  (`create`, `navigate`, `resize`, `pointer`, …) and `setEventHandler` for the
  native events, so the protocol's method names and arguments are written once.
  They go over `channel`, so an implementation that only overrides `channel`
  keeps working.

## 0.1.3

* Initial release of the federated common platform interface for `flutter_cef`:
  the shared Dart types (`cef_events`, `cef_input`) and the `FlutterCefPlatform`
  contract with its default `MethodChannelFlutterCef`. Split out of the
  `flutter_cef` package; no API change for app-facing consumers.
