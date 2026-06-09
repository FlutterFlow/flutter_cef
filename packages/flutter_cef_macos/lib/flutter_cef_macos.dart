import 'package:flutter_cef_platform_interface/flutter_cef_platform_interface.dart';

/// The macOS implementation of `flutter_cef`.
///
/// The macOS plugin is native-only: the Swift `FlutterCefPlugin` (see
/// `macos/Classes/`) spawns and talks to a per-view `cef_host` subprocess over
/// the `flutter_cef` method channel. This Dart class exists only to **endorse**
/// the default method-channel platform instance at registration time; there is
/// no macOS-specific Dart behavior.
///
/// Registered via `dartPluginClass: FlutterCefMacos` in this package's pubspec —
/// the Flutter tool calls [registerWith] during plugin registration.
class FlutterCefMacos {
  /// Sets the [FlutterCefPlatform] instance to the method-channel
  /// implementation (the contract the native macOS plugin speaks).
  static void registerWith() {
    FlutterCefPlatform.instance = MethodChannelFlutterCef();
  }
}
