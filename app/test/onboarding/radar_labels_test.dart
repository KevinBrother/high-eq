import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/features/onboarding/radar.dart';

void main() {
  testWidgets('雷达四轴在图上可直接定位，小屏大字仍可查看分数与原始分档', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.8)),
          child: const Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: 286,
                child: AssessmentRadar(
                  percentages: {'SEA': 59.9, 'OEA': 85, 'UOE': 15, 'ROE': 75},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final top = t.getCenter(find.text('自我觉察'));
    final right = t.getCenter(find.text('读懂别人'));
    final bottom = t.getCenter(find.text('自我激励'));
    final left = t.getCenter(find.text('自我管理'));
    expect(top.dy, lessThan(right.dy));
    expect(bottom.dy, greaterThan(left.dy));
    expect(right.dx, greaterThan(left.dx));
    expect(find.text('自我觉察 · 60 / 100'), findsOneWidget);
    expect(find.text('L2'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
