import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/features/emotion/decision.dart';

void main() {
  test('Dart classifier passes every real T30 decision vector', () {
    final file = File('../server/internal/emotion/testdata/decisions.json');
    final rows = (jsonDecode(file.readAsStringSync()) as List)
        .cast<Map<String, dynamic>>();
    expect(rows, hasLength(23));
    for (final row in rows) {
      final input = row['input'] as Map<String, dynamic>;
      final actual = EmotionDecision.evaluate(input).kind;
      expect(actual, row['want'], reason: row['name'] as String);
    }
  });
}
