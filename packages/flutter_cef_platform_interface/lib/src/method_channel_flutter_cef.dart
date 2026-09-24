import 'package:flutter/services.dart';

import 'flutter_cef_platform.dart';

/// The default [FlutterCefPlatform] implementation: a plain [MethodChannel]
/// named [FlutterCefPlatform.channelName].
///
/// This works for any platform whose native plugin speaks the channel protocol
/// (macOS and Windows both do), so a platform implementation needs no Dart-side
/// override: it provides the native plugin and endorses this default instance
/// from its `registerWith`.
class MethodChannelFlutterCef extends FlutterCefPlatform {
  final MethodChannel _channel =
      const MethodChannel(FlutterCefPlatform.channelName);

  @override
  MethodChannel get channel => _channel;
}
