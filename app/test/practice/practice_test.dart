import 'dart:async';
import 'package:high_eq/features/practice/repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/features/practice/chat.dart';
import 'package:high_eq/features/practice/demo.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/core/sse.dart';

class Interrupted extends DemoPractice {
  final attempts = <String>[];
  @override
  Stream<ReplyEvent> send(String id, Json body) async* {
    attempts.add(body['client_message_id']);
    if (attempts.length == 1) {
      yield const ReplyEvent(ReplyEventKind.fragment, {'text': '未保存的片段'});
      throw const FormatException();
    }
    yield* super.send(id, body);
  }
}

void main() {
  terminals();
  testWidgets('断线读回、重发复用消息 ID，重进不重复发言', (t) async {
    final repo = Interrupted();
    final seed = {'request_id': 'a', 'scenario': '排练交接', 'scene': 'work'};
    final session = await repo.create(seed);
    await t.pumpWidget(
      MaterialApp(
        home: PracticeChat(repo: repo, initial: session, seed: seed),
      ),
    );
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), '我们能约个时间吗？');
    await t.tap(find.byTooltip('发送'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));

    expect(find.text('未保存的片段'), findsNothing);
    await t.tap(find.text('恢复会话'));
    await t.pumpAndSettle();
    await t.tap(find.text('重试原发言'));
    await t.pumpAndSettle();
    expect(repo.attempts.length, 2);
    expect(repo.attempts.toSet().length, 1);
    expect((await repo.get('a'))['messages'], hasLength(2));
    expect(find.text('我们能约个时间吗？'), findsOneWidget);
  });
}

class TerminalDemo extends DemoPractice {
  TerminalDemo(this.kind);
  final ReplyEventKind kind;
  final release = Completer<void>();
  final attempts = <Json>[];
  String? ended;
  @override
  Future<Json> get(String id) async => {
    ...await super.get(id),
    if (ended != null) 'status': ended,
  };
  @override
  Stream<ReplyEvent> send(String id, Json body) async* {
    attempts.add(body);
    if (attempts.length > 1) {
      ended = null;
      yield* super.send(id, body);
      return;
    }
    yield const ReplyEvent(ReplyEventKind.fragment, {'text': '临时句子'});
    await release.future;
    ended = kind == ReplyEventKind.safety ? 'safety' : 'moderation_unavailable';
    yield ReplyEvent(
      kind,
      kind == ReplyEventKind.safety
          ? {'safety': true, 'message': safetyHelp}
          : {'code': ended, 'retryable': true, 'message': moderationHelp},
    );
    yield const ReplyEvent(ReplyEventKind.fragment, {'text': '迟到的内容'});
  }
}

void terminals() {
  for (final kind in [
    ReplyEventKind.safety,
    ReplyEventKind.moderationUnavailable,
  ]) {
    testWidgets('$kind 替换片段且不显示评分', (t) async {
      final repo = TerminalDemo(kind);
      final session = await repo.create({
        'request_id': 'a',
        'scene': 'work',
        'scenario': '排练',
      });
      await t.pumpWidget(
        MaterialApp(
          home: PracticeChat(repo: repo, initial: session),
        ),
      );
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), '合成测试');
      await t.tap(find.byTooltip('发送'));
      await t.pump();
      await t.pump();
      expect(find.text('临时句子'), findsOneWidget);
      expect(find.text('本场未扣次'), findsOneWidget);
      repo.release.complete();
      await t.pump();
      await t.pump();
      expect(find.text('临时句子'), findsNothing);
      expect(find.text('迟到的内容'), findsNothing);
      expect(find.text('结束并评分'), findsNothing);
      expect(
        find.text(kind == ReplyEventKind.safety ? safetyHelp : moderationHelp),
        findsOneWidget,
      );
      expect(
        find.text(kind != ReplyEventKind.safety ? safetyHelp : moderationHelp),
        findsNothing,
      );
      if (kind == ReplyEventKind.moderationUnavailable) {
        await t.tap(find.text('重试原发言'));
        await t.pumpAndSettle();
        expect(repo.attempts, hasLength(2));
        expect(repo.attempts.first, repo.attempts.last);
        expect(find.text('本场净扣 1 次'), findsOneWidget);
      } else {
        expect(find.text('重试原发言'), findsNothing);
      }
    });
  }
}
