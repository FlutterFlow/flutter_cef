// Smoke test for the example app: the browser chrome (URL bar + Go) renders.
// The host channel is mocked so CefWebView's create() resolves without a real
// cef_host subprocess.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_cef_example/main.dart';

void main() {
  const channel = MethodChannel('flutter_cef');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'create') {
        return <String, dynamic>{'textureId': 1, 'width': 320, 'height': 240};
      }
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  testWidgets('shows the URL bar and Go button', (tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump(); // let the post-frame create() resolve

    expect(find.text('Go'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });
}
