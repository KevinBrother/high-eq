import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/features/health/windows.dart';

void main() {
  test(
    'UTC boundaries, sparse HRV, overlapping exercise and fractional steps',
    () {
      final w = healthWindows('apple_history', 30000, 90000, [
        ['heart_rate', 30100, 30100, 62],
        ['heart_rate', 30999, 30999, 78],
        ['steps', 45000, 75000, 45],
        ['exercise', 59000, 61000, 1],
        ['hrv', 60000, 60000, 23],
        ['heart_rate', 90000, 90000, 120],
      ]);
      expect(w.length, 2);
      expect(w.first['heart_rate'], {
        'mean': 70.0,
        'maximum': 78.0,
        'sample_count': 2,
        'valid_seconds': 1,
      });
      expect(w.first.containsKey('hrv'), false);
      expect(w.last.containsKey('heart_rate'), false);
      expect(w.last['hrv'], {'mean': 23.0, 'maximum': 23.0, 'sample_count': 1});
      for (final slot in w) {
        expect(slot['exercise'], true);
        expect(slot['cadence']['mean'], 90.0);
        expect(slot['cadence']['valid_seconds'], 15);
      }
    },
  );

  test('steps starting before the collection boundary are ignored', () {
    final windows = healthWindows('apple_history', 30000, 60000, [
      ['steps', 0, 60000, 300],
    ]);
    expect(windows, isEmpty);
  });

  test(
    'steps beginning before the actual collection boundary are excluded whole',
    () {
      final windows = healthWindows('apple_history', 150000, 270000, [
        ['steps', 120000, 240000, 120],
      ], collectionFrom: 150000);
      expect(windows, isEmpty);
    },
  );

  test('workout overlapping a later read batch marks the heart window', () {
    final windows = healthWindows('apple_history', 720000, 750000, [
      ['exercise', 0, 1800000, 1],
      ['heart_rate', 720000, 720000, 68],
    ]);
    expect(windows.single['exercise'], true);
  });

  test(
    'all metric types stay aligned across a UTC date and read-batch boundary',
    () {
      final from = DateTime.utc(
        2026,
        11,
        21,
        23,
        59,
        30,
      ).millisecondsSinceEpoch;
      final boundary = from + slotMs;
      final to = boundary + slotMs;
      final rows = [
        ['heart_rate', from + 10000, from + 10000, 71],
        ['steps', from, to, 50],
        ['exercise', from + 20000, from + 40000, 1],
        ['hrv', boundary + 5000, boundary + 5000, 23],
      ];

      final combined = healthWindows(
        'huawei_history',
        from,
        to,
        rows,
        collectionFrom: from,
      );
      final firstBatch = healthWindows(
        'huawei_history',
        from,
        boundary,
        rows,
        collectionFrom: from,
      );
      final secondBatch = healthWindows(
        'huawei_history',
        boundary,
        to,
        rows,
        collectionFrom: from,
      );

      expect(combined.map((window) => window['starts_at']), [
        '2026-11-21T23:59:30.000Z',
        '2026-11-22T00:00:00.000Z',
      ]);
      expect(firstBatch.single, combined.first);
      expect(secondBatch.single, combined.last);
      expect(combined.first['heart_rate'], {
        'mean': 71.0,
        'maximum': 71.0,
        'sample_count': 1,
        'valid_seconds': 1,
      });
      expect(combined.first.containsKey('hrv'), false);
      expect(combined.last.containsKey('heart_rate'), false);
      expect(combined.last['hrv'], {
        'mean': 23.0,
        'maximum': 23.0,
        'sample_count': 1,
      });
      for (final window in combined) {
        expect(window['exercise'], true);
        expect(window['cadence'], {
          'mean': 50.0,
          'maximum': 50.0,
          'sample_count': 1,
          'valid_seconds': 30,
        });
      }
    },
  );

  const sources = ['apple_history', 'health_connect', 'huawei_history'];
  for (final source in sources) {
    for (final kind in ['steps', 'phone_steps']) {
      test('$source $kind', () {
        const from = 0;
        final row = [kind, 25000, 35000, 40];
        final first = healthWindows(source, from, from + 30000, [
          row,
        ], collectionFrom: from);
        final second = healthWindows(source, from + 30000, from + 60000, [
          row,
        ], collectionFrom: from);
        final single = healthWindows(source, from, from + 60000, [
          row,
        ], collectionFrom: from);

        expect(first.single['cadence']['sample_count'], 1);
        expect(second.single['cadence']['sample_count'], 1);
        expect(single, hasLength(2));
        expect(
          single.map((window) => window['cadence']['sample_count']),
          everyElement(1),
        );
        expect(first.single['cadence']['valid_seconds'], 5);
        expect(second.single['cadence']['valid_seconds'], 5);
        expect(single.map((window) => window['cadence']['valid_seconds']), [
          5,
          5,
        ]);
        expect(
          first.single['cadence']['mean'],
          single.first['cadence']['mean'],
        );
        expect(
          second.single['cadence']['mean'],
          single.last['cadence']['mean'],
        );
      });

      test('$source $kind starting before consent is excluded', () {
        final windows = healthWindows(source, 30000, 60000, [
          [kind, 25000, 35000, 10],
        ], collectionFrom: 30000);
        expect(windows, isEmpty);
      });
    }
  }
}
