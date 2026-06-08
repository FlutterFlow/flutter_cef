// Integration smoke test: a CefWebView mounts and asks the host to create a
// session. The host channel is mocked so this runs without a built cef_host.app
// (real end-to-end rendering is verified by running the example app).

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:flutter_cef/flutter_cef.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('CefWebView requests a host session', (tester) async {
    const channel = MethodChannel('flutter_cef');
    final calls = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'create') {
        return <String, dynamic>{'textureId': 1, 'width': 320, 'height': 240};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(
      const Center(
        child: SizedBox(
          width: 320,
          height: 240,
          child: CefWebView(url: 'about:blank'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(calls, contains('create'));
  });
}
