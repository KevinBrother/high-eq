import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/endpoints.g.dart';
import 'package:high_eq/core/providers.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/growth/growth_page.dart';
import 'package:high_eq/features/onboarding/assessment.dart';
import 'package:high_eq/features/onboarding/login.dart' show vendorChannel;
import 'package:high_eq/features/practice/repository.dart' show ApiPractice;
import 'package:high_eq/main.dart';

import '../../test/isolation_test.dart' show MemorySecret;
import '../t26/transport.dart';

const _waitLimit = Duration(seconds: 25);
const _frame = Duration(milliseconds: 20);
const _items = 16;

// The second synthetic sheet: 7 on items 1-12, 1 on items 13-16. Compared with
// the Go fixture sheet, the weakest WLEIS dimension moves from SEA
// (observation) to ROE (request).
const _secondAnswers = <int>[
  7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 1, 1, 1, 1,
];

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

Finder _inAssessment(Finder matching) =>
    find.descendant(of: find.byType(AssessmentPage), matching: matching);

Finder _semantics(String label) => find.byWidgetPredicate(
  (widget) => widget is Semantics && widget.properties.label == label,
);

Finder _tab(String label) => find.descendant(
  of: find.byType(NavigationBar),
  matching: find.text(label),
);

Future<void> _waitQuestion(WidgetTester tester, int item, String label) async {
  await _waitFor(
    tester,
    _inAssessment(find.text('合成题目 ${item.toString().padLeft(2, '0')}')),
    label: label,
  );
}

Finder _answer(int value) => _inAssessment(
  find.byWidgetPredicate(
    (widget) =>
        widget is ListTile &&
        widget.onTap != null &&
        widget.leading is Text &&
        (widget.leading! as Text).data == '$value',
  ),
);

Future<void> _answerCurrent(WidgetTester tester, int value) async {
  final control = _answer(value);
  await _waitFor(tester, control, label: 'answer $value on the current item');
  if (control.hitTestable().evaluate().isEmpty) {
    await Scrollable.ensureVisible(tester.element(control), alignment: .5);
    await tester.pump();
  }
  await _waitUntil(
    tester,
    () => control.hitTestable().evaluate().length == 1,
    label: 'hittable answer $value',
  );
  await tester.tap(control.hitTestable());
  await tester.pump();
}

void mark(String stage) => debugPrintSynchronously('T27_STAGE $stage');

void main() {
  _T27LiveBinding().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;

  testWidgets(
    'same synthetic account retests after four weeks and both plans use the latest weakest dimension',
    (tester) async {
      final environment = Platform.environment;
      final rawOrigin = environment['T27_ORIGIN'];
      final proof = environment['T27_LOGIN_PROOF'];
      final zone2 = environment['T27_ZONE2'];
      expect(rawOrigin, isNotNull, reason: 'T27_ORIGIN is required');
      expect(proof, isNotNull, reason: 'T27_LOGIN_PROOF is required');
      expect(proof, isNotEmpty, reason: 'T27_LOGIN_PROOF must not be empty');
      expect(zone2, isNotNull, reason: 'T27_ZONE2 is required');

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

      final directory = await Directory.systemTemp.createTemp('t27-live-');
      addTearDown(() async {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });
      final sessions = Sessions(MemorySecret(), directory);
      await sessions.restore();

      final transport = HttpTransport(t26LoopbackClient());
      addTearDown(transport.close);
      final api = AppApi(origin, transport, sessions);

      var authorizeCalls = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(vendorChannel, (call) async {
        if (call.method != 'authorize') {
          throw PlatformException(code: 'unexpected_method');
        }
        authorizeCalls++;
        return proof;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(vendorChannel, null),
      );

      mark('login');
      await tester.pumpWidget(
        ProviderScope(
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
      await _tapFinder(tester, apple, next: find.text('今日计划'), nextLabel: 'practice home with the fixture plan');
      expect(authorizeCalls, 1);
      expect(api.sessions.active, isNotNull);

      mark('fixture-plan');
      final observationSubtitle = find.text('对练关卡 · 只说刚才发生的事');
      await _waitFor(tester, observationSubtitle, label: 'fixture plan single level');
      expect(find.text('单项练习'), findsOneWidget);
      expect(find.text('对练关卡 · 把请求说具体'), findsNothing);

      mark('growth-before');
      await _tapFinder(
        tester,
        _tab('成长'),
        next: find.byType(GrowthPage),
        nextLabel: 'formal growth page',
      );
      final growth = find.byType(GrowthPage);
      await _waitFor(
        tester,
        find.descendant(of: growth, matching: find.text('四周复测已到期')),
        label: 'four-week retest banner',
      );
      expect(_semantics('最近一次，50 / 100'), findsOneWidget);
      expect(_semantics('自我觉察，最近一次 0 分，L1'), findsOneWidget);
      expect(_semantics('读懂别人，最近一次 17 分，L1'), findsOneWidget);
      expect(_semantics('自我激励，最近一次 83 分，L4'), findsOneWidget);
      expect(_semantics('自我管理，最近一次 100 分，L5'), findsOneWidget);
      expect(find.text('更早一次'), findsNothing);

      mark('retest');
      await _tapFinder(
        tester,
        find.descendant(of: growth, matching: find.text('去复测')),
        next: find.byType(AssessmentPage),
        nextLabel: 'real assessment page from the growth retest entry',
      );
      await _waitFor(
        tester,
        _inAssessment(find.text('本次自评总分 · 50 / 100')),
        label: 'previous assessment result from the retest entry',
      );
      // Let the growth -> assessment route transition finish; the result text
      // can appear while the incoming page is still sliding in.
      await tester.pump(const Duration(milliseconds: 600));
      final startRetest = _inAssessment(
        find.widgetWithText(OutlinedButton, '开始复测'),
      );
      await _tapFinder(tester, startRetest);
      await _waitQuestion(tester, 1, 'reassessment question 1');
      for (var item = 0; item < _items; item++) {
        await _answerCurrent(tester, _secondAnswers[item]);
        if (item + 1 < _items) {
          await _waitQuestion(tester, item + 2, 'reassessment question ${item + 2}');
        }
      }
      await _waitFor(
        tester,
        _inAssessment(find.text('想先在哪种场合练习？')),
        label: 'reassessment scene',
      );
      final friends = find.ancestor(
        of: find.text('朋友'),
        matching: find.byWidgetPredicate(
          (widget) => widget is ChoiceChip && widget.onSelected != null,
        ),
      );
      await _tapFinder(tester, friends);
      await _waitUntil(tester, () {
        final matches = friends.evaluate();
        return matches.length == 1 &&
            (matches.single.widget as ChoiceChip).selected;
      }, label: 'selected friend scene');

      final submit = _inAssessment(
        find.widgetWithText(FilledButton, '提交并查看雷达图'),
      );
      await _tapFinder(tester, submit);
      await _waitFor(
        tester,
        _inAssessment(find.text('本次自评总分 · 75 / 100')),
        label: 'real reassessment result',
      );
      expect(_inAssessment(find.text('距下次可复测还有 28 天')), findsOneWidget);

      mark('same-day-plan');
      await _tapFinder(
        tester,
        _inAssessment(find.text('进入练习')),
        next: find.text('今日计划'),
        nextLabel: 'practice home after reassessment',
      );
      await _waitFor(tester, observationSubtitle, label: 'kept same-day plan');
      expect(find.text('单项练习'), findsOneWidget);
      expect(find.text('对练关卡 · 把请求说具体'), findsNothing);
      expect(find.text('对练关卡 · 协作时提出期限'), findsNothing);
      // Let the pushNamedAndRemoveUntil transition finish before the tab bar
      // accepts another tap.
      await tester.pump(const Duration(milliseconds: 600));

      mark(
        'growth-after nav=${find.byType(NavigationBar).evaluate().length} '
        'tab=${_tab('成长').evaluate().length} '
        'hit=${_tab('成长').hitTestable().evaluate().length}',
      );
      await _tapFinder(
        tester,
        _tab('成长'),
        next: find.byType(GrowthPage),
        nextLabel: 'growth page after reassessment',
      );
      await _waitFor(
        tester,
        _semantics('最近一次总分，75 / 100'),
        label: 'latest assessment comparison',
      );
      expect(_semantics('更早一次，50 / 100'), findsOneWidget);
      expect(_semantics('变化，+25'), findsOneWidget);
      expect(find.text('变化'), findsOneWidget);
      expect(find.text('+25'), findsOneWidget);
      // Both radar readings carry the before and after of the same account, and
      // all four WLEIS axes change between the two synthetic sheets.
      expect(_semantics('自我觉察，最近一次 100 分，L5，更早一次 0 分'), findsOneWidget);
      expect(_semantics('读懂别人，最近一次 100 分，L5，更早一次 17 分'), findsOneWidget);
      expect(_semantics('自我激励，最近一次 100 分，L5，更早一次 83 分'), findsOneWidget);
      expect(_semantics('自我管理，最近一次 0 分，L1，更早一次 100 分'), findsOneWidget);

      mark('next-day-plan');
      final scope = api.sessions.active!;
      await tester.runAsync(
        () => MobileEndpoints(api).updateMe(
          scope: scope,
          body: {'timezone': zone2},
        ),
      );
      // Read the generated plan through the same formal HTTP route the page
      // uses, then resolve that exact content_id in the formal level catalog.
      // The page must show this single level's title, not either request level.
      final nextPlan = await tester.runAsync(
        () => MobileEndpoints(api).getTodayPlan(scope: scope),
      );
      final levelItems = (nextPlan!['items'] as List)
          .cast<Json>()
          .where((item) => item['kind'] == 'level' && item['title'] == '单项练习')
          .toList();
      expect(levelItems, hasLength(1), reason: 'one single-skill level in the next-day plan');
      final levelId = levelItems.single['content_id'] as String;
      final catalogLevel = await tester.runAsync(
        () => ApiPractice(api, scope).findLevel(levelId),
      );
      expect(catalogLevel, isNotNull, reason: 'generated level $levelId is in the catalog');
      final levelTitle = catalogLevel!['title'] as String;

      await _tapFinder(tester, _tab('练习'), next: find.text('今日计划'), nextLabel: 'practice home on the fixture next day');
      // Locate the actual single-skill row, not the whole screen: both the
      // single-skill and full-practice rows resolve their own subtitle, so a
      // page-wide text match could pair the expected title with the wrong row.
      final singleRow = find.ancestor(
        of: find.text('单项练习'),
        matching: find.byType(ListTile),
      );
      final rowSubtitle = find.descendant(
        of: singleRow,
        matching: find.text('对练关卡 · $levelTitle'),
      );
      await _waitFor(tester, rowSubtitle, label: 'single-skill row $levelId');
      // The replaced practice route may still be on screen for one transition.
      await tester.pump(const Duration(milliseconds: 600));
      expect(singleRow, findsOneWidget);
      expect(rowSubtitle, findsOneWidget);
      expect(
        find.descendant(
          of: singleRow,
          matching: find.text('对练关卡 · 只说刚才发生的事'),
        ),
        findsNothing,
      );

      mark('done');
      debugPrintSynchronously('PASS(page.journey)');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
