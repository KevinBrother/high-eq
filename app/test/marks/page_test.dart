import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/marks/page.dart';
import 'package:high_eq/features/reviews/model.dart';
import 'package:high_eq/features/reviews/page.dart';

class ReviewBook extends Fake implements ReviewRepository {
  ReviewDraft? stored;

  @override
  Future<ReviewDraft?> loadDraft() async => stored;

  @override
  Future<void> saveDraft(ReviewDraft draft) async {
    stored = draft;
  }

  @override
  Future<List<ReviewPerson>> people() async => const [
    ReviewPerson(id: 'p', name: '合成对象'),
  ];
}

class Book extends Fake implements MarkBook {
  bool granted = false, fail = false, saved = false, peopleError = false;
  bool removeFail = false;
  ApiFailure? createFailure;
  bool hideFirstHistory = false;
  int historyCalls = 0;
  String? historyNext;
  final ids = <String>[];
  Json? record;
  @override
  bool get demo => false;
  @override
  Future<bool> consented() async => granted;
  @override
  Future<void> grant() async {
    granted = true;
  }

  @override
  Future<Mark> create(String k) async {
    ids.add(k);
    final failure = createFailure;
    if (failure != null) {
      createFailure = null;
      throw failure;
    }
    record ??= {'id': 'm', 'marked_at': '2026-11-21T10:45:00Z'};
    if (fail) {
      fail = false;
      throw StateError('lost response');
    }
    return Mark.fromJson(record!);
  }

  @override
  Future<({List<Mark> items, String? next})> history([String? cursor]) async {
    historyCalls++;
    if (hideFirstHistory && historyCalls == 1) {
      return (items: <Mark>[], next: null);
    }
    return (
      items: [if (record != null) Mark.fromJson(record!)],
      next: historyNext,
    );
  }

  @override
  Future<Map<String, String>> people() async {
    if (peopleError) throw StateError('people unavailable');
    return {'p': '合成对象'};
  }

  @override
  Future<Mark> edit(String id, Json fields) async {
    record!.addAll(fields);
    return Mark.fromJson(record!);
  }

  @override
  Future<void> remove(String id) async {
    if (removeFail) {
      throw const ApiFailure(503, 'service_unavailable', '稍后重试', true);
    }
    record = null;
  }

  @override
  Future<bool> bookmarked(Mark m) async => saved;
  @override
  Future<void> bookmark(Mark m) async {
    saved = true;
  }
}

Future<void> tap(WidgetTester t, String label) async {
  final f = find.text(label).last;
  await t.ensureVisible(f);
  await t.tap(f);
  await t.pumpAndSettle();
}

void main() {
  testWidgets('首用拒绝不写；明确同意、丢响应重试沿用请求 ID', (t) async {
    final b = Book();
    await t.pumpWidget(MaterialApp(home: MarksPage(b, quick: true)));
    await t.pumpAndSettle();
    expect(find.textContaining('180 天'), findsOneWidget);
    await tap(t, '暂不记录');
    expect(b.granted, isFalse);
    expect(b.ids, isEmpty);
    expect(find.textContaining('已记下'), findsNothing);
    await tap(t, '我上头了');
    b.fail = true;
    await tap(t, '同意并标记');
    expect(find.textContaining('已记下'), findsNothing);
    await tap(t, '重试本次标记');
    expect(b.ids.length, 2);
    expect(b.ids.toSet().length, 1);
    expect(find.text('补充信息'), findsOneWidget);
  });
  testWidgets('历史不创建；补对象场景、复盘参数、本机草稿与删除', (t) async {
    final b = Book()..granted = true;
    final reviews = ReviewBook();
    await b.create('prior');
    Json? seed;
    await t.pumpWidget(
      MaterialApp(
        home: MarksPage(b),
        onGenerateRoute: (s) {
          expect(s.name, '/marks/review');
          seed = s.arguments as Json;
          return MaterialPageRoute(
            builder: (_) =>
                ReviewPage(reviews, prefill: ReviewPrefill.tryFromRoute(seed)),
          );
        },
      ),
    );
    await t.pumpAndSettle();
    await tap(t, '补充信息');
    await tap(t, '不指定对象');
    await tap(t, '合成对象');
    await tap(t, '不指定场景');
    await tap(t, '职场');
    await tap(t, '保存');
    await tap(t, '写复盘');
    expect(seed, {
      'mark_id': 'm',
      'occurred_at': '2026-11-21T10:45:00.000Z',
      'contact_id': 'p',
      'scene': 'work',
    });
    expect(find.text('复盘与踩坑本'), findsOneWidget);
    expect(find.text('从标记开始'), findsOneWidget);
    expect(find.textContaining('合成对象'), findsOneWidget);
    expect(find.textContaining('职场'), findsWidgets);
    expect(reviews.stored?.markId, 'm');
    expect(reviews.stored?.occurredAt, DateTime.parse('2026-11-21T10:45:00Z'));
    expect(reviews.stored?.contactId, 'p');
    expect(reviews.stored?.scene?.name, 'work');
    await t.pageBack();
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('删除标记'));
    await t.pumpAndSettle();
    await tap(t, '保留');
    expect(b.record, isNotNull);
    expect(find.text('标记已删除'), findsNothing);
    await t.tap(find.byTooltip('删除标记'));
    await t.pumpAndSettle();
    await tap(t, '删除');
    expect(b.record, isNull);
    expect(b.ids, ['prior']);
  });
  testWidgets('丢响应后刷新历史仍用原请求号，删除后再用新请求号', (t) async {
    final b = Book()
      ..granted = true
      ..fail = true
      ..hideFirstHistory = true
      ..historyNext = 'next';
    b.record = {
      'id': 'm',
      'marked_at': DateTime.now().toUtc().toIso8601String(),
    };
    await t.pumpWidget(MaterialApp(home: MarksPage(b, quick: true)));
    await t.pumpAndSettle();
    expect(b.ids.length, 1);
    expect(b.historyCalls, 1);
    expect(find.text('重试本次标记'), findsOneWidget);
    await t.tap(find.byTooltip('刷新历史'));
    await t.pumpAndSettle();
    // History cannot prove which request created a record. Keep the exact local
    // intent and let the server deduplicate the original request ID.
    expect(find.text('重试本次标记'), findsOneWidget);
    expect(find.text('我上头了'), findsNothing);
    await tap(t, '重试本次标记');
    expect(b.ids.length, 2);
    expect(b.ids.toSet().length, 1);
    expect(find.textContaining('已记下'), findsOneWidget);
    expect(find.text('我上头了'), findsOneWidget);
    await t.tap(find.byTooltip('删除标记'));
    await t.pumpAndSettle();
    await tap(t, '删除');
    expect(find.text('还没有标记。下次想暂停一下时，点上方按钮就好。'), findsOneWidget);
    await tap(t, '我上头了');
    expect(b.ids.length, 3);
    expect(b.ids[1], b.ids[0]);
    expect(b.ids[2], isNot(b.ids[0]));
  });
  testWidgets('409 不报告成功，清除旧请求后下一次用新 ID', (t) async {
    final b = Book()
      ..granted = true
      ..createFailure = const ApiFailure(
        409,
        'conflict',
        '这次标记已删除，请重新记录',
        false,
      );
    await t.pumpWidget(MaterialApp(home: MarksPage(b, quick: true)));
    await t.pumpAndSettle();
    expect(find.textContaining('已记下'), findsNothing);
    expect(find.textContaining('这次标记已删除'), findsOneWidget);
    expect(find.text('我上头了'), findsOneWidget);
    await tap(t, '我上头了');
    expect(b.ids.length, 2);
    expect(b.ids.toSet().length, 2);
    expect(find.textContaining('已记下'), findsOneWidget);
  });
  testWidgets('删除失败不报告成功，也不移除卡片', (t) async {
    final b = Book()
      ..granted = true
      ..removeFail = true;
    await b.create('prior');
    await t.pumpWidget(MaterialApp(home: MarksPage(b)));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('删除标记'));
    await t.pumpAndSettle();
    await tap(t, '删除');
    expect(find.text('标记已删除'), findsNothing);
    expect(find.text('稍后重试'), findsOneWidget);
    expect(b.record, isNotNull);
    expect(find.text('补充信息'), findsOneWidget);
  });
  testWidgets('对象列表失败仍可只补场景', (t) async {
    final b = Book()
      ..granted = true
      ..peopleError = true;
    await b.create('prior');
    await t.pumpWidget(MaterialApp(home: MarksPage(b)));
    await t.pumpAndSettle();
    await tap(t, '补充信息');
    expect(find.text('对象列表暂不可用 · 重试'), findsOneWidget);
    await tap(t, '不指定场景');
    await tap(t, '职场');
    await tap(t, '保存');
    expect(b.record!['scene'], 'work');
    expect(b.record!['contact_id'], isNull);
  });
}
