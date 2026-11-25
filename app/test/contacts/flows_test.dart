import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/contacts/deletion.dart';
import 'package:high_eq/features/contacts/demo.dart';
import 'package:high_eq/features/contacts/inference.dart';
import 'package:high_eq/features/contacts/models.dart';
import 'package:high_eq/features/contacts/purpose.dart';
import 'package:high_eq/features/contacts/scene.dart';
import 'package:high_eq/features/contacts/workspace.dart';

const _fixtureProfile = <String, dynamic>{
  'summary': '更倾向先听完再回应',
  'big_five': [
    {'label': '沟通练习', 'confidence': 0.5},
  ],
  'conflict_style': {'label': '沟通练习', 'confidence': 0.5},
  'attachment': null,
};

const _fixtureQuestions = <Question>[
  (id: 'q1', prompt: '意见不同时通常怎么回应？'),
  (id: 'q2', prompt: '喜欢当面谈还是稍后再谈？'),
  (id: 'q3', prompt: '会主动说出需要吗？'),
  (id: 'q4', prompt: '压力大时常有什么表现？'),
  (id: 'q5', prompt: '怎样提建议更容易接受？'),
];

class Fixture extends DemoContacts {
  Json? saved;
  bool offline = false, member = false, forbidden = false, safety = false;
  Object? removeError;
  final events = <String>[];
  final rows = <Contact>[
    Contact.fromJson({
      'id': 'contact-a',
      'nickname': '同事 A',
      'scene': 'work',
      'editable': true,
      'profile': _fixtureProfile,
    }),
    Contact.fromJson({
      'id': 'contact-b',
      'nickname': '老朋友',
      'scene': 'friends',
      'editable': false,
      'profile': _fixtureProfile,
    }),
  ];
  int _nextId = 1;

  Json get _rights => member
      ? {
          'tier': 'member',
          'max_active_contacts': null,
          'expires_at': DateTime.now()
              .add(const Duration(hours: 1))
              .toUtc()
              .toIso8601String(),
        }
      : {'tier': 'free', 'max_active_contacts': 1, 'expires_at': null};

  Contact _copy(Contact c, {bool? editable}) => Contact.fromJson({
    'id': c.id,
    'nickname': c.name,
    'scene': c.scene.name,
    'editable': editable ?? c.editable,
    'profile': c.profile,
  });

  @override
  Future<Book> load() async {
    if (offline) throw StateError('sensitive response');
    return Book([
      for (final c in rows) _copy(c, editable: member ? true : c.editable),
    ], _rights);
  }

  @override
  Future<List<Question>> questions() async => List.of(_fixtureQuestions);

  @override
  Future<void> save(Json input, {String? id}) async {
    if (forbidden) throw const ApiFailure(403, 'forbidden', '私密响应', false);
    saved = input;
    if (id == null) {
      final book = await load();
      if (!book.canAdd) throw StateError('名额已用');
      rows.add(
        Contact.fromJson({
          'id': 'fixture-${_nextId++}',
          'nickname': input['nickname'],
          'scene': input['scene'],
          'editable': true,
          'profile': _fixtureProfile,
        }),
      );
      return;
    }
    final index = rows.indexWhere((c) => c.id == id && c.editable);
    if (index < 0) throw StateError('关系人不可编辑');
    final current = rows[index];
    rows[index] = Contact.fromJson({
      'id': current.id,
      'nickname': input['nickname'],
      'scene': input['scene'],
      'editable': true,
      'profile': current.profile,
    });
  }

  @override
  Future<void> remove(String id) async {
    events.add('remove');
    final error = removeError;
    if (error != null) throw error;
    rows.removeWhere((c) => c.id == id);
    if (!member && rows.isNotEmpty && !rows.any((c) => c.editable)) {
      rows[0] = _copy(rows[0], editable: true);
    }
  }

  @override
  Future<void> choose(String id) async {
    for (var i = 0; i < rows.length; i++) {
      rows[i] = _copy(rows[i], editable: rows[i].id == id);
    }
  }

  @override
  Future<ProfileInferenceResult> infer(
    String id,
    String requestId,
    String text, {
    required ContactInferenceGrant authorization,
  }) async => safety
      ? const ProfileInferenceSafety()
      : const ProfileInferenceCompleted(_fixtureProfile);
}

class InferenceFixture extends Fixture {
  bool pendingInference = true;
  final inferenceCalls =
      <({String contactId, String requestId, String text})>[];

  @override
  Future<Book> load() async => Book(
    [
      Contact.fromJson({
        'id': 'synthetic-contact',
        'nickname': '同事 A',
        'scene': 'work',
        'editable': true,
        'profile': _fixtureProfile,
      }),
    ],
    {'tier': 'free', 'max_active_contacts': 1},
  );

  @override
  Future<ProfileInferenceResult> infer(
    String contactId,
    String requestId,
    String text, {
    required ContactInferenceGrant authorization,
  }) async {
    inferenceCalls.add((
      contactId: contactId,
      requestId: requestId,
      text: text,
    ));
    return pendingInference
        ? const ProfileInferenceProcessing()
        : const ProfileInferenceCompleted(_fixtureProfile);
  }
}

class FlowDeletion implements ContactDeletion {
  FlowDeletion(this.repo, this.prepare, this.confirm);

  final Fixture repo;
  final Future<void> Function() prepare, confirm;
  GrowthDeletion? operation;

  @override
  Future<List<GrowthDeletion>> pending() async => [?operation];

  @override
  Future<void> remove(String contactId, {GrowthDeletion? retry}) async {
    try {
      await prepare();
    } on Object {
      throw const DeletionNotSent();
    }
    operation = (contactId: contactId, operationId: 'fixture');
    await repo.remove(contactId);
    operation = null;
    try {
      await confirm();
    } on Object {
      throw const DeletionCacheUnconfirmed();
    }
  }

  @override
  Future<DeletionCheck> check(
    GrowthDeletion operation, {
    bool abandon = false,
  }) => throw UnimplementedError();
}

Future<void> open(
  WidgetTester t,
  Fixture f, {
  Future<void> Function()? onDeletePreparing,
  Future<void> Function()? onDeleted,
}) async {
  await t.pumpWidget(
    MaterialApp(
      home: ContactsWorkspace(
        key: ObjectKey(f),
        repo: f,
        selection: SceneMemory(Scene.family),
        deletion: onDeletePreparing == null || onDeleted == null
            ? null
            : FlowDeletion(f, onDeletePreparing, onDeleted),
      ),
    ),
  );
  await t.pumpAndSettle();
}

Future<void> tap(WidgetTester t, String label) async {
  await t.pump();
  final w = find.text(label).last;
  await t.ensureVisible(w);
  await t.tap(w);
  await t.pumpAndSettle();
}

void main() {
  testWidgets('确认删除成功后才清理成长缓存', (t) async {
    final f = Fixture();
    await open(
      t,
      f,
      onDeletePreparing: () async => f.events.add('prepare'),
      onDeleted: () async => f.events.add('confirm'),
    );

    await tap(t, '同事 A');
    await tap(t, '删除关系人');
    await tap(t, '确认删除');

    expect(f.events, ['prepare', 'remove', 'confirm']);
    expect(find.text('同事 A'), findsNothing);
    expect(find.text('关系人已删除。'), findsOneWidget);
  });

  testWidgets('ok:false 或未确认回执不得清理成长缓存', (t) async {
    final f = Fixture()..removeError = const FormatException('未确认删除');
    await open(
      t,
      f,
      onDeletePreparing: () async => f.events.add('prepare'),
      onDeleted: () async => f.events.add('confirm'),
    );

    await tap(t, '同事 A');
    await tap(t, '删除关系人');
    await tap(t, '确认删除');

    expect(f.events, ['prepare', 'remove']);
    expect(find.text('同事 A'), findsOneWidget);
    expect(find.text('暂时无法确认删除结果。请点「核对删除结果」。'), findsOneWidget);
    expect(find.text('核对删除结果'), findsOneWidget);
  });

  testWidgets('403/404 不当作删除确认，也不清理成长缓存', (t) async {
    for (final status in [403, 404]) {
      final f = Fixture()
        ..removeError = ApiFailure(status, 'denied', '服务端拒绝', false);
      await open(
        t,
        f,
        onDeletePreparing: () async => f.events.add('prepare'),
        onDeleted: () async => f.events.add('confirm'),
      );

      await tap(t, '同事 A');
      await tap(t, '删除关系人');
      await tap(t, '确认删除');

      expect(f.events, ['prepare', 'remove']);
      expect(find.text('权限或关系人已变更，删除结果尚未确认。请点「核对删除结果」。'), findsOneWidget);
      expect(find.text('核对删除结果'), findsOneWidget);
    }
  });

  testWidgets('删除围栏写入失败时不得发送 DELETE', (t) async {
    final f = Fixture();
    await open(
      t,
      f,
      onDeletePreparing: () async {
        f.events.add('prepare');
        throw StateError('support unavailable');
      },
      onDeleted: () async => f.events.add('confirm'),
    );

    await tap(t, '同事 A');
    await tap(t, '删除关系人');
    await tap(t, '确认删除');

    expect(f.events, ['prepare']);
    expect(find.textContaining('删除「同事 A」'), findsOneWidget);
    expect(find.text('确认删除'), findsOneWidget);
    expect(find.textContaining('删除未发送'), findsOneWidget);
  });

  testWidgets('取消删除不写围栏也不发送 DELETE', (t) async {
    final f = Fixture();
    await open(
      t,
      f,
      onDeletePreparing: () async => f.events.add('prepare'),
      onDeleted: () async => f.events.add('confirm'),
    );

    await tap(t, '同事 A');
    await tap(t, '删除关系人');
    await tap(t, '取消');

    expect(f.events, isEmpty);
    expect(find.text('同事 A'), findsOneWidget);
  });

  testWidgets('关系人已删除但缓存清理失败时明确提示且不伪装成删除失败', (t) async {
    final f = Fixture();
    await open(
      t,
      f,
      onDeletePreparing: () async => f.events.add('prepare'),
      onDeleted: () async => throw StateError('cache unavailable'),
    );

    await tap(t, '同事 A');
    await tap(t, '删除关系人');
    await tap(t, '确认删除');

    expect(find.text('同事 A'), findsNothing);
    expect(f.events, ['prepare', 'remove']);
    expect(find.textContaining('关系人已删除，但本机成长缓存暂未清理'), findsOneWidget);
  });

  testWidgets('远端题目→创建→详情→修改→可选导入→确认删除', (t) async {
    final f = Fixture();
    for (final c in (await f.load()).people) {
      await f.remove(c.id);
    }
    await open(t, f);
    await tap(t, '添加关系人');
    await tap(t, '同意并继续');
    expect(find.textContaining('注销账号'), findsOneWidget);
    await t.enterText(find.byType(TextField), '家里人');
    await tap(t, '下一步');
    final qs = await f.questions();
    for (var i = 0; i < qs.length; i++) {
      expect(find.text(qs[i].prompt), findsOneWidget);
      await tap(t, '还不确定');
      await tap(t, i == qs.length - 1 ? '保存关系人' : '下一步');
    }
    expect(f.saved, {
      'nickname': '家里人',
      'scene': 'family',
      'answers': [
        for (final q in qs) {'question_id': q.id, 'answer': '还不确定'},
      ],
    });
    await tap(t, '家里人');
    expect(find.text('把握度 50%'), findsWidgets);
    expect(find.text('亲密相处时'), findsNothing);
    await tap(t, '编辑资料');
    await t.enterText(find.byType(TextField), '小姨');
    await tap(t, '保存关系人');
    expect(f.saved, {'nickname': '小姨', 'scene': 'family'});
    await tap(t, '小姨');
    await tap(t, '导入聊天片段');
    expect(find.textContaining('新提交只用于本次画像推断'), findsOneWidget);
    expect(find.textContaining('既有导入记录满 24 小时后从导出中排除'), findsOneWidget);
    await tap(t, '同意并继续');
    expect(find.textContaining('24 小时内删除'), findsNothing);
    expect(find.textContaining('当前导出仅含未过期记录的定位信息'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await tap(t, '我已了解，并有权分享这段内容');
    await t.enterText(find.byType(TextField), '仅供测试的内容');
    f.safety = true;
    await tap(t, '提交片段');
    expect(find.text(profileInferenceSafetyMessage), findsOneWidget);
    expect(find.textContaining('仅供测试'), findsNothing);
    await tap(t, '删除关系人');
    expect(find.textContaining('关联互动记录和评分副本'), findsOneWidget);
    await tap(t, '取消');
    expect(find.text('小姨'), findsOneWidget);
    await tap(t, '删除关系人');
    await tap(t, '确认删除');
    expect(find.text('小姨'), findsNothing);
    expect((await f.load()).people, isEmpty);
  });
  testWidgets('画像同意不提交正文；明确提交后 202 只重试原请求', (t) async {
    final f = InferenceFixture();
    await f.grant(ContactPurpose.contacts);
    await open(t, f);
    await tap(t, '同事 A');
    await tap(t, '导入聊天片段');
    await tap(t, '同意并继续');
    expect(f.inferenceCalls, isEmpty);
    await tap(t, '我已了解，并有权分享这段内容');
    await t.enterText(find.byType(TextField), '合成片段');
    expect(f.inferenceCalls, isEmpty);
    await tap(t, '提交片段');

    expect(f.inferenceCalls, hasLength(1));
    final original = f.inferenceCalls.single;
    expect(original.text, '合成片段');
    expect(find.text('画像仍在处理中，不是已更新。'), findsOneWidget);
    expect(find.text('画像已更新，仅供参考。'), findsNothing);
    f.pendingInference = false;
    await tap(t, '重试获取结果');

    expect(f.inferenceCalls, hasLength(2));
    expect(f.inferenceCalls[1], original);
    expect(find.text('画像已更新，仅供参考。'), findsOneWidget);
    expect(find.text('重试获取结果'), findsNothing);
  });
  testWidgets('加载失败可重试；续费刷新解锁；编辑被 403 拒绝则不保留写权限', (t) async {
    final f = Fixture()..offline = true;
    await open(t, f);
    expect(find.text('重试'), findsOneWidget);
    expect(find.textContaining('sensitive'), findsNothing);
    f.offline = false;
    await tap(t, '重试');
    await tap(t, '老朋友');
    expect(find.text('编辑资料'), findsNothing);
    f.member = true;
    await t.tap(find.byTooltip('刷新列表'));
    await t.pumpAndSettle();
    await tap(t, '编辑资料');
    await tap(t, '同意并继续');
    f.member = false;
    f.forbidden = true;
    await tap(t, '保存关系人');
    expect(find.textContaining('权限或关系人已变更'), findsOneWidget);
    await tap(t, '老朋友');
    expect(find.text('导入聊天片段'), findsNothing);
    expect(find.textContaining('私密响应'), findsNothing);
  });
}
