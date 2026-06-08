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

  Widget boxed(Widget child, {double w = 320, double h = 240}) =>
      Directionality(
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

  // ── IME / text input ───────────────────────────────────────────────
  Future<FocusNode> focusedView(WidgetTester tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester
        .pumpWidget(boxed(CefWebView(url: 'about:blank', focusNode: focus)));
    await tester.pumpAndSettle(); // session create resolves
    focus.requestFocus();
    await tester.pump(); // focus listener attaches the text-input connection
    return focus;
  }

  testWidgets('opens a delta text-input connection when focused',
      (tester) async {
    await focusedView(tester);
    final args = tester.testTextInput.setClientArgs;
    expect(args, isNotNull);
    expect(args!['enableDeltaModel'], isTrue);
    expect((args['inputType'] as Map)['name'], 'TextInputType.text');
  });

  testWidgets(
      'seeds the connection with a valid caret (CJK composition needs '
      'a real insertion point, not the -1 of TextEditingValue.empty)',
      (tester) async {
    await focusedView(tester);
    final state = tester.testTextInput.editingState;
    expect(state, isNotNull);
    expect(state!['selectionBase'], 0);
    expect(state['selectionExtent'], 0);
  });

  testWidgets(
      'composition relays to imeSetComposition, commit to imeCommitText',
      (tester) async {
    await focusedView(tester);
    // Marked (composing) text — the in-progress, underlined region.
    tester.testTextInput.updateEditingValue(const TextEditingValue(
      text: 'ni',
      selection: TextSelection.collapsed(offset: 2),
      composing: TextRange(start: 0, end: 2),
    ));
    await tester.pump();
    expect((callsTo('imeSetComposition').last.arguments as Map)['text'], 'ni');
    expect(callsTo('imeCommitText'), isEmpty);

    // The IME resolves it to the committed characters (composing collapsed).
    tester.testTextInput.updateEditingValue(const TextEditingValue(text: '你好'));
    await tester.pump();
    expect((callsTo('imeCommitText').last.arguments as Map)['text'], '你好');
  });

  testWidgets('emoji commits as the whole string (no surrogate truncation)',
      (tester) async {
    await focusedView(tester);
    tester.testTextInput.updateEditingValue(const TextEditingValue(text: '🎉'));
    await tester.pump();
    final committed =
        (callsTo('imeCommitText').last.arguments as Map)['text'] as String;
    expect(committed, '🎉');
    expect(committed.runes.length, 1); // a single rune, not a half-pair
  });

  testWidgets('closes the text-input connection when unfocused',
      (tester) async {
    final focus = await focusedView(tester);
    expect(tester.testTextInput.setClientArgs, isNotNull);
    focus.unfocus();
    await tester.pump();
    expect(tester.testTextInput.hasAnyClients, isFalse);
  });

  testWidgets(
      '⌃⌘Space is not forwarded to the page so the emoji picker can '
      'fall through to the platform', (tester) async {
    await focusedView(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    log.clear(); // ignore the modifier key-downs themselves
    // ⌃⌘Space must NOT reach the page (no 'key' send) — it has to fall through
    // to the platform input context, which opens the emoji & symbols picker.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(callsTo('key'), isEmpty);

    // Contrast: a plain key IS forwarded to the page, proving the harness sees
    // 'key' sends at all.
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    log.clear();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    expect(callsTo('key'), isNotEmpty);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
  });
}
