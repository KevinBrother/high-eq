import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/sse.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/practice/chat.dart';
import 'package:high_eq/features/practice/demo.dart';
import 'package:high_eq/features/practice/repository.dart';

class Faults extends DemoPractice {
  final bool safety;
  Faults({this.safety = false});
  String? stopped;
  final finishing = <String>[];
  @override
  Future<Json> finish(String id) async {
    finishing.add(id);
    if (finishing.length > 1) {
      stopped = null;
      return super.finish(id);
    }
    stopped = safety ? 'safety' : 'moderation_unavailable';
    if (safety) return {'safety': true, 'message': safetyHelp};
    throw const ApiFailure(503, 'moderation_unavailable', moderationHelp, true);
  }

  @override
  Future<Json> get(String id) async => {
    ...await super.get(id),
    if (stopped != null) ...{
      'status': stopped,
      'settlement': {
        'status': 'refunded',
        'net_charge': 0,
        'charged_day': '2026-11-20',
      },
    },
  };
}

class Held extends DemoPractice {
  final release = Completer<void>();
  int exits = 0;
  @override
  Stream<ReplyEvent> send(String id, Json body) async* {
    yield const ReplyEvent(ReplyEventKind.fragment, {'text': '尚未保存'});
    await release.future;
    yield const ReplyEvent(ReplyEventKind.fragment, {'text': '迟到帧'});
  }

  @override
  Future<Json> exit(String id) {
    exits++;
    return super.exit(id);
  }
}

void main() {
  for (final safety in [true, false]) {
    testWidgets('评分${safety ? '危机' : '503'}只显示对应终止与原日退款', (t) async {
      final r = Faults(safety: safety);
      await r.create({'request_id': 'a', 'scene': 'work', 'scenario': '排练'});
      // Seed a contract-shaped saved round, no HTTP or model.
      final future = r.send('a', {
        'client_message_id': 'b',
        'text': '合成发言',
      }).drain<void>();
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 100));
      await future;
      await t.pumpWidget(
        MaterialApp(
          home: PracticeChat(repo: r, initial: await r.get('a')),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('结束并评分'));
      await t.pumpAndSettle();
      expect(find.text(safety ? safetyHelp : moderationHelp), findsOneWidget);
      expect(find.text(safety ? moderationHelp : safetyHelp), findsNothing);
      expect(find.textContaining('已退回 2026-11-20'), findsOneWidget);
      expect(find.textContaining('NVC 总分'), findsNothing);
      if (!safety) {
        await t.tap(find.text('重试原评分'));
        await t.pumpAndSettle();
        expect(r.finishing, ['a', 'a']);
        expect(find.text('整场反馈'), findsOneWidget);
      } else {
        expect(find.text('重试原评分'), findsNothing);
      }
    });
  }
  testWidgets('首条生成中可确认主动退出，不接受迟到帧', (t) async {
    final r = Held();
    final s = await r.create({
      'request_id': 'a',
      'scene': 'work',
      'scenario': '排练',
    });
    await t.pumpWidget(
      MaterialApp(
        home: PracticeChat(repo: r, initial: s),
      ),
    );
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), '合成发言');
    await t.tap(find.byTooltip('发送'));
    await t.pump();
    expect(find.text('尚未保存'), findsOneWidget);
    await t.tap(find.text('主动退出'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(r.exits, 0);
    await t.tap(find.text('确认退出'));
    await t.pumpAndSettle();
    r.release.complete();
    await t.pump();
    expect(r.exits, 1);
    expect(find.text('本场已主动退出。'), findsOneWidget);
    expect(find.text('本场未扣次'), findsOneWidget);
    expect(find.text('迟到帧'), findsNothing);
  });
}
