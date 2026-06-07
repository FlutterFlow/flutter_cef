import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_cef/flutter_cef.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('flutter_cef');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final log = <MethodCall>[];

  setUp(() {
    messenger.setMockMethodCallHandler(channel, (call) async {
      log.add(call);
      if (call.method == 'create') {
        return <String, dynamic>{'textureId': 7, 'width': 100, 'height': 80};
      }
      return null;
    });
  });

  tearDown(() {
    log.clear();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('create returns the host texture id and forwards args', () async {
    final c = CefWebController(sessionId: 's1');
    final id = await c.create(url: 'https://example.com', width: 100, height: 80);
    expect(id, 7);
    expect(c.textureId, 7);
    final args =
        (log.firstWhere((m) => m.method == 'create').arguments as Map)
            .cast<String, dynamic>();
    expect(args['sessionId'], 's1');
    expect(args['url'], 'https://example.com');
    expect(args['width'], 100);
  });

  test('navigate forwards the url for this session', () async {
    final c = CefWebController(sessionId: 's2');
    await c.navigate('https://flutter.dev');
    final args =
        (log.firstWhere((m) => m.method == 'navigate').arguments as Map)
            .cast<String, dynamic>();
    expect(args['sessionId'], 's2');
    expect(args['url'], 'https://flutter.dev');
  });

  test('a host cursor event updates the controller cursor', () async {
    final c = CefWebController(sessionId: 's3');
    // create() installs the host->Dart handler and registers the session.
    await c.create(url: 'about:blank', width: 10, height: 10);
    expect(c.cursor.value, SystemMouseCursors.basic);

    // Simulate a host -> Dart cursor event: CT_IBEAM (3) -> text cursor.
    await messenger.handlePlatformMessage(
      'flutter_cef',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('cursor', {'sessionId': 's3', 'cursor': 3}),
      ),
      (_) {},
    );
    expect(c.cursor.value, SystemMouseCursors.text);
  });

  test('session ids are unique when not supplied', () {
    expect(CefWebController().sessionId,
        isNot(equals(CefWebController().sessionId)));
  });

  test('sendPointer clamps clickCount to Chromium-legal 1..3', () async {
    final c = CefWebController(sessionId: 'sp');
    c.sendPointer(type: 1, x: 5, y: 6, clickCount: 9);
    await Future<void>.delayed(Duration.zero);
    final args = (log.firstWhere((m) => m.method == 'pointer').arguments as Map)
        .cast<String, dynamic>();
    expect(args['clickCount'], 3);
  });

  // Simulate a host -> Dart event for [sessionId].
  Future<void> emit(String sessionId, String method, Map<String, Object?> a) {
    return messenger.handlePlatformMessage(
      'flutter_cef',
      const StandardMethodCodec().encodeMethodCall(
        MethodCall(method, {'sessionId': sessionId, ...a}),
      ),
      (_) {},
    );
  }

  test('navigation + script verbs are forwarded for the session', () async {
    final c = CefWebController(sessionId: 'nav');
    await c.reload();
    await c.stop();
    await c.goBack();
    await c.goForward();
    await c.executeJavaScript('1+1');
    expect(log.map((m) => m.method),
        containsAll(['reload', 'stop', 'goBack', 'goForward', 'executeJavaScript']));
    for (final m in log) {
      expect((m.arguments as Map)['sessionId'], 'nav');
    }
    expect((log.firstWhere((m) => m.method == 'executeJavaScript').arguments
        as Map)['code'], '1+1');
  });

  test('loadingState event updates loading + history notifiers', () async {
    final c = CefWebController(sessionId: 'ls');
    await c.create(url: 'about:blank', width: 1, height: 1);
    await emit('ls', 'loadingState',
        {'isLoading': true, 'canGoBack': true, 'canGoForward': false});
    expect(c.isLoading.value, true);
    expect(c.canGoBack.value, true);
    expect(c.canGoForward.value, false);
  });

  test('title + url events update notifiers', () async {
    final c = CefWebController(sessionId: 'tu');
    await c.create(url: 'about:blank', width: 1, height: 1);
    await emit('tu', 'title', {'title': 'Hello'});
    await emit('tu', 'url', {'url': 'https://x.test/'});
    expect(c.title.value, 'Hello');
    expect(c.url.value, 'https://x.test/');
  });

  test('loadError event invokes the callback with a CefLoadError', () async {
    final c = CefWebController(sessionId: 'le');
    await c.create(url: 'about:blank', width: 1, height: 1);
    CefLoadError? got;
    c.onLoadError = (e) => got = e;
    await emit('le', 'loadError',
        {'code': -105, 'url': 'https://bad.test/', 'text': 'ERR_NAME_NOT_RESOLVED'});
    expect(got, isNotNull);
    expect(got!.errorCode, -105);
    expect(got!.url, 'https://bad.test/');
    expect(got!.errorText, 'ERR_NAME_NOT_RESOLVED');
  });

  test('consoleMessage event invokes the callback', () async {
    final c = CefWebController(sessionId: 'cm');
    await c.create(url: 'about:blank', width: 1, height: 1);
    CefConsoleMessage? got;
    c.onConsoleMessage = (m) => got = m;
    await emit('cm', 'consoleMessage', {'level': 4, 'message': 'app.js:3\tboom'});
    expect(got!.level, 4);
    expect(got!.message, 'app.js:3\tboom');
  });
}
