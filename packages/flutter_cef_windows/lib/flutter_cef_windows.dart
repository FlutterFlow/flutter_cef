import 'package:flutter_cef_platform_interface/flutter_cef_platform_interface.dart';

/// The Windows implementation of `flutter_cef`.
///
/// The Windows plugin is native-only: the C++ `FlutterCefPlugin` (see
/// `windows/`) spawns and talks to a per-profile `cef_host` subprocess over a
/// named-pipe IPC and answers the `flutter_cef` method channel. This Dart
/// class exists only to **endorse** the default method-channel platform
/// instance at registration time; there is no Windows-specific Dart behavior.
///
/// Registered via `dartPluginClass: FlutterCefWindows` in this package's
/// pubspec — the Flutter tool calls [registerWith] during plugin registration.
class FlutterCefWindows {
  /// Sets the [FlutterCefPlatform] instance to the method-channel
  /// implementation (the contract the native Windows plugin speaks).
  static void registerWith() {
    FlutterCefPlatform.instance = MethodChannelFlutterCef();
  }
}
