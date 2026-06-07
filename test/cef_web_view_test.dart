import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_cef/flutter_cef.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_cef');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final log = <MethodCall>[];
  late Duration createDelay;

  setUp(() {
    log.clear();
    createDelay = Duration.zero;
    messenger.setMockMethodCallHandler(channel, (call) async {
      log.add(call);
      if (call.method == 'create') {
        if (createDelay > Duration.zero) {
          await Future<void>.delayed(createDelay);
        }
        return <String, dynamic>{'textureId': 1, 'width': 320, 'height': 240};
      }
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Widget boxed(Widget child, {double w = 320, double h = 240}) => Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: SizedBox(width: w, height: h, child: child)),
      );
  List<MethodCall> callsTo(String m) =>
      log.where((c) => c.method == m).toList();

  testWidgets('shows the placeholder until the first texture arrives',
      (tester) async {
    createDelay = const Duration(milliseconds: 50);
    await tester.pumpWidget(boxed(const CefWebView(
      url: 'about:blank',
      placeholder: Text('loading'),
    )));
    expect(find.text('loading'), findsOneWidget);
    expect(find.byType(Texture), findsNothing);

    await tester.pump(const Duration(milliseconds: 100)); // create resolves
    expect(find.byType(Texture), findsOneWidget);
    expect(find.text('loading'), findsNothing);
  });

  testWidgets('creates exactly one session sized to the layout',
      (tester) async {
    await tester.pumpWidget(boxed(const CefWebView(url: 'https://a.test')));
    await tester.pumpAndSettle();
    final creates = callsTo('create');
    expect(creates, hasLength(1));
    final args = (creates.single.arguments as Map).cast<String, dynamic>();
    expect(args['url'], 'https://a.test');
    expect(args['width'], 320);
    expect(args['height'], 240);
  });

  testWidgets('resizes the session when the layout changes', (tester) async {
    const key = ValueKey('v');
    await tester.pumpWidget(
        boxed(const CefWebView(key: key, url: 'about:blank'), w: 320, h: 240));
    await tester.pumpAndSettle();
    await tester.pumpWidget(
        boxed(const CefWebView(key: key, url: 'about:blank'), w: 400, h: 300));
    await tester.pumpAndSettle();
    final resizes = callsTo('resize');
    expect(resizes, isNotEmpty);
    final args = (resizes.last.arguments as Map).cast<String, dynamic>();
    expect(args['width'], 400);
    expect(args['height'], 300);
  });

  testWidgets('navigates when the url property changes', (tester) async {
    const key = ValueKey('v');
    await tester
        .pumpWidget(boxed(const CefWebView(key: key, url: 'https://a.test')));
    await tester.pumpAndSettle();
    await tester
        .pumpWidget(boxed(const CefWebView(key: key, url: 'https://b.test')));
    await tester.pumpAndSettle();
    final navs = callsTo('navigate');
    expect(navs, hasLength(1));
    expect((navs.single.arguments as Map)['url'], 'https://b.test');
  });

  testWidgets('disposes the session it owns when removed', (tester) async {
    await tester.pumpWidget(boxed(const CefWebView(url: 'about:blank')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(boxed(const SizedBox.shrink()));
    await tester.pumpAndSettle();
    expect(callsTo('dispose'), hasLength(1));
  });

  testWidgets('does not dispose an externally-owned controller',
      (tester) async {
    final controller = CefWebController(sessionId: 'ext');
    await tester.pumpWidget(
        boxed(CefWebView(url: 'about:blank', controller: controller)));
    await tester.pumpAndSettle();
    await tester.pumpWidget(boxed(const SizedBox.shrink()));
    await tester.pumpAndSettle();
    expect(callsTo('dispose'), isEmpty); // the view left it alone
    await controller.dispose(); // caller's responsibility
    expect(callsTo('dispose'), hasLength(1));
  });
}
