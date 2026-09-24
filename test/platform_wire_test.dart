import 'package:flutter/services.dart';
import 'package:flutter_cef_platform_interface/flutter_cef_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

// FlutterCefPlatform's typed methods are the method-channel protocol the
// native plugins implement. This pins each one to its exact wire call, so a
// rename or a changed argument shows up here, not as a silently ignored call.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(FlutterCefPlatform.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final platform = MethodChannelFlutterCef();
  final log = <MethodCall>[];

  setUp(() => messenger.setMockMethodCallHandler(channel, (call) async {
        log.add(call);
        return null;
      }));
  tearDown(() {
    log.clear();
    messenger.setMockMethodCallHandler(channel, null);
  });

  const s = 'sid';
  final cases = <String, (Future<Object?> Function(), String, Map)>{
    'create': (
      () => platform.create(s,
          url: 'https://a.test/',
          width: 10,
          height: 20,
          dpr: 2,
          authoredHtml: '<p>',
          allowedSchemes: 'https',
          enableCdp: true,
          agentControl: true,
          profile: 'p',
          hostGroup: 'g',
          documentStartScripts: ['1'],
          channels: ['ch']),
      'create',
      {
        'url': 'https://a.test/',
        'authoredHtml': '<p>',
        'width': 10,
        'height': 20,
        'dpr': 2.0,
        'allowedSchemes': 'https',
        'enableCdp': true,
        'agentControl': true,
        'profile': 'p',
        'hostGroup': 'g',
        'documentStartScripts': ['1'],
        'channels': ['ch'],
      },
    ),
    'create (minimal)': (
      () => platform.create(s, url: 'about:blank', width: 1, height: 1, dpr: 1),
      'create',
      {'url': 'about:blank', 'width': 1, 'height': 1, 'dpr': 1.0},
    ),
    'dispose': (() => platform.dispose(s), 'dispose', {}),
    'freezeSession': (() => platform.freezeSession(s), 'freezeSession', {}),
    'thawSession': (
      () => platform.thawSession(s, url: 'u'),
      'thawSession',
      {'url': 'u'}
    ),
    'setVisible': (
      () => platform.setVisible(s, false),
      'setVisible',
      {'visible': false}
    ),
    'resize': (
      () => platform.resize(s, 3, 4, 1.5),
      'resize',
      {'width': 3, 'height': 4, 'dpr': 1.5}
    ),
    'setFrameInterval': (
      () => platform.setFrameInterval(s, 33),
      'setFrameInterval',
      {'ms': 33}
    ),
    'setAudioMuted': (
      () => platform.setAudioMuted(s, true),
      'setAudioMuted',
      {'muted': true}
    ),
    'sessionStats': (() => platform.sessionStats(s), 'sessionStats', {}),
    'getFrameSurface': (
      () => platform.getFrameSurface(s),
      'getFrameSurface',
      {}
    ),
    'navigate': (
      () => platform.navigate(s, 'https://a.test/'),
      'navigate',
      {'url': 'https://a.test/'}
    ),
    'loadTrusted': (
      () => platform.loadTrusted(s, 'data:,'),
      'loadTrusted',
      {'url': 'data:,'}
    ),
    'loadAuthored': (
      () => platform.loadAuthored(s, 'https://a.test/', '<p>'),
      'loadAuthored',
      {'url': 'https://a.test/', 'html': '<p>'}
    ),
    'reload': (() => platform.reload(s), 'reload', {}),
    'stop': (() => platform.stop(s), 'stop', {}),
    'goBack': (() => platform.goBack(s), 'goBack', {}),
    'goForward': (() => platform.goForward(s), 'goForward', {}),
    'setZoomLevel': (
      () => platform.setZoomLevel(s, 1),
      'setZoomLevel',
      {'level': 1.0}
    ),
    'find': (
      () => platform.find(s, 'x',
          forward: false, matchCase: true, findNext: true),
      'find',
      {'text': 'x', 'forward': false, 'matchCase': true, 'findNext': true}
    ),
    'stopFind': (
      () => platform.stopFind(s, clearSelection: false),
      'stopFind',
      {'clearSelection': false}
    ),
    'openAuthWindow': (
      () => platform.openAuthWindow(s, 'https://a.test/'),
      'openAuthWindow',
      {'url': 'https://a.test/'}
    ),
    'showDevTools': (
      () => platform.showDevTools(s, inspectX: 1, inspectY: 2),
      'showDevTools',
      {'inspectX': 1, 'inspectY': 2}
    ),
    'executeJavaScript': (
      () => platform.executeJavaScript(s, '1'),
      'executeJavaScript',
      {'code': '1'}
    ),
    'evalReturning': (
      () => platform.evalReturning(s, 5, '1'),
      'evalReturning',
      {'id': 5, 'code': '1'}
    ),
    'addJavaScriptChannel': (
      () => platform.addJavaScriptChannel(s, 'ch'),
      'addJavaScriptChannel',
      {'name': 'ch'}
    ),
    'respondJsDialog': (
      () => platform.respondJsDialog(s, 3, true, 't'),
      'respondJsDialog',
      {'id': 3, 'ok': true, 'text': 't'}
    ),
    'chooseContextMenu': (
      () => platform.chooseContextMenu(s, 3, 7),
      'chooseContextMenu',
      {'id': 3, 'commandId': 7}
    ),
    'respondMediaRequest': (
      () => platform.respondMediaRequest(s, 3, allow: true, remember: false),
      'respondMediaRequest',
      {'id': 3, 'allow': true, 'remember': false}
    ),
    'setMediaSetting': (
      () => platform.setMediaSetting(s, CefMediaSetting.block),
      'setMediaSetting',
      {'value': 2}
    ),
    'setCookie': (
      () => platform.setCookie(s,
          url: 'u',
          name: 'n',
          value: 'v',
          domain: 'd',
          path: '/',
          secure: true,
          httpOnly: true,
          sameSite: CefCookieSameSite.none),
      'setCookie',
      {
        'url': 'u',
        'name': 'n',
        'value': 'v',
        'domain': 'd',
        'path': '/',
        'secure': true,
        'httpOnly': true,
        'sameSite': 'none',
      }
    ),
    'clearCookies': (() => platform.clearCookies(s), 'clearCookies', {}),
    'visitCookies': (
      () => platform.visitCookies(s, 4, ''),
      'visitCookies',
      {'id': 4, 'url': ''}
    ),
    'deleteCookie': (
      () => platform.deleteCookie(s, 'u', 'n'),
      'deleteCookie',
      {'url': 'u', 'name': 'n'}
    ),
    'pointer': (
      () => platform.pointer(s,
          type: 1,
          button: 2,
          clickCount: 1,
          modifiers: 0,
          x: 1,
          y: 2,
          dx: 0,
          dy: 0),
      'pointer',
      {
        'type': 1,
        'button': 2,
        'clickCount': 1,
        'modifiers': 0,
        'x': 1.0,
        'y': 2.0,
        'dx': 0.0,
        'dy': 0.0,
      }
    ),
    'key': (
      () => platform.key(s,
          type: 0,
          modifiers: 1,
          windowsKeyCode: 65,
          nativeKeyCode: 0,
          character: 97),
      'key',
      {
        'type': 0,
        'modifiers': 1,
        'windowsKeyCode': 65,
        'nativeKeyCode': 0,
        'character': 97,
      }
    ),
    'editCommand': (
      () => platform.editCommand(s, 3),
      'editCommand',
      {'command': 3}
    ),
    'imeSetComposition': (
      () => platform.imeSetComposition(s, 'か'),
      'imeSetComposition',
      {'text': 'か'}
    ),
    'imeCommitText': (
      () => platform.imeCommitText(s, 'か'),
      'imeCommitText',
      {'text': 'か'}
    ),
    'imeCancelComposition': (
      () => platform.imeCancelComposition(s),
      'imeCancelComposition',
      {}
    ),
    'showEmojiPicker': (
      () => platform.showEmojiPicker(s),
      'showEmojiPicker',
      {}
    ),
    'enableAgentControl': (
      () => platform.enableAgentControl(s),
      'enableAgentControl',
      {}
    ),
    'disableAgentControl': (
      () => platform.disableAgentControl(s),
      'disableAgentControl',
      {}
    ),
  };

  cases.forEach((name, c) {
    final (call, method, args) = c;
    test(name, () async {
      await call();
      expect(log, hasLength(1));
      expect(log.single.method, method);
      expect(log.single.arguments, {'sessionId': s, ...args});
    });
  });

  test('events reach the handler with their session id', () async {
    final got = <(String, String, Map<String, dynamic>)>[];
    platform.setEventHandler((id, event, args) => got.add((id, event, args)));
    await messenger.handlePlatformMessage(
      FlutterCefPlatform.channelName,
      const StandardMethodCodec().encodeMethodCall(
          const MethodCall('url', {'sessionId': 'e', 'url': 'u'})),
      (_) {},
    );
    // An event without a session id is dropped.
    await messenger.handlePlatformMessage(
      FlutterCefPlatform.channelName,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('url', {})),
      (_) {},
    );
    expect(got, hasLength(1));
    expect(got.single.$1, 'e');
    expect(got.single.$2, 'url');
    expect(got.single.$3['url'], 'u');
  });
}
