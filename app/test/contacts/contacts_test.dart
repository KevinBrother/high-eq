import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/features/contacts/scene.dart';
import 'package:high_eq/features/contacts/profile.dart';
import 'package:high_eq/features/contacts/workspace.dart';
import 'package:high_eq/features/contacts/demo.dart';
import 'package:high_eq/features/contacts/models.dart';

void main() {
  testWidgets('五个场景：选择一次，同一会话的第二个组件立即同步', (t) async {
    final selection = SceneMemory();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              for (var i = 0; i < 2; i++) GlobalScenePicker(selection),
            ],
          ),
        ),
      ),
    );
    await t.tap(find.widgetWithText(ChoiceChip, '伴侣').first);
    await t.pumpAndSettle();
    expect(selection.value, Scene.partner);
    expect(
      t
          .widgetList<ChoiceChip>(find.widgetWithText(ChoiceChip, '伴侣'))
          .every((c) => c.selected),
      true,
    );
  });
  test('隐藏绝对化与诊断词；不得把禁止内容加上“可能”继续显示', () {
    for (final s in ['对方一定会生气', '这是人格障碍', '他从不让步']) {
      expect(observation(s), isNot(contains(s)));
    }
    expect(observation('更倾向先听完再回应'), contains('先听完'));
    expect(observation('妥协型'), contains('各让一步'));
    expect(observation('回避型依恋'), isNot(contains('依恋')));
  });
  testWidgets('紧凑宽度大字画像：只有伴侣显示亲密线索，标签逐项过滤', (t) async {
    t.view.physicalSize = const Size(320, 640);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    for (final scene in [Scene.work, Scene.partner]) {
      final p = Contact.fromJson({
        'id': 'X',
        'nickname': '一位熟悉的人',
        'editable': true,
        'scene': scene.name,
        'profile': {
          'summary': '总是会生气',
          'big_five': [
            {'label': '宜人性高', 'confidence': 0.65},
          ],
          'conflict_style': {'label': '人格障碍', 'confidence': 0.4},
          'attachment': {'label': '回避型依恋', 'confidence': 0.55},
        },
      });
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.8)),
              child: SingleChildScrollView(child: ProfileView(p)),
            ),
          ),
        ),
      );
      expect(find.textContaining('总是'), findsNothing);
      expect(find.textContaining('人格障碍'), findsNothing);
      expect(find.text('把握度 65%'), findsOneWidget);
      expect(
        find.text('亲密相处时'),
        scene == Scene.partner ? findsOneWidget : findsNothing,
      );
      expect(t.takeException(), isNull);
    }
  });
  testWidgets('到期后只读可查看、不能编辑或导入，改选须二次确认', (t) async {
    final repo = DemoContacts();
    await t.pumpWidget(
      MaterialApp(
        home: ContactsWorkspace(
          repo: repo,
          selection: SceneMemory(),
          demo: true,
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('添加关系人'), findsOneWidget);
    expect(
      t
          .widget<FilledButton>(
            find.ancestor(
              of: find.text('添加关系人'),
              matching: find.byWidgetPredicate((w) => w is FilledButton),
            ),
          )
          .onPressed,
      isNull,
    );
    await t.tap(find.text('老朋友'));
    await t.pumpAndSettle();
    expect(find.textContaining('仅供参考'), findsWidgets);
    expect(find.text('编辑资料'), findsNothing);
    expect(find.text('导入聊天片段'), findsNothing);
    await t.ensureVisible(find.text('改选为可用关系人'));
    await t.tap(find.text('改选为可用关系人'));
    await t.pumpAndSettle();
    await t.tap(find.text('确认改选'));
    await t.pumpAndSettle();
    expect(find.text('编辑资料'), findsOneWidget);
  });
}
