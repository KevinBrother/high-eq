import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/marks/page.dart';
import 'package:high_eq/features/reviews/page.dart';
import 'package:http/http.dart' as http;

class _VolatileSecret implements SecretStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> replace(String? v) async => value = v;
}

// The real product routes run in the Go test's loopback server; only that
// socket may be dialled from the card sandbox.
class _T32ALiveBinding extends LiveTestWidgetsFlutterBinding {
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

Future<void> _tapMarkAction(WidgetTester tester, String text) async {
  final target = find.widgetWithText(TextButton, text);
  await _waitUntil(
    tester,
    () => target.evaluate().isNotEmpty,
    label: 'mark action "$text"',
  );
  await tester.ensureVisible(target.last);
  await tester.pump();
  await tester.tap(target.last);
  await tester.pump();
}

int _int(Map<String, dynamic> snapshot, String key) {
  final value = snapshot[key];
  if (value is! int) throw StateError('fixture "$key" is not an integer');
  return value;
}

bool _bool(Map<String, dynamic> snapshot, String key) {
  final value = snapshot[key];
  if (value is! bool) throw StateError('fixture "$key" is not a boolean');
  return value;
}

String _string(Map<String, dynamic> snapshot, String key) {
  final value = snapshot[key];
  if (value is! String) throw StateError('fixture "$key" is not a string');
  return value;
}

Future<Map<String, dynamic>> _checkpoint(
  WidgetTester tester,
  Uri origin,
  String fixtureSecret,
  String stage,
) async {
  // FIXTURE ONLY: a readback of the same running service, not a product route
  // and not a stand-in for any page submission.
  final response = await tester.runAsync(() => http.post(
    origin.replace(path: '/__t32a/checkpoint'),
    headers: {
      'content-type': 'application/json',
      'x-t32a-fixture': fixtureSecret,
    },
    body: jsonEncode({'stage': stage}),
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

void _expectEmptyReview(Map<String, dynamic> snapshot) {
  expect(_int(snapshot, 'marks'), 1);
  expect(_string(snapshot, 'scene'), 'work');
  expect(_int(snapshot, 'reviews'), 0);
  expect(_int(snapshot, 'remaining'), 1);
  expect(_int(snapshot, 'used'), 2);
  expect(_int(snapshot, 'ledger'), 0);
}

void main() {
  _T32ALiveBinding().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;

  testWidgets('手动标记到文字复盘走真实页面与同一服务', (tester) async {
    final environment = Platform.environment;
    final rawOrigin = environment['T32A_ORIGIN'];
    final rawTokens = environment['T32A_TOKENS'];
    final fixtureSecret = environment['T32A_FIXTURE'];
    expect(rawOrigin, isNotNull);
    expect(rawTokens, isNotNull);
    expect(fixtureSecret, isNotNull);
    final origin = Uri.parse(rawOrigin!);
    final secret = fixtureSecret!;
    expect(origin.scheme, 'http');
    expect(origin.host, '127.0.0.1');
    expect(origin.hasPort, isTrue);

    final directory = await Directory.systemTemp.createTemp('t32a-live-');
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
    final book = MarkBook(api, scope);
    final reviews = ApiReviews(api, scope);

    Widget page() => MaterialApp(
      home: MarksPage(book),
      routes: {
        '/marks/review': (context) => ReviewPage(
          reviews,
          prefill: ReviewPrefill.tryFromRoute(
            ModalRoute.of(context)?.settings.arguments,
          ),
        ),
      },
    );

    await tester.pumpWidget(page());
    await _waitForText(tester, '还没有标记。下次想暂停一下时，点上方按钮就好。');

    // ACTUAL PRODUCT UI: one mark, then its optional scene.
    await _tapText(tester, '我上头了');
    await _waitForText(tester, '已记下 · 一分钟内的点击合为一条');
    await _tapText(tester, '补充信息');
    await _waitForText(tester, '补充标记');
    await _tapText(tester, '不指定场景');
    await _tapText(tester, '职场');
    await _tapText(tester, '保存');
    await _waitForText(tester, '补充已保存');
    final afterMark = await _checkpoint(
      tester,
      origin,
      secret,
      'mark_scene',
    );
    _expectEmptyReview(afterMark);

    // ACTUAL PRODUCT UI: the history entry opens the real review route with the
    // mark prefill. Filling all four steps only saves an encrypted local draft.
    await _tapMarkAction(tester, '写复盘');
    await _waitForText(tester, '从标记开始');
    await _waitForText(tester, '场景：职场');
    await tester.enterText(
      find.byKey(const Key('review.happened')),
      '同事说话时我打断了他。',
    );
    await tester.pump();
    await _tapText(tester, '下一步');
    await _waitForKey(tester, 'review.myFeeling');
    await tester.enterText(
      find.byKey(const Key('review.myFeeling')),
      '着急',
    );
    await tester.enterText(
      find.byKey(const Key('review.theirFeeling')),
      '可能有点意外',
    );
    await tester.pump();
    await _tapText(tester, '下一步');
    await _waitForKey(tester, 'review.myAction');
    await tester.enterText(
      find.byKey(const Key('review.myAction')),
      '我先说完',
    );
    await tester.pump();
    await _tapText(tester, '下一步');
    await _waitForKey(tester, 'review.nextAction');
    await tester.enterText(
      find.byKey(const Key('review.nextAction')),
      '先停一下，问他刚才想说什么。',
    );
    await tester.pump();
    await _waitForText(tester, '草稿已加密保存在本机');

    // ACTUAL PRODUCT UI: leave and re-enter. The draft comes back, and no
    // review has reached the service or the quota.
    await tester.pageBack();
    await tester.pump();
    await _waitForText(tester, '我的标记');
    await _tapMarkAction(tester, '写复盘');
    await _waitForText(tester, '从标记开始');
    await _waitUntil(
      tester,
      () {
        final field = find.byKey(const Key('review.happened'));
        if (field.evaluate().isEmpty) return false;
        return tester.widget<TextField>(field).controller?.text ==
            '同事说话时我打断了他。';
      },
      label: 'restored local draft',
    );
    final afterDraft = await _checkpoint(
      tester,
      origin,
      secret,
      'draft_reopened',
    );
    _expectEmptyReview(afterDraft);

    // ACTUAL PRODUCT UI: continue from the restored draft and submit once.
    await _tapText(tester, '下一步');
    await _waitForKey(tester, 'review.myFeeling');
    await _tapText(tester, '下一步');
    await _waitForKey(tester, 'review.myAction');
    await _tapText(tester, '下一步');
    await _waitForKey(tester, 'review.nextAction');
    await _tapText(tester, '提交 AI 复盘');
    await _waitForText(tester, '这次复盘');
    final afterSubmit = await _checkpoint(
      tester,
      origin,
      secret,
      'submitted',
    );
    expect(_int(afterSubmit, 'marks'), 1);
    expect(_int(afterSubmit, 'reviews'), 1);
    expect(_int(afterSubmit, 'review_mark_matches'), 1);
    expect(_int(afterSubmit, 'reviews_with_signal'), 0);
    expect(_int(afterSubmit, 'scored'), 1);
    expect(_int(afterSubmit, 'remaining'), 0);
    expect(_int(afterSubmit, 'used'), 3);
    expect(_int(afterSubmit, 'ledger'), 1);
    expect(_bool(afterSubmit, 'readback_review'), isTrue);
    expect(_bool(afterSubmit, 'submitted_mark_match'), isTrue);
    expect(_string(afterSubmit, 'submitted_scene'), 'work');
    expect(_bool(afterSubmit, 'submitted_time_match'), isTrue);

    // ACTUAL PRODUCT UI: return to marks and see the same history. A second
    // mark click stays free (deduplicated or a new free mark) and does not
    // debit again.
    await tester.pageBack();
    await tester.pump();
    await _waitForText(tester, '我的标记');
    await _waitForText(tester, '我上头了');
    await _waitUntil(
      tester,
      () => find.textContaining('职场').evaluate().isNotEmpty,
      label: 'own mark history',
    );
    await tester.tap(find.byTooltip('刷新历史'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    expect(find.text('重新加载历史'), findsNothing);
    await _waitUntil(
      tester,
      () => find.textContaining('职场').evaluate().isNotEmpty,
      label: 'refreshed mark history',
    );
    await _tapText(tester, '我上头了');
    await _waitForText(tester, '已记下 · 一分钟内的点击合为一条');
    final backOnMarks = await _checkpoint(
      tester,
      origin,
      secret,
      'returned_mark',
    );
    expect(_int(backOnMarks, 'marks'), greaterThanOrEqualTo(1));
    expect(_string(backOnMarks, 'scene'), 'work');
    expect(_int(backOnMarks, 'reviews'), 1);
    expect(_int(backOnMarks, 'review_mark_matches'), 1);
    expect(_int(backOnMarks, 'remaining'), 0);
    expect(_int(backOnMarks, 'used'), 3);
    expect(_int(backOnMarks, 'ledger'), 1);
    expect(_bool(backOnMarks, 'submitted_mark_match'), isTrue);
    debugPrint('T32A_STAGE complete');
  });
}
