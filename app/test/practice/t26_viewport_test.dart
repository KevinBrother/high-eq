import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/features/practice/chat.dart';
import 'package:high_eq/features/practice/demo.dart';
import 'package:high_eq/features/practice/result.dart';

import '../../tool/t26/plan_practice_steps.dart';

void main() {
  testWidgets('短视口回复已保存时滚动聊天底栏才能点击评分', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 420);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = DemoPractice();
    final session = await repo.create({
      'request_id': 't26-viewport',
      'level_id': demoPlanLevelId,
    });
    await tester.pumpWidget(
      MaterialApp(
        home: PracticeChat(repo: repo, initial: session),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '合成视口回归');
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect((await repo.get('t26-viewport'))['messages'], hasLength(2));

    // Keep the keyboard inset while the footer below the chat is scrolled.
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    final finish = find.widgetWithText(TextButton, '结束并评分');
    expect(finish, findsOneWidget);
    expect(finish.hitTestable(), findsNothing);

    await tester.tap(await revealT26PracticeControl(tester, finish));
    await tester.pumpAndSettle();
    expect(find.byType(PracticeResult), findsOneWidget);
    expect(find.text('整场反馈'), findsOneWidget);
    expect((await repo.get('t26-viewport'))['status'], 'complete');
  });
}
