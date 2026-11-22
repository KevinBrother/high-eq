import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/sse.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/practice/chat.dart';
import 'package:high_eq/features/practice/conversation.dart';
import 'package:high_eq/features/practice/demo.dart';
import 'package:high_eq/features/practice/repository.dart';

class CappedPractice extends DemoPractice {
  CappedPractice({this.hideReply = false, this.terminal = 'capped'});

  final bool hideReply;
  final String terminal;
  int finishes = 0;

  @override
  Future<Json> get(String id) async {
    final session = await super.get(id);
    return {
      ...session,
      'status': terminal,
      if (hideReply)
        'messages': (session['messages'] as List)
            .where((m) => m['role'] == 'user')
            .toList(),
    };
  }

  @override
  Future<Json> finish(String id) {
    finishes++;
    return super.finish(id);
  }
}

class CapOnNext extends DemoPractice {
  bool capped = false, capNext = false;

  @override
  Stream<ReplyEvent> send(String id, Json body) {
    if (capNext) {
      capNext = false;
      capped = true;
      return Stream<ReplyEvent>.error(
        const ApiFailure(409, 'conflict', '本场已达长度上限', false),
      );
    }
    return super.send(id, body);
  }

  @override
  Future<Json> get(String id) async {
    final session = await super.get(id);
    return {...session, if (capped) 'status': 'capped'};
  }
}

class DelayedModerationFinish extends CappedPractice {
  bool moderated = false;
  int finishAttempts = 0;

  @override
  Future<Json> finish(String id) async {
    finishAttempts++;
    if (finishAttempts == 1) {
      throw const FormatException('连接中断');
    }
    moderated = false;
    return super.finish(id);
  }

  @override
  Future<Json> get(String id) async {
    final session = await super.get(id);
    return {...session, if (moderated) 'status': 'moderation_unavailable'};
  }
}

Future<CappedPractice> practice(
  WidgetTester tester, {
  bool withReply = true,
  String terminal = 'capped',
}) async {
  final repo = CappedPractice(hideReply: !withReply, terminal: terminal);
  await repo.create({'request_id': 'a', 'scene': 'work', 'scenario': '合成封顶会话'});
  if (withReply) {
    final done = repo.send('a', {
      'client_message_id': 'b',
      'text': '合成发言',
    }).drain<void>();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await done;
  }
  return repo;
}

void main() {
  testWidgets('capped 有完整回复：禁发但可结束评分', (t) async {
    final repo = await practice(t);
    await t.pumpWidget(
      MaterialApp(
        home: PracticeChat(repo: repo, initial: await repo.get('a')),
      ),
    );
    await t.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    expect(find.byTooltip('发送'), findsNothing);
    expect(find.textContaining('已保留完整对话，可以结束并评分'), findsOneWidget);
    expect(find.text('结束并评分'), findsOneWidget);

    await t.tap(find.text('结束并评分'));
    await t.pumpAndSettle();
    expect(repo.finishes, 1);
    expect(find.text('整场反馈'), findsOneWidget);
  });

  testWidgets('发送遇 409 后自动回读 capped，并保留评分入口', (t) async {
    final repo = CapOnNext();
    await repo.create({
      'request_id': 'a',
      'scene': 'work',
      'scenario': '合成封顶会话',
    });
    final first = repo.send('a', {
      'client_message_id': 'b',
      'text': '合成首轮',
    }).drain<void>();
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    await t.pump(const Duration(milliseconds: 100));
    await first;
    repo.capNext = true;

    await t.pumpWidget(
      MaterialApp(
        home: PracticeChat(repo: repo, initial: await repo.get('a')),
      ),
    );
    await t.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    await t.enterText(find.byType(TextField), '合成封顶后发言');
    await t.tap(find.byTooltip('发送'));
    await t.pumpAndSettle();

    expect(repo.capped, isTrue);
    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('已保留完整对话，可以结束并评分'), findsOneWidget);
    expect(find.text('结束并评分'), findsOneWidget);
  });

  testWidgets('capped 无 AI 回复：禁发且 finish 不得发请求', (t) async {
    final repo = await practice(t, withReply: false);
    final initial = await repo.get('a');
    final conversation = Conversation(repo, initial);
    addTearDown(conversation.dispose);
    await conversation.recover();
    await conversation.finish();
    expect(repo.finishes, 0);

    await t.pumpWidget(
      MaterialApp(
        home: PracticeChat(repo: repo, initial: initial),
      ),
    );
    await t.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('没有可评分内容'), findsOneWidget);
    expect(find.text('结束并评分'), findsNothing);
  });

  testWidgets('封顶评分断线先读回 capped，后续审核故障仍保留原评分重试', (t) async {
    final repo = DelayedModerationFinish();
    await repo.create({
      'request_id': 'a',
      'scene': 'work',
      'scenario': '合成封顶会话',
    });
    final done = repo.send('a', {
      'client_message_id': 'b',
      'text': '合成发言',
    }).drain<void>();
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    await t.pump(const Duration(milliseconds: 100));
    await done;

    await t.pumpWidget(
      MaterialApp(
        home: PracticeChat(repo: repo, initial: await repo.get('a')),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('结束并评分'));
    await t.pumpAndSettle();

    expect(repo.finishAttempts, 1);
    expect(find.text('重试原评分'), findsOneWidget);

    repo.moderated = true;
    await t.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await t.pumpWidget(
      MaterialApp(
        home: PracticeChat(repo: repo, initial: await repo.get('a')),
      ),
    );
    await t.pumpAndSettle();

    expect(find.text(moderationHelp), findsOneWidget);
    expect(find.text('重试原评分'), findsOneWidget);
    await t.tap(find.text('重试原评分'));
    await t.pumpAndSettle();
    expect(repo.finishAttempts, 2);
    expect(find.text('整场反馈'), findsOneWidget);
  });

  for (final terminal in ['safety', 'moderation_unavailable']) {
    testWidgets('$terminal 有历史也不能走普通评分', (t) async {
      final repo = await practice(t, terminal: terminal);
      await t.pumpWidget(
        MaterialApp(
          home: PracticeChat(repo: repo, initial: await repo.get('a')),
        ),
      );
      await t.pumpAndSettle();

      expect(find.text('结束并评分'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(
        find.text(terminal == 'safety' ? safetyHelp : moderationHelp),
        findsOneWidget,
      );
      expect(repo.finishes, 0);
    });
  }
}
