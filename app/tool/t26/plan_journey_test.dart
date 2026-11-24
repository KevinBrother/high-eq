import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/providers.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/onboarding/login.dart' show vendorChannel;
import 'package:high_eq/main.dart';

import '../../test/isolation_test.dart' show MemorySecret;
import 'assessment_steps.dart';
import 'journey_stage.dart';
import 'plan_practice_steps.dart';
import 'transport.dart';

const _networkLimit = Duration(seconds: 25);

class _T26LiveBinding extends LiveTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() ready, {
  required String label,
  Duration limit = _networkLimit,
}) async {
  final elapsed = Stopwatch()..start();
  while (elapsed.elapsed < limit) {
    await tester.pump(const Duration(milliseconds: 20));
    if (ready()) return;
  }
  await tester.pump();
  if (!ready()) {
    fail(
      'Timed out after ${limit.inSeconds}s waiting for $label. '
      'No URL, token, or login proof is included in this failure.',
    );
  }
}

Future<void> _waitFor(
  WidgetTester tester,
  Finder finder, {
  required String label,
  Duration limit = _networkLimit,
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

void main() {
  _T26LiveBinding().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;

  testWidgets(
    'real new user reaches an actionable T26 plan and hands to practice card',
    (tester) async {
      T26JourneyStage.login.report();
      final environment = Platform.environment;
      final rawOrigin = environment['T26_ORIGIN'];
      final proof = environment['T26_LOGIN_PROOF'];
      expect(rawOrigin, isNotNull, reason: 'T26_ORIGIN is required');
      expect(proof, isNotNull, reason: 'T26_LOGIN_PROOF is required');
      expect(proof, isNotEmpty, reason: 'T26_LOGIN_PROOF must not be empty');

      final origin = Uri.parse(rawOrigin!);
      expect(origin.scheme, 'http');
      expect(origin.host, '127.0.0.1');
      expect(origin.hasPort, isTrue);
      expect(origin.userInfo, isEmpty);
      expect(origin.path, anyOf('', '/'));
      expect(origin.hasQuery, isFalse);
      expect(origin.hasFragment, isFalse);

      final directory = await Directory.systemTemp.createTemp('t26-live-');
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
      MethodCall? authorizeCall;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(vendorChannel, (call) async {
        if (call.method != 'authorize') {
          throw PlatformException(code: 'unexpected_method');
        }
        authorizeCalls++;
        authorizeCall = call;
        return proof;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(vendorChannel, null),
      );

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
      await _tapFinder(
        tester,
        apple,
        next: find.text('是否同意开始本次自评？'),
        nextLabel: 'assessment consent',
      );
      expect(authorizeCalls, 1);
      expect(authorizeCall?.method, 'authorize');
      expect(authorizeCall?.arguments, {'provider': 'apple'});
      expect(api.sessions.active, isNotNull);

      T26JourneyStage.assessment.report();
      final enterPractice = await completeT26Assessment(
        tester,
        report: (phase) => phase.report(),
      );

      T26JourneyStage.plan.report();
      await tester.tap(enterPractice);
      await _waitFor(tester, find.text('今日计划'), label: 'practice home plan');
      expect(find.text('今天，练一件小事'), findsOneWidget);

      final planSubtitle = find.text('读人小练习');
      await _waitFor(tester, planSubtitle, label: 'actionable plan item');
      final planTile = find.ancestor(
        of: planSubtitle,
        matching: find.byType(ListTile),
      );
      expect(planTile, findsOneWidget);
      expect(tester.widget<ListTile>(planTile).onTap, isNotNull);

      await finishT26PlanPractice(tester, api);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
