import 'package:flutter_test/flutter_test.dart';

// DemoPractice streams two fragments, each followed by a 100ms timer. Tests
// seed completed history before rendering, so explicitly drive the fake clock.
Future<void> pumpDemoReply<T>(WidgetTester tester, Stream<T> stream) async {
  final done = stream.drain<void>();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
  await done;
}
