import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/contacts/routes.dart';
import 'package:high_eq/features/contacts/scene.dart';
import 'package:high_eq/features/growth/practice_home.dart';
import 'package:high_eq/features/growth/practice_home_actions.dart';
import 'package:high_eq/features/growth/repository.dart';
import 'package:high_eq/features/home/shell.dart';
import 'package:high_eq/features/practice/lobby.dart';
import 'package:high_eq/features/practice/providers.dart';
import 'package:high_eq/features/practice/repository.dart';
import 'package:http/http.dart' as http;

class _VolatileSecret implements SecretStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> replace(String? next) async => value = next;
}

// The real product routes run against the Go test's loopback service. Only
// that socket may be dialled from the card sandbox.
class _T20LiveBinding extends LiveTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

const _networkLimit = Duration(seconds: 60);

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() ready, {
  required String label,
}) async {
  final elapsed = Stopwatch()..start();
  while (elapsed.elapsed < _networkLimit) {
    await tester.pump(const Duration(milliseconds: 20));
    if (ready()) return;
  }
  await tester.pump();
  fail('Timed out waiting for $label. No URL, token or message text is logged.');
}

Future<void> _waitForText(WidgetTester tester, String text) => _waitUntil(
  tester,
  () => find.text(text).evaluate().isNotEmpty,
  label: 'text "$text"',
);

Future<void> _tapVisible(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target.last);
  await tester.pump();
}

Future<void> _tapBack(WidgetTester tester) async {
  final elapsed = Stopwatch()..start();
  while (elapsed.elapsed < const Duration(seconds: 10)) {
    final back = find.byType(BackButton).hitTestable();
    if (back.evaluate().isNotEmpty) {
      expect(back, findsOneWidget);
      await tester.tap(back);
      await tester.pump();
      return;
    }
    await tester.pump(const Duration(milliseconds: 50));
  }
  fail('no hit-testable AppBar back button appeared');
}

// Observable transition state: the pushed page's route animation is done.
Future<void> _waitForRouteSettled(WidgetTester tester, Finder page) async {
  await _waitUntil(
    tester,
    () {
      final elements = page.evaluate();
      if (elements.isEmpty) return false;
      final route = ModalRoute.of(elements.first);
      final animation = route?.animation;
      return route != null && (animation == null || animation.isCompleted);
    },
    label: '${page.describeMatch(Plurality.many)} route transition',
  );
}

Finder _menuScroll() => find
    .descendant(of: find.byType(HomeShell), matching: find.byType(Scrollable))
    .first;

Finder _lobbyScroll() => find
    .descendant(
      of: find.byType(PracticeLobby),
      matching: find.byType(Scrollable),
    )
    .first;

Future<void> _openHistory(WidgetTester tester, String title) async {
  await _waitForText(tester, '对练与预演');
  await _waitForRouteSettled(tester, find.byType(PracticeLobby));
  final target = find.text(title);
  await tester.scrollUntilVisible(
    target,
    300,
    scrollable: _lobbyScroll(),
  );
  await _tapVisible(tester, target);
}

// Reads the comparison line from the rendered Text itself, after scrolling it
// fully into the viewport and checking that it is hit-testable. Both waits use
// observable state: the pushed route's animation completing, then the settlement
// scroll position becoming idle. No fixed delay or blind retry.
Future<Map<String, Object>> _renderedComparison(WidgetTester tester) async {
  final finder = find.byWidgetPredicate(
    (widget) => widget is Text && (widget.data?.contains('上次') ?? false),
  );
  await _waitUntil(
    tester,
    () => finder.evaluate().isNotEmpty,
    label: 'the settlement comparison line',
  );
  final target = finder.first;
  await _waitForRouteSettled(tester, finder);
  await tester.ensureVisible(target);
  await _waitUntil(
    tester,
    () {
      final element = target.evaluate().first;
      final scrollable = Scrollable.maybeOf(element);
      return scrollable == null ||
          !scrollable.position.isScrollingNotifier.value;
    },
    label: 'the settlement scroll position',
  );
  await tester.pump();
  final rect = tester.getRect(target);
  final screen = Offset.zero &
      (tester.view.physicalSize / tester.view.devicePixelRatio);
  final inside =
      rect.width > 0 &&
      rect.height > 0 &&
      rect.left >= screen.left &&
      rect.top >= screen.top &&
      rect.right <= screen.right &&
      rect.bottom <= screen.bottom;
  final hit = target.hitTestable().evaluate().isNotEmpty;
  expect(inside, isTrue, reason: 'comparison text must be fully in viewport');
  expect(hit, isTrue, reason: 'comparison text must be hit-testable');
  return {
    'text': tester.widget<Text>(target).data!,
    'left': rect.left,
    'top': rect.top,
    'right': rect.right,
    'bottom': rect.bottom,
    'inside_viewport': inside,
    'hit_testable': hit,
  };
}

void main() {
  _T20LiveBinding().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;

  testWidgets('正式练习首页 → 对练大厅 → 两次历史结算 → 返回首页', (tester) async {
    final environment = Platform.environment;
    final rawOrigin = environment['T20_ORIGIN'];
    final rawTokens = environment['T20_TOKENS'];
    final receiptPath = environment['T20_RECEIPT'];
    expect(rawOrigin, isNotNull);
    expect(rawTokens, isNotNull);
    expect(receiptPath, isNotNull);
    final origin = Uri.parse(rawOrigin!);
    expect(origin.scheme, 'http');
    expect(origin.host, '127.0.0.1');
    expect(origin.hasPort, isTrue);

    final directory = await Directory.systemTemp.createTemp('t20-compare-');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final wire = HttpTransport(http.Client());
    addTearDown(wire.close);
    final sessions = Sessions(_VolatileSecret(), directory);
    final tokens = Tokens.fromJson(
      jsonDecode(rawTokens!) as Map<String, dynamic>,
    );
    final activated = await tester.runAsync(() => sessions.activate(tokens));
    final scope = activated!;
    final api = AppApi(origin, wire, sessions);
    final practice = ApiPractice(api, scope);
    final growth = ApiGrowthRepository(api, scope);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          practiceRepositoryProvider.overrideWithValue(practice),
          growthRepositoryProvider.overrideWithValue(growth),
          contactSpaceProvider.overrideWithValue((
            scene: SceneMemory(),
            repo: null,
            demo: false,
          )),
        ],
        child: MaterialApp(
          initialRoute: '/practice',
          routes: {
            '/practice': (_) => const PracticeHomeRoute(),
            '/training': (_) => const PracticeRoute(),
          },
        ),
      ),
    );

    // REAL HOME: /practice loads PracticeHomeRoute, which supplies non-null
    // content to HomeShell and renders PracticeHomePage. Its own
    // PracticeContinueActions tile pushes /training. The route is the product's,
    // not the placeholder menu list.
    final entry = find.descendant(
      of: find.byType(PracticeContinueActions),
      matching: find.text('对练与预演'),
    );
    await _waitUntil(
      tester,
      () => find.byType(PracticeHomePage).evaluate().isNotEmpty,
      label: 'the real practice home page',
    );
    await _waitForRouteSettled(tester, find.byType(PracticeHomePage));
    await tester.scrollUntilVisible(
      entry,
      300,
      scrollable: _menuScroll(),
    );
    await _tapVisible(tester, entry);
    await _waitForText(tester, '选一个练习场景');

    // Settlement 1: open the second same-level completion from history. The
    // lobby looks up the prior score from /v1/sessions; it is never injected.
    await _openHistory(tester, '第二场合成发言');
    final same = await _renderedComparison(tester);

    await _tapBack(tester);
    await _waitForText(tester, '对练与预演');

    // Settlement 2: control at a different level, same single_skill mode and
    // same target. It must not borrow another level's score.
    await _openHistory(tester, '第三场另关发言');
    final control = await _renderedComparison(tester);

    // Return result → lobby → the same real practice home, both real AppBar
    // back buttons. The home must still be PracticeHomePage with its own entry.
    await _tapBack(tester);
    await _waitForText(tester, '对练与预演');
    await _tapBack(tester);
    await _waitUntil(
      tester,
      () => find.byType(PracticeHomePage).evaluate().isNotEmpty,
      label: 'the real practice home page after both settlements',
    );
    await _waitForRouteSettled(tester, find.byType(PracticeHomePage));
    await tester.scrollUntilVisible(
      entry,
      300,
      scrollable: _menuScroll(),
    );
    expect(entry, findsOneWidget);

    File(receiptPath!).writeAsStringSync(
      jsonEncode({
        'same_level': same,
        'different_level': control,
        'returned_to_lobby': true,
        'returned_to_home': true,
      }),
      flush: true,
    );
  });
}
