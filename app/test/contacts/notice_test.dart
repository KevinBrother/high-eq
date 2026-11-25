import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/features/contacts/forms.dart';

void main() {
  testWidgets('聊天导入告知不承诺供应商、日志、备份或介质副本按 24 小时删除', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: ChatForm(onSubmit: (_) {})),
        ),
      ),
    );

    expect(find.text(chatRetentionPrimary), findsOneWidget);
    expect(find.text(chatRetentionDetails), findsOneWidget);
    expect(find.textContaining('既有导入记录满 24 小时后从导出中排除并尝试清除'), findsOneWidget);
    expect(find.textContaining('故障可能推迟清除，系统会重试'), findsOneWidget);
    expect(find.textContaining('当前导出仅含未过期记录的定位信息，不含原文'), findsOneWidget);
    expect(find.textContaining('供应商、日志、备份或物理介质副本不保证同期删除'), findsOneWidget);
    expect(find.textContaining('24 小时内删除'), findsNothing);
    expect(find.textContaining('24 小时后尝试清扫'), findsNothing);
  });
}
