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
    final id =
        await c.create(url: 'https://example.com', width: 100, height: 80);
    expect(id, 7);
    expect(c.textureId, 7);
    final args = (log.firstWhere((m) => m.method == 'create').arguments as Map)
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
    expect(
        log.map((m) => m.method),
        containsAll(
            ['reload', 'stop', 'goBack', 'goForward', 'executeJavaScript']));
    for (final m in log) {
      expect((m.arguments as Map)['sessionId'], 'nav');
    }
    expect(
        (log.firstWhere((m) => m.method == 'executeJavaScript').arguments
            as Map)['code'],
        '1+1');
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
    await emit('le', 'loadError', {
      'code': -105,
      'url': 'https://bad.test/',
      'text': 'ERR_NAME_NOT_RESOLVED'
    });
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
    await emit(
        'cm', 'consoleMessage', {'level': 4, 'message': 'app.js:3\tboom'});
    expect(got!.level, 4);
    expect(got!.message, 'app.js:3\tboom');
  });

  test('page lifecycle events invoke their callbacks', () async {
    final c = CefWebController(sessionId: 'pl');
    await c.create(url: 'about:blank', width: 1, height: 1);
    final events = <String>[];
    c.onPageStarted = (u) => events.add('start:$u');
    c.onPageFinished = (u) => events.add('finish:$u');
    c.onProgress = (p) => events.add('progress:$p');
    c.onUrlChange = (u) => events.add('urlChange:$u');
    await emit('pl', 'pageStarted', {'url': 'https://a.test/'});
    await emit('pl', 'progress', {'progress': 42});
    await emit('pl', 'url', {'url': 'https://a.test/page'});
    await emit('pl', 'pageFinished', {'url': 'https://a.test/'});
    expect(events, [
      'start:https://a.test/',
      'progress:42',
      'urlChange:https://a.test/page',
      'finish:https://a.test/',
    ]);
    // The url event still drives the notifier too.
    expect(c.url.value, 'https://a.test/page');
  });

  test('newWindow event routes the popup url to onCreateWindow', () async {
    final c = CefWebController(sessionId: 'nw');
    await c.create(url: 'about:blank', width: 1, height: 1);
    String? opened;
    c.onCreateWindow = (u) => opened = u;
    await emit('nw', 'newWindow', {'url': 'https://popup.test/'});
    expect(opened, 'https://popup.test/');
  });

  test('zoom + find + load verbs are forwarded', () async {
    final c = CefWebController(sessionId: 'b2');
    await c.setZoomLevel(1.0);
    await c.find('hello', forward: false, matchCase: true);
    await c.stopFind();
    await c.loadHtmlString('<h1>hi</h1>');
    await c.loadFile('/tmp/x.html');
    final zoom =
        log.firstWhere((m) => m.method == 'setZoomLevel').arguments as Map;
    expect(zoom['level'], 1.0);
    final find = log.firstWhere((m) => m.method == 'find').arguments as Map;
    expect(find['text'], 'hello');
    expect(find['forward'], false);
    expect(find['matchCase'], true);
    expect(log.any((m) => m.method == 'stopFind'), true);
    // loadHtmlString + loadFile route through navigate with data:/file: urls.
    final navs = log
        .where((m) => m.method == 'navigate')
        .map((m) => (m.arguments as Map)['url'] as String)
        .toList();
    expect(navs.any((u) => u.startsWith('data:text/html')), true);
    expect(navs, contains('file:///tmp/x.html'));
  });

  test('findResult event invokes onFindResult', () async {
    final c = CefWebController(sessionId: 'fr');
    await c.create(url: 'about:blank', width: 1, height: 1);
    CefFindResult? got;
    c.onFindResult = (r) => got = r;
    await emit('fr', 'findResult',
        {'count': 5, 'activeMatchOrdinal': 2, 'isFinal': true});
    expect(got!.numberOfMatches, 5);
    expect(got!.activeMatchOrdinal, 2);
    expect(got!.isFinalUpdate, true);
  });

  test('confirm dialog routes to the handler and responds', () async {
    final c = CefWebController(sessionId: 'jd');
    await c.create(url: 'about:blank', width: 1, height: 1);
    c.onJavaScriptConfirmDialog = (req) async => false;
    await emit('jd', 'jsDialog',
        {'id': 11, 'type': 1, 'message': 'sure?', 'defaultText': ''});
    await pumpEventQueue();
    final resp =
        log.firstWhere((m) => m.method == 'respondJsDialog').arguments as Map;
    expect(resp['id'], 11);
    expect(resp['ok'], false);
  });

  test('prompt dialog returns entered text via respondJsDialog', () async {
    final c = CefWebController(sessionId: 'jp');
    await c.create(url: 'about:blank', width: 1, height: 1);
    c.onJavaScriptTextInputDialog = (req) async => 'typed-${req.defaultText}';
    await emit('jp', 'jsDialog',
        {'id': 12, 'type': 2, 'message': 'name?', 'defaultText': 'x'});
    await pumpEventQueue();
    final resp =
        log.firstWhere((m) => m.method == 'respondJsDialog').arguments as Map;
    expect(resp['ok'], true);
    expect(resp['text'], 'typed-x');
  });

  test('runJavaScriptReturningResult resolves from an evalResult event',
      () async {
    final c = CefWebController(sessionId: 'ev');
    await c.create(url: 'about:blank', width: 1, height: 1);
    final future = c.runJavaScriptReturningResult('1+1');
    final call =
        log.firstWhere((m) => m.method == 'evalReturning').arguments as Map;
    expect(call['code'], '1+1');
    await emit(
        'ev', 'evalResult', {'payload': '${call['id']}:{"ok":true,"v":2}'});
    expect(await future, 2);
  });

  test('runJavaScriptReturningResult surfaces script errors', () async {
    final c = CefWebController(sessionId: 'ee');
    await c.create(url: 'about:blank', width: 1, height: 1);
    final future = c.runJavaScriptReturningResult('boom()');
    final id = (log.firstWhere((m) => m.method == 'evalReturning').arguments
        as Map)['id'];
    // Attach the matcher before the error is delivered (else the errored future
    // is briefly unhandled).
    final expectation = expectLater(future, throwsA(isA<Exception>()));
    await emit('ee', 'evalResult',
        {'payload': '$id:{"ok":false,"v":"ReferenceError"}'});
    await expectation;
  });

  test('addJavaScriptChannel delivers channel messages', () async {
    final c = CefWebController(sessionId: 'ch');
    await c.create(url: 'about:blank', width: 1, height: 1);
    String? got;
    await c.addJavaScriptChannel('Native', onMessageReceived: (m) => got = m);
    final call = log
        .firstWhere((m) => m.method == 'addJavaScriptChannel')
        .arguments as Map;
    expect(call['name'], 'Native');
    await emit('ch', 'channelMessage', {'payload': 'Native:hello world'});
    expect(got, 'hello world');
  });

  test('scroll + storage conveniences forward as JavaScript', () async {
    final c = CefWebController(sessionId: 'sc');
    await c.scrollTo(0, 100);
    await c.scrollBy(5, 6);
    await c.clearLocalStorage();
    final js = log
        .where((m) => m.method == 'executeJavaScript')
        .map((m) => (m.arguments as Map)['code'] as String)
        .toList();
    expect(js, contains('window.scrollTo(0, 100)'));
    expect(js, contains('window.scrollBy(5, 6)'));
    expect(js, contains('localStorage.clear()'));
  });

  test('getScrollPosition decodes the eval result into an Offset', () async {
    final c = CefWebController(sessionId: 'gp');
    await c.create(url: 'about:blank', width: 1, height: 1);
    final f = c.getScrollPosition();
    final id = (log.firstWhere((m) => m.method == 'evalReturning').arguments
        as Map)['id'];
    await emit('gp', 'evalResult', {'payload': '$id:{"ok":true,"v":[12,34]}'});
    expect(await f, const Offset(12, 34));
  });

  test('IME verbs forward to native', () async {
    final c = CefWebController(sessionId: 'im');
    await c.imeSetComposition('文');
    await c.imeCommitText('文字');
    await c.imeCancelComposition();
    expect(
        (log.firstWhere((m) => m.method == 'imeSetComposition').arguments
            as Map)['text'],
        '文');
    expect(
        (log.firstWhere((m) => m.method == 'imeCommitText').arguments
            as Map)['text'],
        '文字');
    expect(log.any((m) => m.method == 'imeCancelComposition'), true);
  });

  test('a host imeCompositionBounds event fires onImeCompositionBounds',
      () async {
    final c = CefWebController(sessionId: 'imb');
    await c.create(url: 'about:blank', width: 10, height: 10);
    Rect? got;
    c.onImeCompositionBounds = (r) => got = r;
    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(const MethodCall('imeCompositionBounds',
          {'sessionId': 'imb', 'x': 12, 'y': 34, 'w': 2, 'h': 18})),
      (_) {},
    );
    expect(got, const Rect.fromLTWH(12, 34, 2, 18));
    await c.dispose();
  });

  test('download event invokes onDownload', () async {
    final c = CefWebController(sessionId: 'dl');
    await c.create(url: 'about:blank', width: 1, height: 1);
    String? got;
    c.onDownload = (n) => got = n;
    await emit('dl', 'download', {'suggestedName': 'file.zip'});
    expect(got, 'file.zip');
  });

  test('dispose fails pending evals and ignores later events', () async {
    final c = CefWebController(sessionId: 'dp');
    await c.create(url: 'about:blank', width: 1, height: 1);
    final f = c.runJavaScriptReturningResult('x');
    final exp = expectLater(f, throwsA(isA<StateError>()));
    await c.dispose();
    await exp;
    var called = false;
    c.onPageStarted = (_) => called = true;
    await emit('dp', 'pageStarted', {'url': 'https://late.test/'});
    expect(called, false, reason: 'events after dispose must be ignored');
  });

  test('alert dialog routes to the handler and acks', () async {
    final c = CefWebController(sessionId: 'al');
    await c.create(url: 'about:blank', width: 1, height: 1);
    String? msg;
    c.onJavaScriptAlertDialog = (req) async {
      msg = req.message;
    };
    await emit('al', 'jsDialog',
        {'id': 7, 'type': 0, 'message': 'hi', 'defaultText': ''});
    await pumpEventQueue();
    expect(msg, 'hi');
    final resp =
        log.firstWhere((m) => m.method == 'respondJsDialog').arguments as Map;
    expect(resp['ok'], true);
  });

  test('addJavaScriptChannel rejects a non-identifier name', () {
    final c = CefWebController(sessionId: 'cv');
    expect(
        () =>
            c.addJavaScriptChannel("x'];alert(1)//", onMessageReceived: (_) {}),
        throwsArgumentError);
  });

  test('cookie verbs forward to native', () async {
    final c = CefWebController(sessionId: 'ck');
    await c.setCookie(
        url: 'https://x.test/', name: 'sid', value: 'abc', domain: 'x.test');
    await c.clearCookies();
    final set = log.firstWhere((m) => m.method == 'setCookie').arguments as Map;
    expect(set['name'], 'sid');
    expect(set['value'], 'abc');
    expect(set['domain'], 'x.test');
    expect(log.any((m) => m.method == 'clearCookies'), true);
  });

  test('getCookies resolves from a host cookies event', () async {
    final c = CefWebController(sessionId: 'ckr');
    await c.create(url: 'about:blank', width: 1, height: 1);
    final future = c.getCookies(url: 'https://x.test/');
    final visit =
        log.firstWhere((m) => m.method == 'visitCookies').arguments as Map;
    expect(visit['url'], 'https://x.test/');
    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(MethodCall('cookies', {
        'sessionId': 'ckr',
        'id': visit['id'],
        'json': '[{"name":"sid","value":"abc","domain":"x.test","path":"/",'
            '"secure":true,"httpOnly":false}]',
      })),
      (_) {},
    );
    final cookies = await future;
    expect(cookies, hasLength(1));
    expect(cookies.single.name, 'sid');
    expect(cookies.single.value, 'abc');
    expect(cookies.single.secure, isTrue);
    await c.dispose();
  });

  test('deleteCookie + openDevTools forward to native', () async {
    final c = CefWebController(sessionId: 'ckd');
    await c.deleteCookie(url: 'https://x.test/', name: 'sid');
    await c.openDevTools();
    final del =
        log.firstWhere((m) => m.method == 'deleteCookie').arguments as Map;
    expect(del['url'], 'https://x.test/');
    expect(del['name'], 'sid');
    expect(log.any((m) => m.method == 'showDevTools'), isTrue);
  });

  test('showEmojiPicker forwards to native', () async {
    final c = CefWebController(sessionId: 'emo');
    await c.showEmojiPicker();
    final m = log.firstWhere((m) => m.method == 'showEmojiPicker');
    expect((m.arguments as Map)['sessionId'], 'emo');
  });
}
