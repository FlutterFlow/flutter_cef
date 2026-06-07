import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'flutter_cef_method_channel.dart';

abstract class FlutterCefPlatform extends PlatformInterface {
  /// Constructs a FlutterCefPlatform.
  FlutterCefPlatform() : super(token: _token);

  static final Object _token = Object();

  static FlutterCefPlatform _instance = MethodChannelFlutterCef();

  /// The default instance of [FlutterCefPlatform] to use.
  ///
  /// Defaults to [MethodChannelFlutterCef].
  static FlutterCefPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [FlutterCefPlatform] when
  /// they register themselves.
  static set instance(FlutterCefPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
