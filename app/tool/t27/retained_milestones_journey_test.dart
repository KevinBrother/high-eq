import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/providers.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/growth/growth_page.dart';
import 'package:high_eq/features/growth/practice_home.dart';
import 'package:high_eq/features/growth/widgets.dart';
import 'package:high_eq/features/onboarding/login.dart' show vendorChannel;
import 'package:high_eq/main.dart';

import '../../test/isolation_test.dart' show MemorySecret;
import '../t26/transport.dart';

const _waitLimit = Duration(seconds: 25);
const _frame = Duration(milliseconds: 20);

class _T27LiveBinding extends LiveTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
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
    final visible = <String>[];
    for (final element in find.byType(Text).evaluate()) {
      final data = (element.widget as Text).data;
      if (data != null && data.isNotEmpty) visible.add(data);
    }
    fail(
      'Timed out waiting for $label. Visible text: '
      '${visible.take(30).join(' | ')}',
    );
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

Finder _semantics(String label) => find.byWidgetPredicate(
  (widget) => widget is Semantics && widget.properties.label == label,
);

void _expectMilestonesRetained() {
  for (final days in [3, 7, 30]) {
    expect(_semantics('成就，连续 $days 天，已达成'), findsOneWidget);
    expect(_semantics('成就，连续 $days 天，未达成'), findsNothing);
  }
}

Finder _tab(String label) => find.descendant(
  of: find.byType(NavigationBar),
  matching: find.text(label),
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

/// Scrolls a page the way a normal user would until the milestone strip is
/// fully inside the viewport. No production marker or test-only hook is used.
Future<void> _scrollToStrip(WidgetTester tester, Finder page) async {
  final scrollable = find
      .descendant(of: page, matching: find.byType(Scrollable))
      .first;
  final strip = find.descendant(
    of: page,
    matching: find.byType(AchievementStrip),
  );
  await tester.dragUntilVisible(strip, scrollable, const Offset(0, -240));
  await tester.pump();
  final view = _viewport(tester);
  final nav = find.byType(NavigationBar);
  final bottom = nav.evaluate().isEmpty
      ? view.bottom
      : tester.getRect(nav).top - 16;
  final rect = tester.getRect(strip);
  if (rect.bottom > bottom) {
    await tester.drag(scrollable, Offset(0, -(rect.bottom - bottom)));
    await tester.pump();
  }
  // Finish with normal drag gestures until every stage chip is actually
  // hit-testable, not hidden under the bottom tab bar.
  bool allHitTestable() => [3, 7, 30].every(
    (days) => find
        .descendant(of: strip, matching: find.text('$days 天'))
        .hitTestable()
        .evaluate()
        .isNotEmpty,
  );
  for (var i = 0; i < 12 && !allHitTestable(); i++) {
    await tester.drag(scrollable, const Offset(0, -60));
    await tester.pump();
  }
  expect(allHitTestable(), isTrue, reason: 'stage chips did not reach the viewport');
  _expectInViewport(tester, strip, 'milestone strip');
}

/// Checks the real render tree, not only semantics: every stage must draw the
/// unlocked award icon and unlocked container colour, and no stage in the
/// strip may draw the locked icon or locked background. The locked branch in
/// AchievementStrip uses Icons.lock_outline + surfaceContainerHighest.
void _expectRenderedMilestones(WidgetTester tester, Finder page) {
  final strip = find.descendant(
    of: page,
    matching: find.byType(AchievementStrip),
  );
  expect(strip, findsOneWidget);
  final theme = Theme.of(tester.element(strip));
  for (final days in [3, 7, 30]) {
    final text = find.descendant(of: strip, matching: find.text('$days 天'));
    expect(text, findsOneWidget);
    // Hit-testable means the chip was actually scrolled into the visible
    // viewport, not merely built off-screen or hidden behind the tab bar.
    expect(text.hitTestable(), findsOneWidget);
    final chip = find.ancestor(of: text, matching: find.byType(Container)).first;
    final decoration = tester.widget<Container>(chip).decoration;
    expect(decoration, isA<BoxDecoration>());
    final color = (decoration as BoxDecoration).color;
    expect(color, theme.colorScheme.tertiaryContainer);
    expect(color, isNot(theme.colorScheme.surfaceContainerHighest));
    final icon = find.descendant(of: chip, matching: find.byType(Icon));
    expect(tester.widget<Icon>(icon).icon, Icons.workspace_premium);
    expect(
      find.descendant(of: chip, matching: find.byIcon(Icons.lock_outline)),
      findsNothing,
    );
  }
  expect(
    find.descendant(of: strip, matching: find.byIcon(Icons.lock_outline)),
    findsNothing,
  );
}

Future<void> _openGrowthArchive(WidgetTester tester) async {
  await _tapFinder(tester, _tab('成长'));
  await _waitFor(
    tester,
    find.byType(GrowthPage).hitTestable(),
    label: 'formal growth archive from the normal tab bar',
  );
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _backToPractice(WidgetTester tester) async {
  await _tapFinder(tester, _tab('练习'));
  await _waitFor(
    tester,
    find.text('今日计划').hitTestable(),
    label: 'practice home from the normal tab bar',
  );
  await tester.pump(const Duration(milliseconds: 300));
}

void mark(String stage) => debugPrintSynchronously('T27_STAGE $stage');

class _Journey {
  _Journey(this.origin, this.proofs);

  final Uri origin;
  final List<String> proofs;
  var authorizations = 0;
  final sessions = <Sessions>[];
  final transports = <HttpTransport>[];

  Future<AppApi> open(WidgetTester tester) async {
    final directory = await Directory.systemTemp.createTemp('t27-streak-');
    final sessions = Sessions(MemorySecret(), directory);
    await sessions.restore();
    this.sessions.add(sessions);
    final transport = HttpTransport(t26LoopbackClient());
    transports.add(transport);
    return AppApi(origin, transport, sessions);
  }

  Future<void> signIn(WidgetTester tester, AppApi api) async {
    final proof = proofs[authorizations++];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(vendorChannel, (call) async {
      if (call.method != 'authorize') {
        throw PlatformException(code: 'unexpected_method');
      }
      return proof;
    });

    // A fresh key discards the previous page's provider container, so the cold
    // reopen cannot inherit the first app's in-memory state.
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
      nextLabel: 'practice home with the retained milestones',
    );
    expect(api.sessions.active, isNotNull);
  }

  Future<void> dispose() async {
    for (final transport in transports) {
      transport.close();
    }
    for (final sessions in sessions) {
      await sessions.clear();
    }
  }
}

void main() {
  _T27LiveBinding().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;

  testWidgets(
    'broken streak keeps 3/7/30 and one real free completion counts today once',
    (tester) async {
      final environment = Platform.environment;
      final rawOrigin = environment['T27_ORIGIN'];
      final firstProof = environment['T27_LOGIN_PROOF'];
      final secondProof = environment['T27_LOGIN_PROOF2'];
      expect(rawOrigin, isNotNull, reason: 'T27_ORIGIN is required');
      expect(firstProof, isNotNull, reason: 'T27_LOGIN_PROOF is required');
      expect(secondProof, isNotNull, reason: 'T27_LOGIN_PROOF2 is required');
      expect(secondProof, isNot(firstProof));

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

      final journey = _Journey(origin, [firstProof!, secondProof!]);
      addTearDown(journey.dispose);
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(vendorChannel, null);
      });

      mark('login');
      final api = await journey.open(tester);
      await journey.signIn(tester, api);
      expect(journey.authorizations, 1);

      mark('retained-milestones');
      await _waitFor(tester, find.text('连续 0 天'), label: 'current streak zero');
      _expectMilestonesRetained();
      expect(find.text('0 / 4 已完成'), findsOneWidget);
      expect(find.text('新成就解锁'), findsNothing);
      debugPrintSynchronously('PASS(page.retained-milestones)');

      mark('practice-strip');
      await _scrollToStrip(tester, find.byType(PracticeHomePage));
      _expectRenderedMilestones(tester, find.byType(PracticeHomePage));
      debugPrintSynchronously('PASS(page.practice-strip)');

      mark('growth-retained');
      await _openGrowthArchive(tester);
      await _scrollToStrip(tester, find.byType(GrowthPage));
      _expectRenderedMilestones(tester, find.byType(GrowthPage));
      expect(find.text('当前连续 0 天'), findsOneWidget);
      debugPrintSynchronously('PASS(page.growth-retained)');
      await _backToPractice(tester);

      mark('today-completion');
      await _tapFinder(
        tester,
        find.text('读人练习'),
        next: find.byType(ExerciseSheet),
        nextLabel: 'exercise sheet from the today plan',
      );
      await _waitFor(
        tester,
        find.byType(RadioListTile<int>),
        label: 'exercise choices',
      );
      await _tapFinder(tester, find.byType(RadioListTile<int>).first);
      await _tapFinder(
        tester,
        find.widgetWithText(FilledButton, '看看我读对了吗'),
      );
      await _waitUntil(
        tester,
        () =>
            find.text('读到了').evaluate().isNotEmpty ||
            find.text('再换一个角度').evaluate().isNotEmpty,
        label: 'exercise verdict',
      );
      await _tapText(tester, '完成今日练习');
      await _waitFor(
        tester,
        find.text('已打卡 · 连续 1 天'),
        label: 'completion snackbar with the new one-day streak',
      );
      // Completion always returns every reached milestone; the page must only
      // announce newly added stages, so an empty set shows no dialog.
      expect(find.text('新成就解锁'), findsNothing);
      await _waitFor(tester, find.text('连续 1 天'), label: 'streak one');
      expect(find.text('1 / 4 已完成'), findsOneWidget);
      _expectMilestonesRetained();
      debugPrintSynchronously('PASS(page.today-completion)');

      mark('cold-reopen');
      final cold = await journey.open(tester);
      await journey.signIn(tester, cold);
      expect(journey.authorizations, 2);
      await _waitFor(tester, find.text('连续 1 天'), label: 'cold streak one');
      _expectMilestonesRetained();
      expect(find.text('1 / 4 已完成'), findsOneWidget);
      expect(find.text('读人小练习 · 已完成'), findsOneWidget);
      expect(find.text('新成就解锁'), findsNothing);
      await _scrollToStrip(tester, find.byType(PracticeHomePage));
      _expectRenderedMilestones(tester, find.byType(PracticeHomePage));
      // The second Sessions ran on an empty directory: nothing above came from
      // the first page's encrypted cache.
      debugPrintSynchronously('PASS(page.cold-reopen)');

      mark('growth-cold-reopen');
      await _openGrowthArchive(tester);
      await _scrollToStrip(tester, find.byType(GrowthPage));
      _expectRenderedMilestones(tester, find.byType(GrowthPage));
      expect(find.text('当前连续 1 天'), findsOneWidget);
      debugPrintSynchronously('PASS(page.growth-cold-reopen)');

      mark('done');
      debugPrintSynchronously('PASS(page.journey)');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
