import 'package:flutter/services.dart';

import 'flutter_cef_platform.dart';

/// The default [FlutterCefPlatform] implementation: a plain [MethodChannel]
/// named [FlutterCefPlatform.channelName].
///
/// This works for any platform whose native plugin speaks the channel protocol
/// (macOS today, Windows / Linux later), so most platform implementations need
/// no Dart-side override — they just provide the native plugin and endorse this
/// default instance from their `registerWith`.
class MethodChannelFlutterCef extends FlutterCefPlatform {
  final MethodChannel _channel =
      const MethodChannel(FlutterCefPlatform.channelName);

  @override
  MethodChannel get channel => _channel;
}
