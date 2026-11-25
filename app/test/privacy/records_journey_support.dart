import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart' hide within;
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/providers.dart';
import 'package:high_eq/features/home/shell.dart';
import 'package:high_eq/features/onboarding/login.dart';
import 'package:high_eq/features/privacy/page.dart';
import 'package:high_eq/main.dart';

import '../../tool/t27/history_journey_support.dart' show JourneyFrames;
import 'account_journey_test.dart' show currentPage, within;

const browseRecords = Key('privacy-browse-records');

Future<void> mountRecordsApp(WidgetTester tester, AppApi api) =>
    tester.pumpWidget(
      ProviderScope(
        overrides: [apiProvider.overrideWith((_) => api)],
        child: const HighEqApp(),
      ),
    );

Future<void> logInForRecords(
  JourneyFrames frames, {
  required String appleProof,
}) async {
  final messenger = frames.tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(vendorChannel, (call) async {
    expect(call.method, 'authorize');
    expect(call.arguments, {'provider': 'apple'});
    return appleProof;
  });
  try {
    final login = currentPage<LoginPage>('/');
    await frames.tap(within(login, find.text('我已阅读并同意')));
    await frames.tap(within(login, find.text('同意并继续')));
    await frames.tap(within(login, find.text('我已满 14 周岁')));
    final apple = within(login, find.text('Apple 登录'));
    await frames.show(apple, within: login);
    await frames.tap(apple);

    final practice = currentPage<HomeShell>('/practice');
    final skipAssessment = find.text('暂不测评');
    await frames.until(
      () =>
          practice.evaluate().isNotEmpty ||
          skipAssessment.evaluate().isNotEmpty,
      'practice or the first assessment consent',
    );
    if (practice.evaluate().isEmpty) await frames.tap(skipAssessment);
    await frames.appeared(practice, 'signed-in practice page');
  } finally {
    messenger.setMockMethodCallHandler(vendorChannel, null);
  }
}

Future<Finder> openRecordsPrivacy(
  JourneyFrames frames,
  String accountId,
) async {
  final practice = currentPage<HomeShell>('/practice');
  await frames.tap(
    within(
      within(practice, find.byType(NavigationBar)),
      find.byWidgetPredicate(
        (widget) => widget is NavigationDestination && widget.label == '我的',
      ),
    ),
  );
  final me = currentPage<HomeShell>('/me');
  final tile = within(me, find.byKey(const Key('me-privacy')));
  await frames.show(tile, within: me);
  await frames.tap(tile);

  final privacy = currentPage<PrivacyPage>('/privacy');
  await frames.appeared(
    within(privacy, find.text('账号 $accountId')),
    'privacy account',
  );
  return privacy;
}
