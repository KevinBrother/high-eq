import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/features/contacts/models.dart';
import 'package:high_eq/features/contacts/demo.dart';
import 'package:high_eq/features/contacts/scene.dart';
import 'package:high_eq/features/practice/demo.dart';
import 'package:high_eq/features/practice/lobby.dart';

class Recorded extends DemoPractice {
  final creates = <Json>[];
  bool loseFirst = false;
  int exits = 0;
  @override
  Future<Json> create(Json body) async {
    creates.add(body);
    final s = await super.create(body);
    if (loseFirst && creates.length == 1) throw const FormatException();
    return s;
  }

  @override
  Future<Json> exit(String id) {
    exits++;
    return super.exit(id);
  }
}

Future<void> say(WidgetTester t, String text) async {
  await t.enterText(find.byType(TextField), text);
  await t.tap(find.byTooltip('发送'));
  await t.pumpAndSettle();
}

Future<void> tapLabel(WidgetTester t, String label) async {
  final f = find.text(label);
  await t.ensureVisible(f);
  await t.tap(f);
  await t.pumpAndSettle();
}

class ChangingBook extends DemoContacts {
  bool allowed = true;
  @override
  Future<Book> load() async => Book(
    [
      for (final n in ['可选称呼', '只读称呼'])
        Contact.fromJson({
          'id': n,
          'nickname': n,
          'scene': 'work',
          'editable': n == '可选称呼' && allowed,
          'profile': <String, dynamic>{},
        }),
    ],
    {'tier': 'free', 'max_active_contacts': 1},
  );
}

class NoQuota extends DemoPractice {
  @override
  Future<Json> create(Json body) async => throw ApiFailure(
    429,
    'quota_exceeded',
    '额度不足',
    false,
    DateTime(2026, 11, 22, 8, 0),
  );
}

void main() {
  testWidgets('只列可用关系人，提交前重查已变只读则不创建', (t) async {
    final r = Recorded(), book = ChangingBook();
    await t.pumpWidget(
      MaterialApp(
        home: PracticeLobby(
          demo: true,
          repo: r,
          scene: SceneMemory(),
          contacts: book,
        ),
      ),
    );
    await t.pumpAndSettle();
    await tapLabel(t, '不指定关系人');
    expect(find.text('只读称呼'), findsNothing);
    await tapLabel(t, '可选称呼');
    book.allowed = false;
    await tapLabel(t, '先说发生了什么');
    expect(r.creates, isEmpty);
    expect(find.text('关系人已不可用，请重新选择。'), findsOneWidget);
  });
  testWidgets('首次真实模式先告知；429 提示余量和重置，不自动购买', (t) async {
    final r = NoQuota();
    await t.pumpWidget(
      MaterialApp(
        home: PracticeLobby(repo: r, scene: SceneMemory()),
      ),
    );
    await t.pumpAndSettle();
    await tapLabel(t, '先说发生了什么');
    expect(find.textContaining('相关关系人或注销账号'), findsOneWidget);
    await tapLabel(t, '暂不开始');
    expect(await r.read('creating'), isNull);
    await tapLabel(t, '先说发生了什么');
    await tapLabel(t, '了解，继续练习');
    expect(find.textContaining('今日对练剩余 0 次'), findsOneWidget);
    expect(find.textContaining('08:00'), findsOneWidget);
    expect(find.text('查看额度与重置时间'), findsOneWidget);
  });
  testWidgets('场景难度筛选 → 单项目标 → 重练使用新会话，并对比同关成绩', (t) async {
    final r = Recorded(), scene = SceneMemory();
    await t.pumpWidget(
      MaterialApp(
        home: PracticeLobby(demo: true, repo: r, scene: scene),
      ),
    );
    await t.pumpAndSettle();
    await tapLabel(t, '家人');
    await tapLabel(t, '难度 1');
    expect(scene.value, Scene.family);
    expect(find.text('说清我的需要'), findsNothing);
    await tapLabel(t, '先说发生了什么');
    await say(t, '第一次表达');
    await tapLabel(t, '结束并评分');
    expect(find.text('观察 · 单项反馈'), findsOneWidget);
    expect(find.text('建议三天后重练'), findsOneWidget);
    expect(find.textContaining('NVC 总分'), findsNothing);
    expect(find.textContaining('读懂别人'), findsNothing);
    await tapLabel(t, '再练一次');
    await say(t, '第二次表达');
    await say(t, '补充合成细节');
    await tapLabel(t, '结束并评分');
    expect(find.text('上次 15 → 本次 25（+10 分）'), findsOneWidget);
    expect(find.text('本关已通过'), findsOneWidget);
    expect(r.creates[0]['level_id'], r.creates[1]['level_id']);
    expect(r.creates[0]['request_id'], isNot(r.creates[1]['request_id']));
  });
  testWidgets('预演创建丢响应复用请求，返回不退出；整场定位第二次用户发言', (t) async {
    final r = Recorded()..loseFirst = true;
    await t.pumpWidget(
      MaterialApp(
        home: PracticeLobby(
          demo: true,
          repo: r,
          scene: SceneMemory(Scene.friends),
        ),
      ),
    );
    await t.pumpAndSettle();
    final field = find.byType(TextField);
    await t.ensureVisible(field);
    await t.enterText(field, '排练和朋友约时间');
    await t.pump();
    await tapLabel(t, '开始预演');
    expect(r.creates, hasLength(1));
    expect(await r.read('creating'), isNotNull);
    await tapLabel(t, '恢复上次创建');
    expect(r.creates, hasLength(2));
    expect(r.creates[0], r.creates[1]);
    expect(
      r.creates.first.keys,
      unorderedEquals(['scenario', 'scene', 'request_id']),
    );
    expect(r.creates.first['scene'], 'friends');
    await say(t, '先说时间');
    await t.pageBack();
    await t.pumpAndSettle();
    expect(r.exits, 0);
    await t.scrollUntilVisible(
      find.text('继续本场'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tapLabel(t, '继续本场');
    await say(t, '再说地点');
    await tapLabel(t, '结束并评分');
    expect(find.text('NVC 总分 100 / 100'), findsOneWidget);
    final list = find.byType(Scrollable).first;
    await t.scrollUntilVisible(find.text('第 2 次用户发言'), 200, scrollable: list);
    expect(find.text('「再说地点」'), findsOneWidget);
    expect(find.text('「先说时间」'), findsNothing);
    expect(find.textContaining('自我管理'), findsOneWidget);
    expect(find.textContaining('关系效果'), findsOneWidget);
    expect(find.text('我们能约个时间，一起把下一步定下来吗？'), findsOneWidget);
  });
}
