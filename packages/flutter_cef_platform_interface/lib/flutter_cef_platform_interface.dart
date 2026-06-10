/// The common platform interface for the `flutter_cef` plugin.
///
/// Holds the shared Dart types ([CefCookie], [CefLoadError], input mappings,
/// …) and the [FlutterCefPlatform] contract that each platform implementation
/// (macOS, and future Windows / Linux) speaks. App-facing code depends on
/// `package:flutter_cef/flutter_cef.dart`, which re-exports the types here.
library;

export 'src/cef_events.dart';
export 'src/cef_input.dart';
export 'src/flutter_cef_platform.dart';
export 'src/method_channel_flutter_cef.dart';
