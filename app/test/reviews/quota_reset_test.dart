import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/features/contacts/scene.dart';
import 'package:high_eq/features/reviews/model.dart';
import 'package:high_eq/features/reviews/page.dart';

// One synthetic form submission returns the same 429 body the review handler
// sends for an exhausted allowance. No server, model or store is touched.

class _QuotaReviews implements ReviewRepository {
  ReviewDraft? stored;
  final saved = <ReviewDraft>[];
  final submitted = <ReviewDraft>[];
  late Completer<ReviewAttempt> response;

  @override
  Future<ReviewDraft?> loadDraft() async => stored;

  @override
  Future<void> saveDraft(ReviewDraft draft) async {
    saved.add(draft);
    stored = draft;
  }

  @override
  Future<void> discardDraft(ReviewDraft submitted) async {
    if (stored?.requestId == submitted.requestId &&
        stored!.sameSubmission(submitted)) {
      stored = null;
    }
  }

  @override
  Future<ReviewAttempt> submit(ReviewDraft draft) {
    submitted.add(draft);
    response = Completer<ReviewAttempt>();
    return response.future;
  }

  @override
  Future<List<ReviewPerson>> people() async => const [];

  @override
  Future<ReviewHistoryPage> history({
    String? cursor,
    int limit = 20,
    Scene? scene,
    String? contactId,
  }) async => const ReviewHistoryPage(items: [], next: null);
}

Future<void> _tap(WidgetTester tester, String text) async {
  final target = find.text(text).last;
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String key, String value) async {
  final field = find.byKey(Key(key));
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
  await tester.pumpAndSettle();
}

Future<void> _fillAll(WidgetTester tester) async {
  await _enter(tester, 'review.happened', '同事在会上打断了我的汇报。');
  await _tap(tester, '下一步');
  await _enter(tester, 'review.myFeeling', '我有点着急，也有点难堪。');
  await _enter(tester, 'review.theirFeeling', '他可能担心时间不够。');
  await _tap(tester, '下一步');
  await _enter(tester, 'review.myAction', '我提高声音说：你先听我说完。');
  await _tap(tester, '下一步');
  await _enter(tester, 'review.nextAction', '下次我先停一下，问他想补充什么。');
}

Future<void> _pump(WidgetTester tester, _QuotaReviews repo) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ReviewPage(key: ValueKey(repo), repo),
      routes: {
        '/membership': (_) => Scaffold(
          appBar: AppBar(),
          body: const Text('会员页占位'),
        ),
      },
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _submitQuota(WidgetTester tester, _QuotaReviews repo) async {
  await _fillAll(tester);
  await _tap(tester, '提交 AI 复盘');
  expect(repo.submitted, hasLength(1));
  repo.response.completeError(
    const ApiFailure(429, 'quota_exceeded', '今日该功能的次数已用完，请在重置后再试', true),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('429 显示本项剩余 0，不诱导原请求重试，可主动查看额度', (tester) async {
    final repo = _QuotaReviews();
    await _pump(tester, repo);
    await _submitQuota(tester, repo);

    expect(find.textContaining('今日文字复盘剩余 0 次'), findsOneWidget);
    expect(find.text('今日复盘次数已用完，请稍后再来。'), findsNothing);
    expect(find.text('重试原请求'), findsNothing);
    expect(find.text('查看额度与重置时间'), findsOneWidget);
    expect(find.text('会员页占位'), findsNothing);
    expect(repo.submitted, hasLength(1));

    final draft = repo.stored;
    expect(draft, isNotNull);
    expect(draft!.happened, '同事在会上打断了我的汇报。');
    expect(draft.nextAction, '下次我先停一下，问他想补充什么。');
  });

  testWidgets('查看额度后返回仍保留原复盘草稿且不自动重发提交', (tester) async {
    final repo = _QuotaReviews();
    await _pump(tester, repo);
    await _submitQuota(tester, repo);
    final requestId = repo.submitted.single.requestId;

    await _tap(tester, '查看额度与重置时间');
    expect(find.text('会员页占位'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.text('提交 AI 复盘'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('review.nextAction')))
          .controller!
          .text,
      '下次我先停一下，问他想补充什么。',
    );
    expect(repo.submitted, hasLength(1));
    expect(repo.submitted.single.requestId, requestId);
    expect(repo.stored?.requestId, requestId);
    expect(repo.stored?.sameSubmission(repo.submitted.single), isTrue);
  });

  testWidgets('仅当服务端给出可信重置时间时才显示本地时间', (tester) async {
    final withTime = _QuotaReviews();
    await _pump(tester, withTime);
    await _fillAll(tester);
    await _tap(tester, '提交 AI 复盘');
    withTime.response.completeError(
      ApiFailure(
        429,
        'quota_exceeded',
        '今日该功能的次数已用完，请在重置后再试',
        true,
        DateTime(2026, 11, 27, 8, 5),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('11 月 27 日 08:05 重置（本地时间）'), findsOneWidget);

    final noTime = _QuotaReviews();
    await _pump(tester, noTime);
    await _fillAll(tester);
    await _tap(tester, '提交 AI 复盘');
    noTime.response.completeError(
      const ApiFailure(429, 'quota_exceeded', '今日该功能的次数已用完，请在重置后再试', true),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('今日文字复盘剩余 0 次'), findsOneWidget);
    expect(find.textContaining('重置（本地时间）'), findsNothing);
    expect(find.textContaining('请在额度重置后再试'), findsOneWidget);
  });

  testWidgets('审核故障仍按原逻辑提供重试且不显示额度链接', (tester) async {
    final repo = _QuotaReviews();
    await _pump(tester, repo);
    await _fillAll(tester);
    await _tap(tester, '提交 AI 复盘');
    repo.response.completeError(
      const ApiFailure(503, 'moderation_unavailable', '内部审核片段不可展示', true),
    );
    await tester.pumpAndSettle();

    expect(find.text('服务暂不可用，可重试'), findsOneWidget);
    expect(find.text('重试原请求'), findsOneWidget);
    expect(find.text('查看额度与重置时间'), findsNothing);
    expect(find.textContaining('剩余 0 次'), findsNothing);
  });
}
