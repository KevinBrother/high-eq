import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/endpoints.g.dart';
import 'package:high_eq/core/providers.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/growth/growth_page.dart';
import 'package:high_eq/features/growth/practice_home.dart';
import 'package:high_eq/features/growth/widgets.dart';
import 'package:high_eq/features/onboarding/login.dart' show vendorChannel;
import 'package:high_eq/main.dart';
import 'package:http/http.dart' as http;

import '../../test/isolation_test.dart' show MemorySecret;
import '../t26/transport.dart';

const _waitLimit = Duration(seconds: 30);
const _frame = Duration(milliseconds: 20);
const _lastCardId = '26000000-0000-4000-8000-000000000120';
// Formal seed values for the last card, independent of any response body.
const _lastCardTitle = '公共场景：发出请求';
const _lastCardBody = '请求要短、具体、可执行，并给对方一个容易回应的选项。';

class _T27LiveBinding extends LiveTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

/// Records the formal HTTP calls the widgets make without adding a test-only
/// product hook. Bodies stay in memory only and are never printed.
class _Captured {
  final List<Map<String, dynamic>> cards = [];
  final Map<String, Map<String, dynamic>> details = {};
  final List<String> cardRequests = [];
  final List<String> completes = [];
}

class _CountingTransport implements Transport {
  _CountingTransport(this._inner, this.capture);

  final Transport _inner;
  final _Captured capture;

  @override
  Future<http.StreamedResponse> send(AppOp op, http.Request request) async {
    final path = request.url.path;
    // Count before sending so a hanging or failing request cannot be missed.
    if (request.method == 'POST' &&
        path.startsWith('/v1/plans/items/') &&
        path.endsWith('/complete')) {
      capture.completes.add(path);
    }
    if (op == AppOp.getCard) capture.cardRequests.add(request.url.pathSegments.last);
    final response = await _inner.send(op, request);
    if (op != AppOp.listCards && op != AppOp.getCard) return response;
    final bytes = await response.stream.toBytes();
    if (op == AppOp.listCards) {
      final decoded = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      capture.cards
        ..clear()
        ..addAll((decoded['items'] as List).cast<Map<String, dynamic>>());
    } else {
      final decoded = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      capture.details[request.url.pathSegments.last] = decoded;
    }
    final headers = Map<String, String>.from(response.headers)
      ..remove('content-encoding');
    return http.StreamedResponse(
      Stream.value(bytes),
      response.statusCode,
      contentLength: bytes.length,
      request: response.request,
      headers: headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() => _inner.close();
}

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() ready, {
  required String label,
  Duration limit = _waitLimit,
}) async {
  final clock = tester.binding.clock;
  final deadline = clock.now().add(limit);
  do {
    if (ready()) return;
    await tester.pump(_frame);
  } while (clock.now().isBefore(deadline));
  if (!ready()) {
    // Deliberately no widget text: catalog subtitles carry full card bodies.
    fail('Timed out waiting for $label');
  }
}

Future<void> _waitFor(
  WidgetTester tester,
  Finder finder, {
  required String label,
  Duration limit = _waitLimit,
}) => _waitUntil(
  tester,
  () => finder.evaluate().isNotEmpty,
  label: label,
  limit: limit,
);

Future<void> _tapFinder(
  WidgetTester tester,
  Finder finder, {
  Finder? next,
  String? nextLabel,
}) async {
  await _waitFor(tester, finder, label: 'tappable control');
  final target = finder.last;
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await tester.pump();
  if (next != null) {
    await _waitFor(tester, next, label: nextLabel ?? 'next screen');
  }
}

Future<void> _tapText(
  WidgetTester tester,
  String text, {
  Finder? next,
  String? nextLabel,
}) => _tapFinder(tester, find.text(text), next: next, nextLabel: nextLabel);

Finder _tab(String label) => find.descendant(
  of: find.byElementPredicate(
    (element) =>
        element.widget is NavigationBar &&
        (ModalRoute.of(element)?.isCurrent ?? false),
  ),
  matching: find.text(label),
);

/// Only the route on top of the navigator. Lower routes stay mounted in the
/// overlay, so a bare [find.byType] can return a previous page of the same type.
Finder _currentPage(Type type) => find.byElementPredicate((element) {
  if (element.widget.runtimeType != type) return false;
  return ModalRoute.of(element)?.isCurrent ?? false;
});

Finder _currentScrollable(Type page) => find
    .descendant(of: _currentPage(page), matching: find.byType(Scrollable))
    .first;

Finder _semantics(String label) => find.byWidgetPredicate(
  (widget) => widget is Semantics && widget.properties.label == label,
);

Rect _viewport(WidgetTester tester) =>
    Offset.zero & (tester.view.physicalSize / tester.view.devicePixelRatio);

void _expectInViewport(WidgetTester tester, Finder finder, String label) {
  final rect = tester.getRect(finder);
  final view = _viewport(tester);
  expect(rect.top, greaterThanOrEqualTo(view.top), reason: '$label above viewport');
  expect(
    rect.bottom,
    lessThanOrEqualTo(view.bottom),
    reason: '$label below viewport',
  );
  expect(rect.left, greaterThanOrEqualTo(view.left), reason: '$label left of viewport');
  expect(rect.right, lessThanOrEqualTo(view.right), reason: '$label right of viewport');
}

String _progress(Map<String, dynamic> plan) => [
  for (final item in (plan['items'] as List).cast<Map<String, dynamic>>())
    '${item['id']}:${item['completed']}',
].join('|');

/// A normal user scroll gesture: drag the page until the target is hit-testable.
/// Returns the pixels travelled. The last card needs a non-zero travel so the
/// check cannot pass through `ensureVisible` alone.
Future<double> _dragToHitTestable(
  WidgetTester tester,
  Finder target,
  Type page,
  String label,
) async {
  final scrollable = _currentScrollable(page);
  await _waitFor(tester, scrollable, label: 'scrollable for $label');
  final position = tester.state<ScrollableState>(scrollable).position;
  final start = position.pixels;
  for (var i = 0; i < 80 && target.hitTestable().evaluate().isEmpty; i++) {
    await tester.drag(scrollable, const Offset(0, -240));
    await tester.pump();
  }
  expect(
    target.hitTestable(),
    findsOneWidget,
    reason: '$label did not reach the viewport by drag',
  );
  return position.pixels - start;
}

Future<void> _signIn(WidgetTester tester, AppApi api, String proof) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(vendorChannel, (call) async {
    if (call.method != 'authorize') {
      throw PlatformException(code: 'unexpected_method');
    }
    return proof;
  });
  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: [apiProvider.overrideWith((_) async => api)],
      child: const HighEqApp(),
    ),
  );
  await _waitFor(
    tester,
    find.text('同意并继续'),
    label: 'first-run privacy agreement',
  );
  await _tapText(tester, '我已阅读并同意');
  final acceptPrivacy = find.widgetWithText(FilledButton, '同意并继续');
  await tester.pump();
  expect(tester.widget<FilledButton>(acceptPrivacy).onPressed, isNotNull);
  await _tapFinder(
    tester,
    acceptPrivacy,
    next: find.text('先为自己留一个空间'),
    nextLabel: 'login screen',
  );
  await _tapText(tester, '我已满 14 周岁');
  final apple = find.widgetWithText(OutlinedButton, 'Apple 登录');
  await _waitFor(tester, apple, label: 'Apple sign-in button');
  await tester.ensureVisible(apple);
  await tester.pump();
  expect(tester.widget<OutlinedButton>(apple).onPressed, isNotNull);
  await _tapFinder(
    tester,
    apple,
    next: find.text('今日计划'),
    nextLabel: 'practice home',
  );
  expect(api.sessions.active, isNotNull);
}

/// Opens a catalog card by normal dragging, then checks the actual GET path,
/// the response id/title/body and the rendered sheet. The expected title and
/// body come from the caller when they are known independently.
Future<Map<String, dynamic>> _openCatalogCard(
  WidgetTester tester,
  _Captured capture, {
  required String id,
  required String title,
  String? expectedTitle,
  String? expectedBody,
  required bool requireDrag,
}) async {
  final travelled = await _dragToHitTestable(
    tester,
    find.text(title),
    PracticeHomePage,
    'catalog card $id',
  );
  if (requireDrag) {
    expect(travelled, greaterThan(0), reason: 'the last card must follow a real drag');
  }
  await _tapFinder(tester, find.text(title), next: find.byType(CardSheet));
  await _waitUntil(
    tester,
    () => capture.details.containsKey(id),
    label: 'card $id detail response',
  );
  final detail = capture.details[id]!;
  expect(capture.cardRequests.last, id);
  expect(detail['id'], id);
  final titleExpectation = expectedTitle ?? detail['title'] as String;
  final bodyExpectation = expectedBody ?? detail['body'] as String;
  expect(detail['title'], titleExpectation);
  // Boolean equality so a mismatch never prints the card body.
  expect(
    detail['body'] == bodyExpectation,
    isTrue,
    reason: 'card $id response body does not match the expected full body',
  );

  final sheet = find.byType(CardSheet);
  final body = find.descendant(
    of: sheet,
    matching: find.byType(SelectableText),
  );
  await _waitFor(tester, body, label: 'rendered body for card $id');
  expect(
    tester.widget<SelectableText>(body).data == bodyExpectation,
    isTrue,
    reason: 'card $id sheet does not render the expected full body',
  );
  expect(
    find.descendant(of: sheet, matching: find.text(titleExpectation)),
    findsOneWidget,
  );
  expect(
    find.descendant(of: sheet, matching: find.text('读完了，记为完成')),
    findsNothing,
    reason: 'a card outside the plan has no completion action',
  );
  await tester.tapAt(const Offset(8, 8));
  await tester.pump();
  await _waitUntil(
    tester,
    () => find.byType(CardSheet).evaluate().isEmpty,
    label: 'closed card sheet',
  );
  expect(find.text(title), findsWidgets);
  return detail;
}

Future<void> _expectAchievements(WidgetTester tester) async {
  final page = _currentPage(GrowthPage);
  await _waitFor(tester, page, label: 'formal growth page');
  await _waitUntil(
    tester,
    () => _currentScrollable(GrowthPage).evaluate().isNotEmpty,
    label: 'loaded growth archive',
  );
  final heading = find.descendant(of: page, matching: find.text('阶段成就'));
  await tester.dragUntilVisible(
    heading,
    _currentScrollable(GrowthPage),
    const Offset(0, -300),
  );
  final strip = find.descendant(of: page, matching: find.byType(AchievementStrip));
  await _waitFor(tester, strip, label: 'achievement strip');
  await tester.ensureVisible(strip);
  await tester.pump();
  final streak = find.descendant(of: page, matching: find.text('当前连续 1 天'));
  await _waitFor(tester, streak, label: 'current streak');
  expect(page, findsOneWidget);
  expect(heading, findsOneWidget);
  expect(streak, findsOneWidget);
  for (final days in [3, 7, 30]) {
    expect(
      find.descendant(
        of: strip,
        matching: _semantics('成就，连续 $days 天，未达成'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: strip,
        matching: _semantics('成就，连续 $days 天，已达成'),
      ),
      findsNothing,
    );
  }
  expect(strip.hitTestable(), findsOneWidget);
  _expectInViewport(tester, strip, 'achievement strip');
}

void main() {
  _T27LiveBinding().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;

  testWidgets(
    'real catalog read stays read-only and the planned card completes once',
    (tester) async {
      final environment = Platform.environment;
      final rawOrigin = environment['T27_ORIGIN'];
      final proof = environment['T27_LOGIN_PROOF'];
      expect(rawOrigin, isNotNull, reason: 'T27_ORIGIN is required');
      expect(proof, isNotNull, reason: 'T27_LOGIN_PROOF is required');

      final origin = Uri.parse(rawOrigin!);
      expect(origin.scheme, 'http');
      expect(origin.host, '127.0.0.1');
      expect(origin.hasPort, isTrue);
      expect(origin.userInfo, isEmpty);
      expect(origin.path, anyOf('', '/'));
      expect(origin.hasQuery, isFalse);
      expect(origin.hasFragment, isFalse);

      tester.view.physicalSize = const Size(900, 1350);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final directory = await Directory.systemTemp.createTemp('t27-catalog-');
      final sessions = Sessions(MemorySecret(), directory);
      await sessions.restore();
      final capture = _Captured();
      final transport = _CountingTransport(
        HttpTransport(t26LoopbackClient()),
        capture,
      );
      final api = AppApi(origin, transport, sessions);
      addTearDown(() async {
        transport.close();
        await sessions.clear();
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(vendorChannel, null);
      });

      debugPrintSynchronously('T27_STAGE login');
      await _signIn(tester, api, proof!);
      await _waitUntil(
        tester,
        () => capture.cards.length == 20,
        label: 'the real twenty-card catalog',
      );
      await _waitFor(tester, find.text('今日计划'), label: 'practice home');
      expect(capture.completes, isEmpty, reason: 'login and load must not complete a plan item');

      final ids = [for (final card in capture.cards) card['id'] as String];
      expect(ids.toSet(), hasLength(20), reason: 'catalog ids must be unique');
      expect(ids, orderedEquals([...ids]..sort()), reason: 'strict ascending order');
      expect(ids.last, _lastCardId);
      expect(capture.cards.last['title'], _lastCardTitle);
      expect(
        capture.cards.last['body'] == _lastCardBody,
        isTrue,
        reason: 'catalog last card body does not match the formal seed',
      );

      final scope = api.sessions.active!;
      final wire = MobileEndpoints(api);
      final beforeGrowth = await wire.getGrowth(scope: scope);
      final beforePlan = await wire.getTodayPlan(scope: scope);
      final planItems = (beforePlan['items'] as List)
          .cast<Map<String, dynamic>>();
      final planCard = planItems.singleWhere((item) => item['kind'] == 'card');
      expect(
        planItems.any((item) => item['content_id'] == _lastCardId),
        isFalse,
        reason: 'the last catalog card must be outside today plan',
      );
      expect(planItems.any((item) => item['completed'] == true), isFalse);

      debugPrintSynchronously('T27_STAGE browse-last-card');
      await _tapFinder(tester, find.text('查看全部'), next: find.text('收起'));
      for (final card in capture.cards) {
        expect(find.text(card['title'] as String), findsWidgets);
      }
      final third = capture.cards[2];
      await _openCatalogCard(
        tester,
        capture,
        id: third['id'] as String,
        title: third['title'] as String,
        requireDrag: false,
      );
      await _openCatalogCard(
        tester,
        capture,
        id: _lastCardId,
        title: _lastCardTitle,
        expectedTitle: _lastCardTitle,
        expectedBody: _lastCardBody,
        requireDrag: true,
      );
      expect(capture.completes, isEmpty, reason: 'reading must not complete a plan item');
      debugPrintSynchronously('PASS(page.browse-last-card)');

      debugPrintSynchronously('T27_STAGE read-no-complete');
      final readGrowth = await wire.getGrowth(scope: scope);
      final readPlan = await wire.getTodayPlan(scope: scope);
      expect(readGrowth['streak'], beforeGrowth['streak']);
      expect(readGrowth['achievements'], beforeGrowth['achievements']);
      expect(_progress(readPlan), _progress(beforePlan));
      expect(capture.completes, isEmpty);
      debugPrintSynchronously('PASS(page.read-no-complete)');

      debugPrintSynchronously('T27_STAGE plan-card-complete');
      final planTile = find
          .ancestor(of: find.text('知识卡'), matching: find.byType(ListTile))
          .first;
      await _tapFinder(
        tester,
        planTile,
        next: find.byType(CardSheet),
        nextLabel: 'planned card sheet',
      );
      final plannedBody = capture.cards.singleWhere(
        (card) => card['id'] == planCard['content_id'],
      )['body'];
      final plannedSheet = find.byType(CardSheet);
      final plannedText = find.descendant(
        of: plannedSheet,
        matching: find.byType(SelectableText),
      );
      await _waitFor(tester, plannedText, label: 'planned card body');
      expect(
        tester.widget<SelectableText>(plannedText).data == plannedBody,
        isTrue,
        reason: 'planned card sheet does not render the planned full body',
      );
      final completeLabel = find.text('读完了，记为完成');
      await _waitFor(tester, completeLabel, label: 'completion button');
      final completeButton = find
          .ancestor(
            of: completeLabel,
            matching: find.byWidgetPredicate((widget) => widget is FilledButton),
          )
          .first;
      expect(tester.widget<FilledButton>(completeButton).onPressed, isNotNull);
      expect(capture.completes, isEmpty, reason: 'opening the planned card is not completion');
      await _tapFinder(tester, completeLabel);
      await _waitFor(
        tester,
        find.text('已打卡 · 连续 1 天'),
        label: 'planned-card completion snackbar',
      );
      expect(capture.completes, hasLength(1));
      expect(capture.completes.single, '/v1/plans/items/${planCard['id']}/complete');
      expect(capture.completes.single.contains(_lastCardId), isFalse);

      final finalGrowth = await wire.getGrowth(scope: scope);
      final finalPlan = await wire.getTodayPlan(scope: scope);
      final completed = (finalPlan['items'] as List)
          .cast<Map<String, dynamic>>()
          .where((item) => item['completed'] == true)
          .toList();
      expect(completed, hasLength(1));
      expect(completed.single['id'], planCard['id']);
      expect(completed.single['kind'], 'card');
      expect(finalGrowth['streak'], 1);
      expect(finalGrowth['achievements'], beforeGrowth['achievements']);
      expect(find.text('1 / 4 已完成'), findsOneWidget);
      debugPrintSynchronously('PASS(page.plan-card-complete)');

      debugPrintSynchronously('T27_STAGE growth-tab');
      await _tapFinder(
        tester,
        _tab('成长'),
        next: find.byType(GrowthPage).hitTestable(),
        nextLabel: 'formal growth archive from the tab bar',
      );
      await _expectAchievements(tester);
      debugPrintSynchronously('PASS(page.growth-tab)');
      await _tapFinder(
        tester,
        _tab('练习'),
        next: find.text('今日计划').hitTestable(),
        nextLabel: 'practice home after the tab bar archive',
      );

      debugPrintSynchronously('T27_STAGE growth-home');
      // Wait for the current practice route and its drag container to be
      // mounted, then drag until the home button itself is hit-testable. A
      // mounted copy on a lower route cannot be tapped.
      await _waitFor(
        tester,
        _currentPage(PracticeHomePage),
        label: 'current practice route',
      );
      final practiceScrollable = _currentScrollable(PracticeHomePage);
      await _waitFor(
        tester,
        practiceScrollable,
        label: 'current practice scrollable',
      );
      for (var i = 0;
          i < 80 && find.text('成长档案').hitTestable().evaluate().isEmpty;
          i++) {
        if (practiceScrollable.evaluate().isEmpty) {
          await tester.pump(_frame);
          continue;
        }
        await tester.drag(practiceScrollable.first, const Offset(0, -240));
        await tester.pump();
      }
      final growthButton = find.text('成长档案').hitTestable();
      expect(growthButton, findsOneWidget);
      await _tapFinder(
        tester,
        growthButton,
        next: find.byType(GrowthPage).hitTestable(),
        nextLabel: 'formal growth archive from the home button',
      );
      await _expectAchievements(tester);
      debugPrintSynchronously('PASS(page.growth-home)');

      debugPrintSynchronously('PASS(page.journey)');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    timeout: const Timeout(Duration(minutes: 7)),
  );
}
