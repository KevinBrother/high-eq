import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/membership/page.dart';
import 'package:high_eq/features/membership/store.dart';
import 'package:high_eq/features/reviews/page.dart';
import 'package:http/http.dart' as http;

class _VolatileSecret implements SecretStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> replace(String? v) async => value = v;
}

// No merchant is reachable; every purchase call fails loudly if the journey
// ever tries to buy instead of viewing quota.
class _NoPurchasePort extends StorePort {
  _NoPurchasePort() : super(false);
  @override
  Future<void> available(String channel) async =>
      throw StateError('purchase unavailable in this journey');
  @override
  Future<List<String>> apple(String? plan, String? token) async =>
      throw StateError('purchase unavailable in this journey');
  @override
  Future<void> finish(String signed) async =>
      throw StateError('purchase unavailable in this journey');
  @override
  Future<void> android(String channel, String payload) async =>
      throw StateError('purchase unavailable in this journey');
}

// The real product routes run in the Go test's loopback server; only that
// socket may be dialled from the card sandbox.
class _T24LiveBinding extends LiveTestWidgetsFlutterBinding {
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
  fail('Timed out waiting for $label. No URL, token or review body is logged.');
}

Future<void> _waitForText(WidgetTester tester, String text) => _waitUntil(
  tester,
  () => find.text(text).evaluate().isNotEmpty,
  label: 'text "$text"',
);

Future<void> _waitForKey(WidgetTester tester, String key) => _waitUntil(
  tester,
  () => find.byKey(Key(key)).evaluate().isNotEmpty,
  label: 'field "$key"',
);

Future<void> _tapText(WidgetTester tester, String text) async {
  await _waitForText(tester, text);
  final target = find.text(text).last;
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await tester.pump();
}

String _fieldText(WidgetTester tester, String key) {
  final field = find.byKey(Key(key));
  expect(field, findsOneWidget);
  return tester.widget<TextField>(field).controller!.text;
}

Future<Map<String, dynamic>> _checkpoint(
  WidgetTester tester,
  Uri origin,
  String fixtureSecret,
  String stage,
  Map<String, dynamic> body,
) async {
  // FIXTURE ONLY: a readback of the same running service, not a product route
  // and not a stand-in for any page submission.
  final response = await tester.runAsync(() => http.post(
    origin.replace(path: '/__t24/checkpoint'),
    headers: {
      'content-type': 'application/json',
      'x-t24-fixture': fixtureSecret,
    },
    body: jsonEncode({'stage': stage, ...body}),
  ));
  if (response!.statusCode != 200) {
    fail('fixture "$stage" returned status ${response.statusCode}');
  }
  final value = jsonDecode(response.body);
  if (value is! Map<String, dynamic> || value['stage'] != stage) {
    throw StateError('fixture "$stage" returned an invalid readback');
  }
  return value;
}

String _resetSubtitleUnder(WidgetTester tester, String title) {
  final row = find.ancestor(
    of: find.text(title),
    matching: find.byType(ListTile),
  );
  expect(row, findsOneWidget);
  final rows = tester
      .widgetList<Text>(find.descendant(of: row, matching: find.byType(Text)))
      .map((text) => text.data ?? '')
      .where((text) => text.startsWith('今日限次已用尽。'))
      .toList();
  expect(rows, hasLength(1));
  return rows.single;
}

void main() {
  _T24LiveBinding().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;

  testWidgets('额度用尽后从复盘页查看会员页重置时间，返回后草稿仍在', (tester) async {
    final environment = Platform.environment;
    final rawOrigin = environment['T24_ORIGIN'];
    final rawTokens = environment['T24_TOKENS'];
    final fixtureSecret = environment['T24_FIXTURE'];
    expect(rawOrigin, isNotNull);
    expect(rawTokens, isNotNull);
    expect(fixtureSecret, isNotNull);
    final origin = Uri.parse(rawOrigin!);
    final secret = fixtureSecret!;
    expect(origin.scheme, 'http');
    expect(origin.host, '127.0.0.1');
    expect(origin.hasPort, isTrue);

    final directory = await Directory.systemTemp.createTemp('t24-live-');
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
    final reviews = ApiReviews(api, scope);
    final memberStore = MemberStore(api, scope, port: _NoPurchasePort());
    final localOffset = DateTime.now().timeZoneOffset.inMinutes;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      MaterialApp(
        home: ReviewPage(reviews),
        routes: {'/membership': (_) => MemberPage(memberStore)},
      ),
    );

    // ACTUAL PRODUCT UI: one synthetic five-part draft on the formal page.
    await _waitForText(tester, '发生了什么');
    await tester.enterText(
      find.byKey(const Key('review.happened')),
      '同事在会上打断了我的汇报。',
    );
    await tester.pump();
    await _tapText(tester, '下一步');
    await _waitForKey(tester, 'review.myFeeling');
    await tester.enterText(find.byKey(const Key('review.myFeeling')), '着急，也有点难堪。');
    await tester.enterText(
      find.byKey(const Key('review.theirFeeling')),
      '他可能担心时间不够。',
    );
    await tester.pump();
    await _tapText(tester, '下一步');
    await _waitForKey(tester, 'review.myAction');
    await tester.enterText(find.byKey(const Key('review.myAction')), '我先说完');
    await tester.pump();
    await _tapText(tester, '下一步');
    await _waitForKey(tester, 'review.nextAction');
    await tester.enterText(
      find.byKey(const Key('review.nextAction')),
      '先停一下，问他刚才想说什么。',
    );
    await tester.pump();
    await _waitForText(tester, '草稿已加密保存在本机');

    // ACTUAL PRODUCT UI: the one explicit submit. The real service refuses with
    // its business 429 and no retry_at, so no local midnight is invented.
    await _tapText(tester, '提交 AI 复盘');
    await _waitForText(tester, '今日文字复盘剩余 0 次，请在额度重置后再试。');
    expect(find.text('重试原请求'), findsNothing);
    expect(find.textContaining('重置（本地时间）'), findsNothing);
    await _checkpoint(tester, origin, secret, 'quota_shown', {
      'error_text': '今日文字复盘剩余 0 次，请在额度重置后再试。',
      'local_offset_minutes': localOffset,
    });

    // ACTUAL PRODUCT UI: an explicit tap opens the production MemberPage, whose
    // MemberStore reads the same /v1/entitlements. Only the review row is full.
    await _tapText(tester, '查看额度与重置时间');
    await _waitForText(tester, '今日额度');
    await _waitForText(tester, '文字复盘 · 剩余 0 次');
    expect(find.text('对练 · 剩余 3 次'), findsOneWidget);
    expect(find.text('回复助手 · 剩余 3 次'), findsOneWidget);
    expect(find.textContaining('今日限次已用尽'), findsOneWidget);
    final resetText = _resetSubtitleUnder(tester, '文字复盘 · 剩余 0 次');
    expect(resetText, contains('重置（本地时间）'));
    await _checkpoint(tester, origin, secret, 'member_view', {
      'review_title': '文字复盘 · 剩余 0 次',
      'reset_text': resetText,
      'practice_title': '对练 · 剩余 3 次',
      'reply_title': '回复助手 · 剩余 3 次',
      'exhausted_rows': 1,
      'local_offset_minutes': localOffset,
    });

    // ACTUAL PRODUCT UI: system back returns with every original field intact,
    // no automatic submit and a fresh, still-disabled-until-tapped submission.
    await tester.pageBack();
    await tester.pump();
    // The pushed route stays in the tree during the pop animation; wait for it
    // to leave before tapping controls underneath it.
    await _waitUntil(
      tester,
      () => find.text('今日额度').evaluate().isEmpty,
      label: 'member page closed',
    );
    await _waitForText(tester, '提交 AI 复盘');
    expect(find.text('查看额度与重置时间'), findsNothing);
    expect(_fieldText(tester, 'review.nextAction'), '先停一下，问他刚才想说什么。');
    await _tapText(tester, '上一步');
    await _waitForKey(tester, 'review.myAction');
    expect(_fieldText(tester, 'review.myAction'), '我先说完');
    await _tapText(tester, '上一步');
    await _waitForKey(tester, 'review.theirFeeling');
    expect(_fieldText(tester, 'review.myFeeling'), '着急，也有点难堪。');
    expect(_fieldText(tester, 'review.theirFeeling'), '他可能担心时间不够。');
    await _tapText(tester, '上一步');
    await _waitForKey(tester, 'review.happened');
    expect(_fieldText(tester, 'review.happened'), '同事在会上打断了我的汇报。');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pump();
    await _checkpoint(tester, origin, secret, 'returned', {
      'local_offset_minutes': localOffset,
    });

    // The submit control is available again, but nothing was sent without a tap.
    await _tapText(tester, '下一步');
    await _waitForKey(tester, 'review.myFeeling');
    await _tapText(tester, '下一步');
    await _waitForKey(tester, 'review.myAction');
    await _tapText(tester, '下一步');
    await _waitForKey(tester, 'review.nextAction');
    await _waitForText(tester, '提交 AI 复盘');
    final submit = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('提交 AI 复盘'),
        matching: find.byWidgetPredicate((widget) => widget is FilledButton),
      ),
    );
    expect(submit.onPressed, isNotNull);
    debugPrint('T24_STAGE complete');
  });
}
