import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/features/contacts/scene.dart';
import 'package:high_eq/features/reviews/book.dart';
import 'package:high_eq/features/reviews/model.dart';
import 'package:high_eq/features/reviews/page.dart';

class _ConsentReviews extends _FakeReviews implements ReviewConsent {
  _ConsentReviews({this.grantSucceeds = true});

  bool permission = false;
  final bool grantSucceeds;
  int allowedCalls = 0;
  int grantCalls = 0;
  Completer<void>? allowedGate;

  @override
  Future<bool> allowed() async {
    allowedCalls++;
    final gate = allowedGate;
    if (gate != null) {
      allowedGate = null;
      await gate.future;
    }
    return permission;
  }

  @override
  Future<void> grant() async {
    grantCalls++;
    if (!grantSucceeds) throw StateError('synthetic grant failure');
    permission = true;
  }
}

class _FakeReviews implements ReviewRepository {
  ReviewDraft? stored;
  final saved = <ReviewDraft>[];
  final submitted = <ReviewDraft>[];
  final historyCalls =
      <({String? cursor, int limit, Scene? scene, String? contactId})>[];
  final peopleCalls = <void>[];
  late Completer<ReviewAttempt> response;
  ReviewHistoryPage Function(String? cursor)? page;
  Object? loadError;
  Completer<void>? saveGate;
  Completer<void>? historyGate;
  int discardCalls = 0;
  Future<void> _saveTail = Future.value();

  @override
  Future<ReviewDraft?> loadDraft() async {
    await _saveTail;
    if (loadError != null) throw loadError!;
    return stored;
  }

  @override
  Future<void> saveDraft(ReviewDraft draft) {
    saved.add(draft);
    final next = _saveTail.then((_) async {
      final gate = saveGate;
      if (gate != null) {
        saveGate = null;
        await gate.future;
      }
      stored = draft;
    });
    _saveTail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  @override
  Future<void> discardDraft(ReviewDraft submitted) async {
    discardCalls++;
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
  Future<List<ReviewPerson>> people() async {
    peopleCalls.add(null);
    return const [ReviewPerson(id: 'contact-1', name: '小安')];
  }

  @override
  Future<ReviewHistoryPage> history({
    String? cursor,
    int limit = 20,
    Scene? scene,
    String? contactId,
  }) async {
    historyCalls.add((
      cursor: cursor,
      limit: limit,
      scene: scene,
      contactId: contactId,
    ));
    final gate = historyGate;
    if (gate != null) {
      historyGate = null;
      await gate.future;
    }
    return page?.call(cursor) ?? const ReviewHistoryPage(items: [], next: null);
  }
}

ReviewRecord _record(ReviewDraft submitted, {String id = 'review-1'}) =>
    ReviewRecord(
      id: id,
      submitted: submitted,
      repairPhrase: '刚才我打断了你，你愿意把话说完吗？',
      score: ReviewScore(
        scoreId: 'score-1',
        total: 85,
        observation: const ScoreLine(score: 25, reason: '说清了具体行动'),
        feeling: const ScoreLine(score: 20, reason: '感受可以更直接'),
        need: const ScoreLine(score: 20, reason: '需要再明确一点'),
        request: const ScoreLine(score: 20, reason: '邀请对方选择'),
        readOthers: const LevelLine(level: 4, reason: '注意到了停顿'),
        selfManagement: const LevelLine(level: 3, reason: '语气有所缓和'),
        relationship: const LevelLine(level: 4, reason: '给了对方空间'),
        betterVersion: '刚才我打断了你，你愿意把话说完吗？',
        whyBetter: '承认了具体行动，也把选择交还对方。',
      ),
    );

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

Future<void> _pump(
  WidgetTester tester,
  _FakeReviews repo, {
  ReviewPrefill? prefill,
}) async {
  await tester.pumpWidget(
    MaterialApp(home: ReviewPage(repo, prefill: prefill)),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('T32A 路由参数可安全转换为复盘预填', () {
    final prefill = ReviewPrefill.tryFromRoute({
      'mark_id': 'mark-1',
      'occurred_at': '2026-11-21T11:00:00.000Z',
      'contact_id': 'contact-1',
      'scene': 'family',
    });
    expect(prefill?.markId, 'mark-1');
    expect(prefill?.occurredAt, DateTime.utc(2026, 11, 21, 11));
    expect(prefill?.contactId, 'contact-1');
    expect(prefill?.scene, Scene.family);
    expect(ReviewPrefill.tryFromRoute({'scene': 'family'}), isNull);
    expect(ReviewPrefill.tryFromRoute(null), isNull);
  });

  testWidgets('分步填写会保存草稿，重开恢复输入且尚未联网提交', (tester) async {
    final repo = _FakeReviews();
    await _pump(tester, repo);
    expect(find.text('发生了什么'), findsOneWidget);
    expect(find.byKey(const Key('review.myFeeling')), findsNothing);

    await _enter(tester, 'review.happened', '我在饭桌上突然沉默了。');
    expect(repo.saved, isNotEmpty);
    expect(repo.saved.last.happened, '我在饭桌上突然沉默了。');
    expect(repo.submitted, isEmpty);

    await tester.pumpWidget(const SizedBox());
    final reopened = _FakeReviews()..stored = repo.stored;
    await _pump(tester, reopened);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('review.happened')))
          .controller!
          .text,
      '我在饭桌上突然沉默了。',
    );
    expect(reopened.submitted, isEmpty);
  });

  testWidgets('前一次保存阻塞时，后续输入仍会排队而不是被页面丢弃', (tester) async {
    final repo = _FakeReviews();
    await _pump(tester, repo);

    final gate = Completer<void>();
    repo.saveGate = gate;
    await _enter(tester, 'review.happened', '第一次输入');
    await _enter(tester, 'review.happened', '第二次输入');

    expect(repo.saved.map((draft) => draft.happened), ['第一次输入', '第二次输入']);

    gate.complete();
    await tester.pumpAndSettle();
    expect(repo.stored?.happened, '第二次输入');
  });

  testWidgets('T32A 预填展示时间、对象和场景，并随请求发送关联字段', (tester) async {
    final repo = _FakeReviews();
    final prefill = ReviewPrefill(
      markId: 'mark-1',
      occurredAt: DateTime.parse('2026-11-21T19:00:00+08:00'),
      contactId: 'contact-1',
      scene: Scene.family,
    );
    await _pump(tester, repo, prefill: prefill);
    expect(find.text('从标记开始'), findsOneWidget);
    expect(find.textContaining('2026'), findsOneWidget);
    expect(find.textContaining('家人'), findsWidgets);
    expect(find.textContaining('小安'), findsOneWidget);
    expect(find.textContaining('不会读取或上传录音'), findsOneWidget);

    await _fillAll(tester);
    await _tap(tester, '提交 AI 复盘');
    final sent = repo.submitted.single.toWire();
    expect(sent['mark_id'], 'mark-1');
    expect(sent['occurred_at'], '2026-11-21T11:00:00.000Z');
    expect(sent['contact_id'], 'contact-1');
    expect(sent['scene'], 'family');
    expect(sent.keys.where((key) => key.contains('audio')), isEmpty);
  });

  testWidgets('重开旧格式已尝试草稿会先保存请求键，再沿用原 request_id 提交', (tester) async {
    const requestId = '85b72033-9f07-4bbc-8567-fc31f26508ab';
    final original = ReviewDraft(
      requestId: requestId,
      happened: '上次已经提交过，但响应没有回来。',
      myFeeling: '有些着急。',
      theirFeeling: '对方可能也在等结果。',
      myAction: '我连续点了提交。',
      nextAction: '先查看原请求，再决定是否修改。',
    );
    final restored = ReviewDraft.fromCacheJson({
      ...original.toWire(),
      'attempted': true,
    });
    final repo = _FakeReviews()..stored = restored;
    await _pump(tester, repo);
    await _tap(tester, '下一步');
    await _tap(tester, '下一步');
    await _tap(tester, '下一步');

    final gate = Completer<void>();
    repo.saveGate = gate;
    await _tap(tester, '提交 AI 复盘');

    expect(repo.saved.single.requestId, requestId);
    expect(
      repo.saved.single.possibleAttempts.single.toWire(),
      restored.toWire(),
    );
    expect(repo.submitted, isEmpty);

    gate.complete();
    await tester.pumpAndSettle();
    expect(repo.submitted.single.requestId, requestId);
    expect(repo.submitted.single.toWire(), restored.toWire());
    repo.response.complete(const ReviewProcessing());
    await tester.pumpAndSettle();
  });

  testWidgets('重开已尝试的草稿后修改内容仍保留原键，保存重开后提交才换新 request_id', (tester) async {
    const requestId = '85b72033-9f07-4bbc-8567-fc31f26508ab';
    final original = ReviewDraft(
      requestId: requestId,
      happened: '上次已经提交过，但响应没有回来。',
      myFeeling: '有些着急。',
      theirFeeling: '对方可能也在等结果。',
      myAction: '我连续点了提交。',
      nextAction: '先查看原请求，再决定是否修改。',
    );
    final restored = original.copyWith(possibleAttempts: [original]);
    final repo = _FakeReviews()..stored = restored;
    await _pump(tester, repo);

    await _enter(tester, 'review.happened', '我修改了这次经过。');

    expect(repo.saved.last.requestId, requestId);
    expect(repo.saved.last.possibleAttempts.single.happened, restored.happened);
    expect(repo.saved.last.happened, '我修改了这次经过。');
    expect(repo.submitted, isEmpty);

    await tester.pumpWidget(const SizedBox());
    final reopened = _FakeReviews()..stored = repo.stored;
    await _pump(tester, reopened);
    await _tap(tester, '下一步');
    await _tap(tester, '下一步');
    await _tap(tester, '下一步');
    await _tap(tester, '提交 AI 复盘');

    final sent = reopened.submitted.single;
    expect(sent.requestId, isNot(requestId));
    expect(sent.happened, '我修改了这次经过。');
    expect(reopened.stored?.toWire(), sent.toWire());
    expect(reopened.stored?.possibleAttempts.map((entry) => entry.toWire()), [
      original.toWire(),
      sent.toWire(),
    ]);
    reopened.response.complete(const ReviewProcessing());
    await tester.pumpAndSettle();
  });

  testWidgets('重开已尝试的草稿后改字再撤销，保存重开后仍沿用原 request_id', (tester) async {
    const requestId = '85b72033-9f07-4bbc-8567-fc31f26508ab';
    final original = ReviewDraft(
      requestId: requestId,
      happened: '上次已经提交过，但响应没有回来。',
      myFeeling: '有些着急。',
      theirFeeling: '对方可能也在等结果。',
      myAction: '我连续点了提交。',
      nextAction: '先查看原请求，再决定是否修改。',
    );
    final restored = original.copyWith(possibleAttempts: [original]);
    final repo = _FakeReviews()..stored = restored;
    await _pump(tester, repo);

    await _enter(tester, 'review.happened', '临时改成另一段经过。');
    expect(repo.saved.last.requestId, requestId);
    expect(repo.saved.last.possibleAttempts.single.happened, restored.happened);

    await _enter(tester, 'review.happened', restored.happened);
    expect(repo.saved.last.requestId, requestId);
    expect(repo.saved.last.possibleAttempts.single.happened, restored.happened);

    await tester.pumpWidget(const SizedBox());
    final reopened = _FakeReviews()..stored = repo.stored;
    await _pump(tester, reopened);
    await _tap(tester, '下一步');
    await _tap(tester, '下一步');
    await _tap(tester, '下一步');
    await _tap(tester, '提交 AI 复盘');

    expect(reopened.submitted.single.requestId, requestId);
    expect(reopened.submitted.single.toWire(), restored.toWire());
    reopened.response.complete(const ReviewProcessing());
    await tester.pumpAndSettle();
  });

  testWidgets('重开已尝试的草稿后只补空白仍沿用原 request_id', (tester) async {
    const requestId = '85b72033-9f07-4bbc-8567-fc31f26508ab';
    final original = ReviewDraft(
      requestId: requestId,
      happened: '上次已经提交过，但响应没有回来。',
      myFeeling: '有些着急。',
      theirFeeling: '对方可能也在等结果。',
      myAction: '我连续点了提交。',
      nextAction: '先查看原请求，再决定是否修改。',
    );
    final restored = original.copyWith(possibleAttempts: [original]);
    final repo = _FakeReviews()..stored = restored;
    await _pump(tester, repo);
    await _tap(tester, '下一步');
    await _tap(tester, '下一步');
    await _tap(tester, '下一步');

    await _enter(tester, 'review.nextAction', '先查看原请求，再决定是否修改。   ');

    expect(repo.saved.last.requestId, requestId);
    expect(repo.saved.last.nextAction, restored.nextAction);

    await _tap(tester, '提交 AI 复盘');
    expect(repo.submitted.single.requestId, requestId);
    expect(repo.submitted.single.toWire(), restored.toWire());
    repo.response.complete(const ReviewProcessing());
    await tester.pumpAndSettle();
  });

  testWidgets('新标记遇到旧草稿时先选择，不静默替换', (tester) async {
    final repo = _FakeReviews()
      ..stored = ReviewDraft(
        requestId: '85b72033-9f07-4bbc-8567-fc31f26508ab',
        happened: '上次还没写完的经过',
        myFeeling: '',
        theirFeeling: '',
        myAction: '',
        nextAction: '',
      );
    final prefill = ReviewPrefill(
      markId: 'mark-new',
      occurredAt: DateTime.parse('2026-11-21T20:00:00+08:00'),
      scene: Scene.work,
    );

    await _pump(tester, repo, prefill: prefill);
    expect(find.text('发现一份未完成的草稿'), findsOneWidget);
    expect(find.text('继续上次草稿'), findsOneWidget);
    expect(find.text('从这次标记开始'), findsOneWidget);
    expect(repo.saved, isEmpty);

    await _tap(tester, '继续上次草稿');
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('review.happened')))
          .controller!
          .text,
      '上次还没写完的经过',
    );
    expect(find.text('从标记开始'), findsNothing);
  });

  testWidgets('选择从新标记开始后才替换旧草稿并保留预填', (tester) async {
    final repo = _FakeReviews()
      ..stored = ReviewDraft(
        requestId: '85b72033-9f07-4bbc-8567-fc31f26508ab',
        happened: '上次还没写完的经过',
        myFeeling: '',
        theirFeeling: '',
        myAction: '',
        nextAction: '',
      );
    final prefill = ReviewPrefill(
      markId: 'mark-new',
      occurredAt: DateTime.parse('2026-11-21T20:00:00+08:00'),
      scene: Scene.work,
    );

    await _pump(tester, repo, prefill: prefill);
    await _tap(tester, '从这次标记开始');

    expect(
      tester
          .widget<TextField>(find.byKey(const Key('review.happened')))
          .controller!
          .text,
      isEmpty,
    );
    expect(find.text('从标记开始'), findsOneWidget);
    expect(repo.saved, hasLength(1));
    expect(repo.saved.single.markId, 'mark-new');
    expect(repo.saved.single.scene, Scene.work);
    expect(
      repo.saved.single.requestId,
      isNot('85b72033-9f07-4bbc-8567-fc31f26508ab'),
    );
  });

  testWidgets('503 只显示固定文案；202 与 503 均沿用原 request_id，成功后分流结果', (tester) async {
    final repo = _FakeReviews();
    await _pump(tester, repo);
    await _fillAll(tester);
    await _tap(tester, '提交 AI 复盘');
    expect(repo.submitted, hasLength(1));
    final original = repo.submitted.single;
    repo.response.completeError(
      const ApiFailure(503, 'moderation_unavailable', '内部审核片段不可展示', true),
    );
    await tester.pumpAndSettle();
    expect(find.text('服务暂不可用，可重试'), findsOneWidget);
    expect(find.text('内部审核片段不可展示'), findsNothing);
    expect(find.textContaining('12356'), findsNothing);

    await _tap(tester, '重试原请求');
    expect(repo.submitted, hasLength(2));
    expect(repo.submitted.last.requestId, original.requestId);
    expect(repo.submitted.last.toWire(), original.toWire());
    repo.response.complete(const ReviewProcessing());
    await tester.pumpAndSettle();
    expect(find.textContaining('仍在处理中'), findsOneWidget);

    await _tap(tester, '查看原请求结果');
    expect(repo.submitted, hasLength(3));
    expect(repo.submitted.last.requestId, original.requestId);
    repo.response.complete(ReviewReady(_record(original)));
    await tester.pumpAndSettle();
    expect(find.textContaining('85'), findsOneWidget);
    expect(find.textContaining('承认了具体行动'), findsOneWidget);
    expect(find.text('刚才我打断了你，你愿意把话说完吗？'), findsWidgets);
    expect(repo.stored, isNull);
  });

  testWidgets('重试原请求前重新确认授权，撤权后拒绝不会再次发送正文', (tester) async {
    final repo = _ConsentReviews()..permission = true;
    await _pump(tester, repo);
    await _fillAll(tester);
    await _tap(tester, '提交 AI 复盘');
    final original = repo.submitted.single;
    repo.response.completeError(
      const ApiFailure(503, 'moderation_unavailable', '内部审核片段不可展示', true),
    );
    await tester.pumpAndSettle();

    repo.permission = false;
    await _tap(tester, '重试原请求');
    expect(find.text('提交前确认'), findsOneWidget);
    expect(repo.submitted, hasLength(1));

    await _tap(tester, '暂不提交');
    expect(repo.submitted, hasLength(1));

    await _tap(tester, '重试原请求');
    await _tap(tester, '同意并提交');
    expect(repo.submitted, hasLength(2));
    expect(repo.submitted.last.requestId, original.requestId);
    repo.response.complete(const ReviewProcessing());
    await tester.pumpAndSettle();
  });

  testWidgets('等待重试授权时修改内容，不会提交或覆盖新稿', (tester) async {
    final repo = _ConsentReviews()..permission = true;
    await _pump(tester, repo);
    await _fillAll(tester);
    await _tap(tester, '提交 AI 复盘');
    final original = repo.submitted.single;
    repo.response.completeError(
      const ApiFailure(503, 'moderation_unavailable', '内部审核片段不可展示', true),
    );
    await tester.pumpAndSettle();

    final gate = Completer<void>();
    repo.allowedGate = gate;
    await _tap(tester, '重试原请求');
    await _enter(tester, 'review.nextAction', '我先确认对方是否还需要补充。');
    final replacement = repo.saved.last;
    expect(replacement.requestId, original.requestId);
    expect(replacement.possibleAttempts.single.nextAction, original.nextAction);

    gate.complete();
    await tester.pumpAndSettle();

    expect(repo.submitted, hasLength(1));
    expect(repo.stored?.requestId, original.requestId);
    expect(repo.stored?.nextAction, '我先确认对方是否还需要补充。');
    expect(
      repo.stored?.possibleAttempts.single.nextAction,
      original.nextAction,
    );
  });

  testWidgets('HTTP 500 不承诺未扣次，并允许用原请求重试', (tester) async {
    final repo = _FakeReviews();
    await _pump(tester, repo);
    await _fillAll(tester);
    await _tap(tester, '提交 AI 复盘');
    final original = repo.submitted.single;
    repo.response.completeError(
      const ApiFailure(500, 'internal', '服务端内部原文', false),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('可能已生成并计次'), findsOneWidget);
    expect(find.textContaining('未扣次'), findsNothing);
    expect(find.text('服务端内部原文'), findsNothing);

    await _tap(tester, '重试原请求');
    expect(repo.submitted, hasLength(2));
    expect(repo.submitted.last.requestId, original.requestId);
    expect(repo.submitted.last.toWire(), original.toWire());
    repo.response.complete(const ReviewProcessing());
    await tester.pumpAndSettle();
  });

  testWidgets('提交前等待在途草稿保存结束，成功后再清除草稿', (tester) async {
    final repo = _FakeReviews();
    await _pump(tester, repo);
    await _fillAll(tester);

    final gate = Completer<void>();
    repo.saveGate = gate;
    await _enter(tester, 'review.nextAction', '下次我先停一下，问他想补充什么，再继续汇报。');
    await _tap(tester, '提交 AI 复盘');
    expect(repo.submitted, isEmpty);

    gate.complete();
    await tester.pumpAndSettle();
    final sent = repo.submitted.single;
    repo.response.complete(ReviewReady(_record(sent)));
    await tester.pumpAndSettle();

    expect(repo.discardCalls, 1);
    expect(repo.stored, isNull);
  });

  testWidgets('旧请求在页面关闭后才成功，不删除同键的新编辑草稿', (tester) async {
    final repo = _FakeReviews();
    await _pump(tester, repo);
    await _fillAll(tester);
    await _tap(tester, '提交 AI 复盘');
    final original = repo.submitted.single;

    await tester.pumpWidget(const SizedBox());
    await _pump(tester, repo);
    await _enter(tester, 'review.happened', '离开页面后改过的经过。');
    expect(repo.stored?.requestId, original.requestId);
    expect(repo.stored?.possibleAttempts.single.happened, original.happened);

    repo.response.complete(ReviewReady(_record(original)));
    await tester.pumpAndSettle();

    expect(repo.discardCalls, 1);
    expect(repo.stored?.requestId, original.requestId);
    expect(repo.stored?.happened, '离开页面后改过的经过。');
    expect(repo.stored?.possibleAttempts.single.happened, original.happened);
  });

  testWidgets('草稿落盘期间撤权，保存完成后不再发送正文', (tester) async {
    final repo = _ConsentReviews()..permission = true;
    await _pump(tester, repo);
    await _fillAll(tester);

    final gate = Completer<void>();
    repo.saveGate = gate;
    await _tap(tester, '提交 AI 复盘');
    expect(repo.submitted, isEmpty);
    final retainedId = repo.saved.last.possibleAttempts.single.requestId;

    repo.permission = false;
    gate.complete();
    await tester.pumpAndSettle();

    expect(repo.submitted, isEmpty);
    expect(find.textContaining('授权已撤回'), findsOneWidget);
    expect(repo.stored?.requestId, retainedId);
    expect(repo.stored?.possibleAttempts, isEmpty);

    repo.permission = true;
    await _tap(tester, '重试原请求');
    expect(repo.submitted.single.requestId, retainedId);
    repo.response.complete(const ReviewProcessing());
    await tester.pumpAndSettle();
  });

  testWidgets('A 超时后准备 B 但最终撤权，改回 A 并重开仍复用 A 的 request_id', (tester) async {
    final repo = _ConsentReviews()..permission = true;
    await _pump(tester, repo);
    await _fillAll(tester);
    await _tap(tester, '提交 AI 复盘');
    final original = repo.submitted.single;
    repo.response.completeError(
      const ApiFailure(500, 'internal', '服务端内部原文', false),
    );
    await tester.pumpAndSettle();

    await _enter(tester, 'review.nextAction', 'B：先确认对方是否还需要补充。');
    final gate = Completer<void>();
    repo.saveGate = gate;
    await _tap(tester, '提交 AI 复盘');
    final prepared = repo.saved.last;
    expect(prepared.requestId, isNot(original.requestId));
    expect(prepared.possibleAttempts.map((entry) => entry.toWire()), [
      original.toWire(),
      prepared.toWire(),
    ]);

    repo.permission = false;
    gate.complete();
    await tester.pumpAndSettle();

    expect(repo.submitted, hasLength(1));
    expect(find.textContaining('未发送正文'), findsOneWidget);
    expect(repo.stored?.requestId, prepared.requestId);
    expect(repo.stored?.possibleAttempts.single.toWire(), original.toWire());

    await tester.pumpWidget(const SizedBox());
    final reopened = _ConsentReviews()..permission = true;
    reopened.stored = ReviewDraft.fromCacheJson(repo.stored!.toCacheJson());
    await _pump(tester, reopened);
    await _tap(tester, '下一步');
    await _tap(tester, '下一步');
    await _tap(tester, '下一步');
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('review.nextAction')))
          .controller
          ?.text,
      'B：先确认对方是否还需要补充。',
    );

    await _enter(tester, 'review.nextAction', original.nextAction);
    expect(
      reopened.saved.last.possibleAttempts.single.toWire(),
      original.toWire(),
    );

    await tester.pumpWidget(const SizedBox());
    final restored = _ConsentReviews()..permission = true;
    restored.stored = ReviewDraft.fromCacheJson(reopened.stored!.toCacheJson());
    await _pump(tester, restored);
    await _tap(tester, '下一步');
    await _tap(tester, '下一步');
    await _tap(tester, '下一步');
    await _tap(tester, '提交 AI 复盘');

    expect(restored.submitted.single.requestId, original.requestId);
    expect(restored.submitted.single.toWire(), original.toWire());
    restored.response.complete(const ReviewProcessing());
    await tester.pumpAndSettle();
  });

  testWidgets('A 和 B 都已发送，B 响应丢失后编辑再撤销仍使用 B 的原请求', (tester) async {
    final repo = _ConsentReviews()..permission = true;
    await _pump(
      tester,
      repo,
      prefill: ReviewPrefill(
        markId: 'mark-1',
        contactId: 'contact-1',
        scene: Scene.work,
        occurredAt: DateTime.parse('2026-11-21T10:00:00+08:00'),
      ),
    );
    await _fillAll(tester);
    await _tap(tester, '提交 AI 复盘');
    final a = repo.submitted.single;
    repo.response.completeError(StateError('A 的响应丢失'));
    await tester.pumpAndSettle();

    await _enter(tester, 'review.nextAction', 'B：先确认对方是否还需要补充。');
    await _tap(tester, '提交 AI 复盘');
    expect(repo.submitted, hasLength(2));
    final b = repo.submitted.last;
    expect(b.requestId, isNot(a.requestId));
    await tester.pumpWidget(const SizedBox());
    repo.response.completeError(StateError('B 的响应丢失'));
    await tester.pumpAndSettle();

    final reopened = _ConsentReviews()
      ..permission = true
      ..stored = ReviewDraft.fromCacheJson(repo.stored!.toCacheJson());
    await _pump(tester, reopened);
    await _tap(tester, '下一步');
    await _tap(tester, '下一步');
    await _tap(tester, '下一步');
    await _enter(tester, 'review.nextAction', '临时改成 C。');
    await _enter(tester, 'review.nextAction', '  ${b.nextAction}  ');
    await tester.pumpWidget(const SizedBox());

    final restored = _ConsentReviews()
      ..permission = true
      ..stored = ReviewDraft.fromCacheJson(reopened.stored!.toCacheJson());
    await _pump(tester, restored);
    await _tap(tester, '下一步');
    await _tap(tester, '下一步');
    await _tap(tester, '下一步');
    await _tap(tester, '提交 AI 复盘');
    expect(restored.submitted.single.toWire(), b.toWire());
    restored.response.complete(const ReviewProcessing());
    await tester.pumpAndSettle();
  });

  testWidgets('未授权先确认，拒绝不提交，授权后才联网', (tester) async {
    final repo = _ConsentReviews();
    await _pump(tester, repo);
    await _fillAll(tester);
    await _tap(tester, '提交 AI 复盘');
    expect(find.text('提交前确认'), findsOneWidget);
    expect(find.textContaining('可能包含他人信息'), findsOneWidget);
    expect(find.textContaining('删除该复盘或注销账号'), findsOneWidget);
    expect(repo.submitted, isEmpty);

    await _tap(tester, '暂不提交');
    expect(repo.submitted, isEmpty);

    await _tap(tester, '提交 AI 复盘');
    await _tap(tester, '同意并提交');
    expect(repo.allowedCalls, 3);
    expect(repo.grantCalls, 1);
    expect(repo.submitted, hasLength(1));
    repo.response.complete(const ReviewProcessing());
    await tester.pumpAndSettle();
  });

  testWidgets('授权写入失败时不提交文字', (tester) async {
    final repo = _ConsentReviews(grantSucceeds: false);
    await _pump(tester, repo);
    await _fillAll(tester);
    await _tap(tester, '提交 AI 复盘');
    await _tap(tester, '同意并提交');
    expect(find.text('授权未确认，请稍后重试。'), findsOneWidget);
    expect(repo.grantCalls, 1);
    expect(repo.submitted, isEmpty);
  });

  testWidgets('审核危机单独分流，不展示评分；修改输入后使用新 request_id', (tester) async {
    final repo = _FakeReviews();
    await _pump(tester, repo);
    await _fillAll(tester);
    await _tap(tester, '提交 AI 复盘');
    final first = repo.submitted.single;
    repo.response.complete(
      const ReviewSafety(
        '听起来你现在可能正经历很难受的事。全国心理援助热线 12356；如有人身危险，请立即拨打 110 或 120。',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('12356'), findsOneWidget);
    expect(find.textContaining('85'), findsNothing);

    await _tap(tester, '重新写一次');
    expect(repo.saved.last.requestId, isNot(first.requestId));
    expect(repo.saved.last.possibleAttempts, isEmpty);
    await _enter(tester, 'review.happened', '我在电话里沉默了。');
    await _tap(tester, '下一步');
    await _enter(tester, 'review.myFeeling', '我有点慌。');
    await _enter(tester, 'review.theirFeeling', '对方可能着急。');
    await _tap(tester, '下一步');
    await _enter(tester, 'review.myAction', '我没有回应。');
    await _tap(tester, '下一步');
    await _enter(tester, 'review.nextAction', '我先说明需要缓一缓。');
    await _tap(tester, '提交 AI 复盘');
    expect(repo.submitted.last.requestId, isNot(first.requestId));
  });

  testWidgets('成功提交后，已经打开过的踩坑本会重新加载并显示新记录', (tester) async {
    final repo = _FakeReviews();
    var published = false;
    repo.page = (_) => ReviewHistoryPage(
      items: published ? [_record(repo.submitted.last)] : const [],
      next: null,
    );
    await _pump(tester, repo);

    await tester.tap(find.byKey(const Key('review.tab.book')));
    await tester.pumpAndSettle();
    expect(repo.historyCalls, hasLength(1));
    expect(find.textContaining('还没有复盘记录'), findsOneWidget);

    await tester.tap(find.byKey(const Key('review.tab.form')));
    await tester.pumpAndSettle();
    await _fillAll(tester);
    await _tap(tester, '提交 AI 复盘');
    final sent = repo.submitted.single;
    published = true;
    repo.response.complete(ReviewReady(_record(sent)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('review.tab.book')));
    await tester.pumpAndSettle();
    expect(repo.historyCalls, hasLength(2));
    expect(
      find.byKey(const ValueKey('review.history.review-1')),
      findsOneWidget,
    );
  });

  testWidgets('踩坑本旧请求晚于版本更新返回时，切回仍会重新加载', (tester) async {
    final repo = _FakeReviews();
    final gate = Completer<void>();
    repo.historyGate = gate;

    Widget book({required bool active, required int revision}) => MaterialApp(
      home: Scaffold(
        body: ReviewBookView(repo: repo, active: active, revision: revision),
      ),
    );

    await tester.pumpWidget(book(active: true, revision: 0));
    await tester.pump();
    expect(repo.historyCalls, hasLength(1));

    await tester.pumpWidget(book(active: false, revision: 0));
    await tester.pumpWidget(book(active: false, revision: 1));
    gate.complete();
    await tester.pumpAndSettle();
    expect(repo.historyCalls, hasLength(1));

    await tester.pumpWidget(book(active: true, revision: 1));
    await tester.pumpAndSettle();
    expect(repo.historyCalls, hasLength(2));
  });

  testWidgets('踩坑本每次切回都会重查，能收到退出后旧提交成功的新记录', (tester) async {
    final repo = _FakeReviews();
    final draft = ReviewDraft.blank(
      requestId: '85b72033-9f07-4bbc-8567-fc31f26508ab',
    );
    var published = false;
    repo.page = (_) => ReviewHistoryPage(
      items: published ? [_record(draft)] : const [],
      next: null,
    );

    Widget book({required bool active}) => MaterialApp(
      home: Scaffold(
        body: ReviewBookView(repo: repo, active: active, revision: 0),
      ),
    );

    await tester.pumpWidget(book(active: true));
    await tester.pumpAndSettle();
    expect(repo.historyCalls, hasLength(1));
    expect(find.textContaining('还没有复盘记录'), findsOneWidget);

    await tester.pumpWidget(book(active: false));
    published = true;
    await tester.pumpWidget(book(active: true));
    await tester.pumpAndSettle();

    expect(repo.historyCalls, hasLength(2));
    expect(
      find.byKey(const ValueKey('review.history.review-1')),
      findsOneWidget,
    );
  });

  testWidgets('踩坑本按场景、关系人筛选，并保持游标分页', (tester) async {
    final repo = _FakeReviews();
    final draft = ReviewDraft.blank(
      requestId: '85b72033-9f07-4bbc-8567-fc31f26508ab',
    );
    repo.page = (cursor) => ReviewHistoryPage(
      items: [_record(draft, id: cursor == null ? 'review-1' : 'review-2')],
      next: cursor == null ? 'page-2' : null,
    );
    await _pump(tester, repo);
    await tester.tap(find.byKey(const Key('review.tab.book')));
    await tester.pumpAndSettle();
    expect(repo.historyCalls.single.scene, isNull);
    expect(repo.historyCalls.single.contactId, isNull);

    await tester.tap(find.byKey(const Key('review.filter.scene')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('家人').last);
    await tester.pumpAndSettle();
    expect(repo.historyCalls.last.scene, Scene.family);

    await tester.tap(find.byKey(const Key('review.filter.contact')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('小安').last);
    await tester.pumpAndSettle();
    expect(repo.historyCalls.last.contactId, 'contact-1');

    await _tap(tester, '加载更早复盘');
    expect(repo.historyCalls.last.cursor, 'page-2');
    expect(repo.historyCalls.last.scene, Scene.family);
    expect(repo.historyCalls.last.contactId, 'contact-1');
  });
}
