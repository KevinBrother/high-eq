import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/features/contacts/demo.dart';
import 'package:high_eq/features/contacts/inference.dart';
import 'package:high_eq/features/contacts/models.dart';
import 'package:high_eq/features/contacts/purpose.dart';
import 'package:high_eq/features/contacts/scene.dart';
import 'package:high_eq/features/contacts/workspace.dart';

typedef _Call = ({String contactId, String requestId, String text});

const _initialProfile = <String, dynamic>{
  'summary': '更倾向先听完再回应',
  'big_five': [
    {'label': '沟通练习', 'confidence': 0.5},
  ],
  'conflict_style': {'label': '沟通练习', 'confidence': 0.5},
  'attachment': null,
};

const _completedProfile = <String, dynamic>{
  'summary': '完成后新的画像线索',
  'big_five': [
    {'label': '合作型', 'confidence': 0.8},
  ],
  'conflict_style': {'label': '合作型', 'confidence': 0.7},
  'attachment': null,
};

final class _PageFixture extends DemoContacts {
  _PageFixture({Set<ContactPurpose>? grants, List<Object>? responses})
    : grants = {ContactPurpose.contacts, ContactPurpose.chatImport, ...?grants},
      responses = [...?responses];

  final Set<ContactPurpose> grants;
  final List<Object> responses;
  final List<_Call> inferenceCalls = [];
  bool dropContacts = false;

  @override
  Future<ContactConsentSnapshot> currentConsents() async =>
      ContactConsentSnapshot('fixture', {
        for (final purpose in grants) purpose: 'fixture-${purpose.wire}',
      });

  @override
  Future<void> grant(ContactPurpose purpose) async {
    grants.add(purpose);
  }

  @override
  Future<Book> load() async {
    final rights = <String, dynamic>{
      'tier': 'free',
      'max_active_contacts': 1,
      'expires_at': null,
    };
    if (dropContacts) return Book([], rights);
    return Book([
      Contact.fromJson({
        'id': 'contact-a',
        'nickname': '同事 A',
        'scene': 'work',
        'editable': true,
        'profile': _initialProfile,
      }),
    ], rights);
  }

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
    if (responses.isEmpty) fail('测试未配置推断响应');
    final response = responses.removeAt(0);
    if (response is ProfileInferenceResult) return response;
    throw response;
  }
}

Future<void> _open(WidgetTester tester, _PageFixture fixture) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.light,
      ),
      home: ContactsWorkspace(
        repo: fixture,
        selection: SceneMemory(Scene.work),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await _tap(tester, '同事 A');
}

Future<void> _tap(WidgetTester tester, String label) async {
  await tester.pump();
  final target = find.text(label).last;
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _submit(WidgetTester tester, String text) async {
  await _tap(tester, '导入聊天片段');
  await _tap(tester, '我已了解，并有权分享这段内容');
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
  await _tap(tester, '提交片段');
}

void main() {
  testWidgets('202 只显示处理中；同次重试复用原三元组，完成后才更新并可开新请求', (tester) async {
    final fixture = _PageFixture(
      responses: [
        const ProfileInferenceProcessing(),
        const ProfileInferenceCompleted(_completedProfile),
        const ProfileInferenceProcessing(),
      ],
    );
    await _open(tester, fixture);

    await _submit(tester, '第一段合成片段');
    expect(fixture.inferenceCalls, hasLength(1));
    expect(find.text('画像仍在处理中，不是已更新。'), findsOneWidget);
    expect(find.text('重试获取结果'), findsOneWidget);
    expect(find.text('画像已更新，仅供参考。'), findsNothing);
    expect(find.text('导入聊天片段'), findsNothing);

    final first = fixture.inferenceCalls.single;
    await _tap(tester, '重试获取结果');

    expect(fixture.inferenceCalls, hasLength(2));
    expect(fixture.inferenceCalls[1], first);
    expect(find.text('画像已更新，仅供参考。'), findsOneWidget);
    expect(find.textContaining('完成后新的画像线索'), findsOneWidget);
    expect(find.text('重试获取结果'), findsNothing);

    await _submit(tester, '第二段合成片段');
    expect(fixture.inferenceCalls, hasLength(3));
    final third = fixture.inferenceCalls.last;
    expect(third.contactId, first.contactId);
    expect(third.requestId, isNot(first.requestId));
    expect(third.text, '第二段合成片段');
    expect(find.text('画像仍在处理中，不是已更新。'), findsOneWidget);
  });

  testWidgets('503 保留原操作可重试；重试前撤权不发送且旧材料与重试入口消失', (tester) async {
    final fixture = _PageFixture(
      responses: [const ApiFailure(503, 'service_unavailable', '私密服务响应', true)],
    );
    await _open(tester, fixture);

    await _submit(tester, '不可回放的合成片段');
    expect(fixture.inferenceCalls, hasLength(1));
    expect(find.text('服务暂不可用，可重试。本次未展示新的画像。'), findsOneWidget);
    expect(find.text('重试获取结果'), findsOneWidget);
    expect(find.text('画像已更新，仅供参考。'), findsNothing);

    fixture.grants.remove(ContactPurpose.chatImport);
    await _tap(tester, '重试获取结果');

    expect(fixture.inferenceCalls, hasLength(1));
    expect(find.text('允许使用聊天片段推断画像？'), findsOneWidget);
    expect(find.text('重试获取结果'), findsNothing);
    expect(find.text('粘贴必要片段'), findsNothing);
    expect(find.textContaining('不可回放的合成片段'), findsNothing);

    await _tap(tester, '同意并继续');
    expect(find.text('补充一次对话'), findsOneWidget);
    expect(find.text('我已了解，并有权分享这段内容'), findsOneWidget);
    expect(find.text('粘贴必要片段'), findsNothing);
    expect(fixture.inferenceCalls, hasLength(1));
  });

  testWidgets('409 终结旧操作，不再提供同请求重试', (tester) async {
    final fixture = _PageFixture(
      responses: [
        const ProfileInferenceProcessing(),
        const ApiFailure(409, 'inference_invalidated', '响应不可展示', false),
      ],
    );
    await _open(tester, fixture);
    await _submit(tester, '撤权后失效的合成片段');
    await _tap(tester, '重试获取结果');

    expect(fixture.inferenceCalls, hasLength(2));
    expect(fixture.inferenceCalls[1], fixture.inferenceCalls[0]);
    expect(find.text('这次请求已失效，不能继续重试。请重新导入片段。'), findsOneWidget);
    expect(find.text('重试获取结果'), findsNothing);
    expect(find.text('导入聊天片段'), findsOneWidget);
  });

  testWidgets('Safety 终结本次操作，保留固定提示且不展示画像成功', (tester) async {
    final fixture = _PageFixture(responses: [const ProfileInferenceSafety()]);
    await _open(tester, fixture);
    await _submit(tester, '需要安全分流的合成片段');

    expect(find.text(profileInferenceSafetyMessage), findsOneWidget);
    expect(find.text('画像已更新，仅供参考。'), findsNothing);
    expect(find.text('重试获取结果'), findsNothing);
    expect(find.text('导入聊天片段'), findsOneWidget);
  });

  testWidgets('200 但响应不完整时终结，不提供同请求重试', (tester) async {
    final fixture = _PageFixture(
      responses: [const ProfileInferenceTerminal(200)],
    );
    await _open(tester, fixture);
    await _submit(tester, '不完整响应的合成片段');

    expect(find.text('画像结果不完整，本次导入已结束。请刷新后核对。'), findsOneWidget);
    expect(find.text('画像已更新，仅供参考。'), findsNothing);
    expect(find.text('重试获取结果'), findsNothing);
    expect(find.text('导入聊天片段'), findsOneWidget);
  });

  testWidgets('SessionChanged 清空旧账号的待处理材料与结果', (tester) async {
    final fixture = _PageFixture(
      responses: [const ProfileInferenceProcessing(), SessionChanged()],
    );
    await _open(tester, fixture);
    await _submit(tester, 'A 账号的合成片段');
    await _tap(tester, '重试获取结果');

    expect(fixture.inferenceCalls, hasLength(2));
    expect(fixture.inferenceCalls[1], fixture.inferenceCalls[0]);
    expect(find.text('账号已切换，请重新打开关系人。'), findsOneWidget);
    expect(find.text('重试获取结果'), findsNothing);
    expect(find.textContaining('A 账号的合成片段'), findsNothing);
  });

  testWidgets('刷新发现联系人失效后清空待处理操作并回到列表', (tester) async {
    final fixture = _PageFixture(
      responses: [const ProfileInferenceProcessing()],
    );
    await _open(tester, fixture);
    await _submit(tester, '联系人失效前的合成片段');
    expect(find.text('重试获取结果'), findsOneWidget);

    fixture.dropContacts = true;
    await tester.tap(find.byTooltip('刷新列表'));
    await tester.pumpAndSettle();

    expect(find.text('重试获取结果'), findsNothing);
    expect(find.text('同事 A'), findsNothing);
    expect(find.text('还没有关系人。从一个常交流的人开始吧。'), findsOneWidget);
    expect(fixture.inferenceCalls, hasLength(1));
  });
}
