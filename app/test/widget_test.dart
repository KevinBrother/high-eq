import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/features/home/shell.dart';

void main() {
  testWidgets('four accessible destinations at compact width and large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 650);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.5)),
          child: child!,
        ),
        home: const HomeShell(Section.practice),
        routes: {for (final s in Section.values) s.path: (_) => HomeShell(s)},
      ),
    );
    for (final tab in Section.values) {
      await tester.tap(
        find
            .descendant(
              of: find.byType(NavigationBar),
              matching: find.text(tab.label),
            )
            .last,
      );
      await tester.pumpAndSettle();
      expect(find.text(tab.title), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
}
