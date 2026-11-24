import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/features/contacts/models.dart';
import 'package:high_eq/features/contacts/demo.dart';
import 'package:high_eq/features/contacts/scene.dart';
import 'package:high_eq/features/practice/demo.dart';
import 'package:high_eq/features/practice/lobby.dart';

import 'demo_clock.dart';

class Recorded extends DemoPractice {
  Recorded({super.contacts});
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
  await t.pumpAndSettle();
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

class MutableBook extends DemoContacts {
  MutableBook(this.rows);
  final List<Contact> rows;
  @override
  Future<Book> load() async =>
      Book(List.of(rows), {'tier': 'free', 'max_active_contacts': 1});
  @override
  Future<void> remove(String id) async {
    rows.removeWhere((p) => p.id == id);
  }
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

class ConsentPractice extends DemoPractice {
  bool granted = false, failGrant = false;
  int creates = 0;
  @override
  Future<bool> practiceConsent() async => granted;
  @override
  Future<void> grantPracticeConsent() async {
    if (failGrant) {
      throw const ApiFailure(500, 'unavailable', '授权保存失败', true);
    }
    granted = true;
  }

  @override
  Future<Json> create(Json body) {
    creates++;
    return super.create(body);
  }
}

class OfflineDetail extends Recorded {
  String? offlineId;

  @override
  Future<Json> get(String id) async {
    if (id == offlineId) throw const FormatException('synthetic offline');
    return super.get(id);
  }
}

class CompareOnce extends Recorded {
  int priorReads = 0;
  @override
  Future<Json> get(String id) async {
    if (id == 'seed-a' && ++priorReads > 1) {
      throw const FormatException('second comparison read unavailable');
    }
    return super.get(id);
  }
}

void main() {
  testWidgets('大厅已取得的同一前场成绩不会因聊天页重读而消失', (t) async {
    final r = CompareOnce();
    for (final id in ['seed-a', 'seed-b']) {
      await r.create({
        'request_id': id,
        'scene': 'work',
        'scenario': '合成会议',
        if (id == 'seed-b') 'previous_id': 'seed-a',
      });
      await pumpDemoReply(
        t,
        r.send(id, {'client_message_id': '$id-1', 'text': '$id 发言'}),
      );
      await r.finish(id);
    }
    await t.pumpWidget(
      MaterialApp(
        home: PracticeLobby(demo: true, repo: r, scene: SceneMemory()),
      ),
    );
    await t.pumpAndSettle();
    await t.scrollUntilVisible(
      find.text('seed-b 发言'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tapLabel(t, 'seed-b 发言');
    expect(find.text('上次 60 → 本次 60（0 分）'), findsOneWidget);
    expect(r.priorReads, 1);
  });
  test('演示创建响应与真实 API 一样只返回摘要，详情才返回启动参数', () async {
    final r = DemoPractice();
    final created = await r.create({
      'request_id': 'summary-only',
      'scene': 'work',
      'scenario': '仅详情可见的合成预演',
    });

    expect(created['session_id'], 'summary-only');
    expect(created.containsKey('setup'), isFalse);

    final detail = await r.get('summary-only');
    expect(detail['setup']['scenario'], '仅详情可见的合成预演');
  });

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
  testWidgets('本地告知记录不能代替服务端 practice 授权', (t) async {
    final r = ConsentPractice();
    await r.remember('notice.v1', {'seen': true});
    await t.pumpWidget(
      MaterialApp(
        home: PracticeLobby(repo: r, scene: SceneMemory()),
      ),
    );
    await t.pumpAndSettle();
    await tapLabel(t, '先说发生了什么');
    expect(find.text('开始前，先了解记录方式'), findsOneWidget);
    await tapLabel(t, '了解，继续练习');
    expect(r.granted, isTrue);
    expect(r.creates, 1);
  });
  testWidgets('恢复上次创建也重新确认服务端授权', (t) async {
    final r = ConsentPractice();
    await r.remember('creating', {
      'input': {
        'scenario': '合成授权撤回草稿',
        'scene': 'work',
        'request_id': 'resume-after-revoke',
      },
    });
    await t.pumpWidget(
      MaterialApp(
        home: PracticeLobby(repo: r, scene: SceneMemory()),
      ),
    );
    await t.pumpAndSettle();

    await tapLabel(t, '恢复上次创建');
    expect(find.text('开始前，先了解记录方式'), findsOneWidget);
    await tapLabel(t, '暂不开始');
    expect(r.creates, 0);
    expect(r.granted, isFalse);

    await tapLabel(t, '恢复上次创建');
    await tapLabel(t, '了解，继续练习');
    expect(r.granted, isTrue);
    expect(r.creates, 1);
  });
  testWidgets('服务端授权写入失败不创建会话', (t) async {
    final r = ConsentPractice()..failGrant = true;
    await t.pumpWidget(
      MaterialApp(
        home: PracticeLobby(repo: r, scene: SceneMemory()),
      ),
    );
    await t.pumpAndSettle();
    await tapLabel(t, '先说发生了什么');
    await tapLabel(t, '了解，继续练习');
    expect(find.text('授权保存失败'), findsOneWidget);
    expect(r.creates, 0);
    expect(await r.read('creating'), isNull);
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
  testWidgets('计划深链只打开精确目标关卡', (t) async {
    final r = Recorded();
    final target = (await r.levels(Scene.work, null)).first;

    await t.pumpWidget(
      MaterialApp(
        home: PracticeLobby(
          demo: true,
          repo: r,
          scene: SceneMemory(),
          targetLevelId: target['id'] as String,
        ),
      ),
    );
    await t.pumpAndSettle();

    expect(r.creates, hasLength(1));
    expect(r.creates.single['level_id'], target['id']);
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

  testWidgets('删除关系人只清理关联预演，不留自定义场景或联系标识', (t) async {
    const contactId = 'synthetic-contact-only';
    final book = MutableBook([
      Contact.fromJson({
        'id': contactId,
        'nickname': '合成关系人',
        'scene': 'work',
        'editable': true,
        'profile': <String, dynamic>{},
      }),
    ]);
    final r = Recorded(contacts: book);
    final unrelated = await r.create({
      'request_id': 'unrelated-custom',
      'scene': 'work',
      'scenario': '没有关系人的预演',
    });
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
    await tapLabel(t, '合成关系人');
    final field = find.byType(TextField);
    await t.scrollUntilVisible(
      field,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await t.ensureVisible(field);
    await t.pumpAndSettle();
    await t.enterText(field, '只属于已删除关系人的预演');
    await t.pump();
    await tapLabel(t, '开始预演');

    final linkedId = r.creates.last['request_id'] as String;
    expect(await r.read('creating'), isNull);
    expect(await r.read('started.$linkedId'), isNull);
    expect((await r.get(linkedId))['setup']['contact_id'], contactId);

    // Remove the relation while the account stays signed in, then destroy the
    // Navigator/page tree so no in-memory Lobby state can hide a stale copy.
    await t.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await book.remove(contactId);
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

    final history = await r.history();
    expect(history.map((s) => s['session_id']), [unrelated['session_id']]);
    expect(history.every((s) => !s.containsKey('setup')), isTrue);
    await expectLater(r.get(linkedId), throwsA(isA<StateError>()));
    expect(await r.read('started.$linkedId'), isNull);
    expect(
      (await r.get(unrelated['session_id'] as String))['setup']['scenario'],
      '没有关系人的预演',
    );
  });

  testWidgets('自定义重练链在会话重建后恢复上次对比和再练入口', (t) async {
    final r = Recorded(), scene = SceneMemory(Scene.friends);
    await t.pumpWidget(
      MaterialApp(
        home: PracticeLobby(demo: true, repo: r, scene: scene),
      ),
    );
    await t.pumpAndSettle();

    await t.ensureVisible(find.byType(TextField));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), '排练和朋友约时间');
    await t.pump();
    await tapLabel(t, '开始预演');
    await say(t, 'A 第一次表达');
    await tapLabel(t, '结束并评分');
    expect(find.text('暂无可比的上次成绩'), findsOneWidget);

    await t.scrollUntilVisible(
      find.text('再练一次'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('再练一次'), findsOneWidget);
    await tapLabel(t, '再练一次');
    await say(t, 'B 第一次表达');
    await say(t, 'B 补充细节');
    final bId = r.creates.last['request_id'];
    // Destroy the navigator and both pages before B is scored. The new lobby
    // must read A's identity and B's launch context from authorized details.
    await t.pumpWidget(const SizedBox.shrink());
    await t.pumpAndSettle();

    // A new lobby and State have no local setup cache, like a process restart.
    await t.pumpWidget(
      MaterialApp(
        home: PracticeLobby(demo: true, repo: r, scene: scene),
      ),
    );
    await t.pumpAndSettle();
    await t.scrollUntilVisible(
      find.text('B 第一次表达'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tapLabel(t, 'B 第一次表达');

    await tapLabel(t, '结束并评分');
    expect(find.text('上次 60 → 本次 100（+40 分）'), findsOneWidget);
    await t.scrollUntilVisible(
      find.text('再练一次'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('再练一次'), findsOneWidget);
    await tapLabel(t, '再练一次');
    expect(find.text('排练和朋友约时间'), findsOneWidget);

    final history = await r.history();
    final latest = history.first;
    final intent = await r.read('started.${latest['session_id']}');
    expect(intent, isNull);
    expect(history.every((s) => !s.containsKey('setup')), isTrue);
    final detail = await r.get(latest['session_id']);
    expect(detail['setup']['scenario'], '排练和朋友约时间');
    expect(detail['setup']['scene'], 'friends');
    expect(detail['setup']['previous_id'], bId);
  });

  testWidgets('历史打开带关系人的预设关卡再练保留关系和关卡参数', (t) async {
    const contactId = 'history-contact';
    final book = MutableBook([
      Contact.fromJson({
        'id': contactId,
        'nickname': '历史关系人',
        'scene': 'work',
        'editable': true,
        'profile': <String, dynamic>{},
      }),
    ]);
    final r = Recorded(contacts: book);
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
    await tapLabel(t, '历史关系人');
    await tapLabel(t, '先说发生了什么');
    await say(t, '历史关系人的预设练习');
    await tapLabel(t, '结束并评分');

    // Return to history and open the completed result as a new route. The
    // history summary intentionally has no setup, so repeat must recover it
    // from the owner-only detail response before submitting.
    await t.pageBack();
    await t.pumpAndSettle();
    await t.scrollUntilVisible(
      find.text('历史关系人的预设练习'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tapLabel(t, '历史关系人的预设练习');
    await t.scrollUntilVisible(
      find.text('再练一次'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tapLabel(t, '再练一次');

    expect(r.creates, hasLength(2));
    expect(r.creates.last['level_id'], r.creates.first['level_id']);
    expect(r.creates.last['contact_id'], contactId);
    expect(r.creates.last['previous_id'], r.creates.first['request_id']);
  });

  testWidgets('详情不可得时历史保持只读且不提供重练', (t) async {
    final r = OfflineDetail(), scene = SceneMemory(Scene.friends);
    await r.create({
      'request_id': 'read-only-detail',
      'scene': 'friends',
      'scenario': '只读恢复的预演',
    });
    await pumpDemoReply(
      t,
      r.send('read-only-detail', {
        'client_message_id': 'read-only-detail-1',
        'text': '只读历史记录',
      }),
    );
    await r.finish('read-only-detail');
    r.offlineId = 'read-only-detail';

    await t.pumpWidget(
      MaterialApp(
        home: PracticeLobby(demo: true, repo: r, scene: scene),
      ),
    );
    await t.pumpAndSettle();
    await t.scrollUntilVisible(
      find.text('只读历史记录'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tapLabel(t, '只读历史记录');

    expect(find.text('NVC 总分 60 / 100'), findsOneWidget);
    await t.scrollUntilVisible(
      find.text('本场净扣 1 次'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('再练一次'), findsNothing);
    expect(r.creates, hasLength(1));
  });

  testWidgets('详情不可得时待开始历史只读且不能主动退出', (t) async {
    final r = OfflineDetail(), scene = SceneMemory(Scene.friends);
    await r.create({
      'request_id': 'pending-offline',
      'scene': 'friends',
      'scenario': '待开始的只读预演',
    });
    r.offlineId = 'pending-offline';

    await t.pumpWidget(
      MaterialApp(
        home: PracticeLobby(demo: true, repo: r, scene: scene),
      ),
    );
    await t.pumpAndSettle();
    await t.scrollUntilVisible(
      find.text('尚未发言的练习'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tapLabel(t, '尚未发言的练习');

    expect(find.text('恢复会话'), findsOneWidget);
    expect(find.text('当前只能查看已有内容。恢复会话后才能发言、评分或主动退出。'), findsOneWidget);
    expect(t.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    final exit = t.widget<TextButton>(find.widgetWithText(TextButton, '主动退出'));
    expect(exit.onPressed, isNull);
    expect(find.text('结束并评分'), findsNothing);
    expect(r.exits, 0);
  });

  testWidgets('详情不可得时进行中历史只读且不能主动退出', (t) async {
    final r = OfflineDetail(), scene = SceneMemory(Scene.friends);
    await r.create({
      'request_id': 'active-offline',
      'scene': 'friends',
      'scenario': '进行中的只读预演',
    });
    await pumpDemoReply(
      t,
      r.send('active-offline', {
        'client_message_id': 'active-offline-1',
        'text': '已经保存的发言',
      }),
    );
    r.offlineId = 'active-offline';

    await t.pumpWidget(
      MaterialApp(
        home: PracticeLobby(demo: true, repo: r, scene: scene),
      ),
    );
    await t.pumpAndSettle();
    await t.scrollUntilVisible(
      find.text('已经保存的发言'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tapLabel(t, '已经保存的发言');

    expect(find.text('恢复会话'), findsOneWidget);
    expect(find.text('当前只能查看已有内容。恢复会话后才能发言、评分或主动退出。'), findsOneWidget);
    expect(t.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    final exit = t.widget<TextButton>(find.widgetWithText(TextButton, '主动退出'));
    expect(exit.onPressed, isNull);
    expect(find.text('结束并评分'), findsNothing);
    expect(r.exits, 0);
  });

  testWidgets('大厅详情失败后聊天恢复自定义预演对比与重练上下文', (t) async {
    final r = OfflineDetail(), scene = SceneMemory(Scene.friends);
    await r.create({
      'request_id': 'offline-a',
      'scene': 'friends',
      'scenario': '离线后恢复的预演',
    });
    await pumpDemoReply(
      t,
      r.send('offline-a', {
        'client_message_id': 'offline-a-1',
        'text': 'A 第一次表达',
      }),
    );
    await r.finish('offline-a');

    await r.create({
      'request_id': 'offline-b',
      'scene': 'friends',
      'scenario': '离线后恢复的预演',
      'previous_id': 'offline-a',
    });
    await pumpDemoReply(
      t,
      r.send('offline-b', {
        'client_message_id': 'offline-b-1',
        'text': 'B 第一次表达',
      }),
    );
    await pumpDemoReply(
      t,
      r.send('offline-b', {
        'client_message_id': 'offline-b-2',
        'text': 'B 补充细节',
      }),
    );

    r.offlineId = 'offline-b';
    await t.pumpWidget(
      MaterialApp(
        home: PracticeLobby(demo: true, repo: r, scene: scene),
      ),
    );
    await t.pumpAndSettle();
    await t.scrollUntilVisible(
      find.text('B 第一次表达'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tapLabel(t, 'B 第一次表达');
    expect(find.text('恢复会话'), findsOneWidget);

    // The summary route stayed readable while offline. A later successful GET
    // must supply both the launch seed and previous_id to the settled result.
    r.offlineId = null;
    await tapLabel(t, '恢复会话');
    await tapLabel(t, '结束并评分');
    expect(find.text('上次 60 → 本次 100（+40 分）'), findsOneWidget);
    await t.scrollUntilVisible(
      find.text('再练一次'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tapLabel(t, '再练一次');

    expect(find.text('离线后恢复的预演'), findsOneWidget);
    expect(r.creates.last['scenario'], '离线后恢复的预演');
    expect(r.creates.last['previous_id'], 'offline-b');
  });
}
