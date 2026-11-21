import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/features/onboarding/score.dart';

void main() {
  test('band precedes rounding at all four boundaries', () {
    for (final (cut, level) in [(40, 1), (60, 2), (75, 3), (90, 4)]) {
      expect(scoreLevel(cut - .1), level);
      expect((cut - .1).round(), cut);
      expect(scoreLevel(cut.toDouble()), level + 1);
    }
  });
  test(
    'demo scores four distinct dimensions and total; incomplete is invalid',
    () {
      final result = demoScore([
        for (final n in [1, 3, 5, 7]) ...List.filled(4, n),
      ], DateTime.utc(2026, 11, 1));
      expect(result['dimensions']['SEA']['percent'], 0);
      expect(result['dimensions']['ROE']['percent'], 100);
      expect(result['total']['percent'], 50);
      expect(result['next_eligible_at'], '2026-11-29T00:00:00.000Z');
      expect(() => demoScore([1], DateTime.now()), throwsFormatException);
    },
  );
}
