import 'package:flutter/services.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'method_channel_flutter_cef.dart';

/// The interface that platform-specific implementations of `flutter_cef` must
/// implement to be endorsed (macOS today; Windows / Linux down the line).
///
/// The cross-platform contract is the **method-channel protocol**: every
/// platform exposes a [MethodChannel] named [channelName] over which the
/// app-facing `CefWebController` drives a per-view `cef_host` subprocess
/// (create / navigate / input / dispose) and receives page events. The native
/// side of each platform plugin implements that protocol; the Dart side is
/// usually just this endorsement (see the default [MethodChannelFlutterCef]).
///
/// A platform plugin registers by setting [instance] from its `registerWith`
/// (wired via `dartPluginClass` in the implementation package's pubspec).
abstract class FlutterCefPlatform extends PlatformInterface {
  /// Constructs a [FlutterCefPlatform].
  FlutterCefPlatform() : super(token: _token);

  static final Object _token = Object();

  static FlutterCefPlatform _instance = MethodChannelFlutterCef();

  /// The default instance to use — the method-channel implementation, which
  /// works for any platform whose native plugin speaks the [channelName]
  /// protocol (all of them today).
  static FlutterCefPlatform get instance => _instance;

  /// Platform implementations set this in their `registerWith`. The setter
  /// verifies the [PlatformInterface] token to discourage implementations that
  /// `implements` rather than `extends` this class.
  static set instance(FlutterCefPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// The name of the method channel the app-facing code and the native plugin
  /// communicate over. This is the heart of the cross-platform contract — see
  /// `PORTING.md` for the full method + event + IPC-opcode protocol.
  static const String channelName = 'flutter_cef';

  /// The channel the app-facing `CefWebController` talks over. The default
  /// returns `MethodChannel(channelName)`; a platform only overrides this if it
  /// needs a non-standard transport (none do today).
  MethodChannel get channel =>
      throw UnimplementedError('channel has not been implemented.');
}
