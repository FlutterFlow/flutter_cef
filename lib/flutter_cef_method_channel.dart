import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'flutter_cef_platform_interface.dart';

/// An implementation of [FlutterCefPlatform] that uses method channels.
class MethodChannelFlutterCef extends FlutterCefPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('flutter_cef');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }
}
