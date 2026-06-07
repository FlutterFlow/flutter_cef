import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_cef/flutter_cef.dart';
import 'package:flutter_cef/flutter_cef_platform_interface.dart';
import 'package:flutter_cef/flutter_cef_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockFlutterCefPlatform
    with MockPlatformInterfaceMixin
    implements FlutterCefPlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final FlutterCefPlatform initialPlatform = FlutterCefPlatform.instance;

  test('$MethodChannelFlutterCef is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelFlutterCef>());
  });

  test('getPlatformVersion', () async {
    FlutterCef flutterCefPlugin = FlutterCef();
    MockFlutterCefPlatform fakePlatform = MockFlutterCefPlatform();
    FlutterCefPlatform.instance = fakePlatform;

    expect(await flutterCefPlugin.getPlatformVersion(), '42');
  });
}
