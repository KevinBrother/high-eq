import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/practice/chat.dart';
import 'package:high_eq/features/practice/demo.dart';

import 'demo_clock.dart';

class GatedPrevious extends DemoPractice {
  GatedPrevious(this.gatedId);

  final String gatedId;
  final release = Completer<void>();
  int gatedReads = 0;

  @override
  Future<Json> get(String id) async {
    if (id == gatedId) {
      gatedReads++;
      await release.future;
    }
    return super.get(id);
  }
}

Future<void> addTurn(
  WidgetTester t,
  DemoPractice repo,
  String id,
  String messageId,
  String text,
) {
  return pumpDemoReply(
    t,
    repo.send(id, {'client_message_id': messageId, 'text': text}),
  );
}

Future<String> completed(
  WidgetTester t,
  DemoPractice repo, {
  required String id,
  required String scenario,
  String? previousId,
  required int turns,
}) async {
  await repo.create({
    'request_id': id,
    'scene': 'work',
    'scenario': scenario,
    'previous_id': ?previousId,
  });
  for (var i = 0; i < turns; i++) {
    await addTurn(t, repo, id, '$id-$i', '$id 第 ${i + 1} 次表达');
  }
  await repo.finish(id);
  return id;
}

void main() {
  testWidgets('换账号时旧对比响应不覆盖新会话上下文', (t) async {
    final old = GatedPrevious('old-a');
    await completed(t, old, id: 'old-a', scenario: '旧账号预演', turns: 1);
    await completed(
      t,
      old,
      id: 'old-b',
      scenario: '旧账号预演',
      previousId: 'old-a',
      turns: 1,
    );

    final current = DemoPractice();
    await completed(t, current, id: 'new-a', scenario: '新账号预演', turns: 2);
    await completed(
      t,
      current,
      id: 'new-b',
      scenario: '新账号预演',
      previousId: 'new-a',
      turns: 1,
    );

    await t.pumpWidget(
      MaterialApp(
        home: PracticeChat(repo: old, initial: await old.get('old-b')),
      ),
    );
    await t.pump();
    await t.pump();
    expect(old.gatedReads, 1);

    await t.pumpWidget(
      MaterialApp(
        home: PracticeChat(repo: current, initial: await current.get('new-b')),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('上次 100 → 本次 60（-40 分）'), findsOneWidget);

    old.release.complete();
    await t.pumpAndSettle();
    expect(find.text('上次 100 → 本次 60（-40 分）'), findsOneWidget);
    expect(find.text('上次 60 → 本次 60（+0 分）'), findsNothing);
  });

  testWidgets('页面销毁后旧对比响应不回写', (t) async {
    final old = GatedPrevious('old-a');
    await completed(t, old, id: 'old-a', scenario: '旧账号预演', turns: 1);
    await completed(
      t,
      old,
      id: 'old-b',
      scenario: '旧账号预演',
      previousId: 'old-a',
      turns: 1,
    );

    await t.pumpWidget(
      MaterialApp(
        home: PracticeChat(repo: old, initial: await old.get('old-b')),
      ),
    );
    await t.pump();
    await t.pump();
    expect(old.gatedReads, 1);

    await t.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    old.release.complete();
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });
}
