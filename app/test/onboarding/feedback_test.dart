import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/features/onboarding/surface.dart';

void main() {
  test('待批准的交易不能提示立即重试付款', () {
    expect(
      friendlyError(PlatformException(code: 'pending')),
      contains('不要重复购买'),
    );
  });
  testWidgets('在长页面底部操作时反馈仍立即可见', (t) async {
    final message = ValueNotifier<String?>(null);
    addTearDown(message.dispose);
    await t.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<String?>(
          valueListenable: message,
          builder: (_, text, _) => FlowSurface('会员', '权益', [
            const SizedBox(height: 1400),
            FilledButton(
              onPressed: () => message.value = '等待交易确认',
              child: const Text('查询交易'),
            ),
          ], message: text),
        ),
      ),
    );
    await t.drag(find.byType(ListView), const Offset(0, -1800));
    await t.pumpAndSettle();
    await t.tap(find.text('查询交易'));
    await t.pumpAndSettle();
    final y = t.getCenter(find.text('等待交易确认')).dy;
    expect(y, greaterThan(0));
    expect(y, lessThan(t.view.physicalSize.height / t.view.devicePixelRatio));
  });
}
