import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/features/emotion/progress.dart';

void main() {
  test('legacy rate is ignored while acoustic volume and pitch count', () {
    final now = DateTime.utc(2026, 11, 22);
    const stat = {'mean': 4, 'sample_count': 2, 'valid_seconds': 2};
    final windows = [
      for (final (offset, unit) in [(0, null), (30, 'characters_per_second')])
        <String, dynamic>{
          'starts_at': now.add(Duration(seconds: offset)).toIso8601String(),
          'channel': 'voice',
          'duration_seconds': 30,
          'speech_rate': stat,
          'speech_rate_unit': ?unit,
          'volume': stat,
          'pitch': stat,
        },
    ];
    final result = SignalProgress.fromWindows(
      now: now,
      zone: 'UTC',
      windows: windows,
    );

    expect(result.speechRate.todayValidSeconds, 2);
    expect(result.volume.todayValidSeconds, 4);
    expect(result.pitch.todayValidSeconds, 4);
  });

  test('Dart progress engine passes every real T30 progress vector', () {
    final file = File('../server/internal/emotion/testdata/progress.json');
    final rows = (jsonDecode(file.readAsStringSync()) as List)
        .cast<Map<String, dynamic>>();
    expect(rows, hasLength(3));
    for (final row in rows) {
      final actual = SignalProgress.fromWindows(
        now: DateTime.parse(row['now'] as String),
        zone: row['zone'] as String,
        windows: (row['windows'] as List).cast<Map<String, dynamic>>(),
      );
      final want = row['want'] as Map<String, dynamic>;
      for (final signal in const [
        'heart_rate',
        'speech_rate',
        'volume',
        'pitch',
      ]) {
        final expected = want[signal] as Map<String, dynamic>;
        expect(
          actual.forSignal(signal).todayValidSeconds,
          expected['today_valid_seconds'],
          reason: '${row['name']} $signal',
        );
      }
      final hrv = want['hrv'] as Map<String, dynamic>;
      expect(
        actual.hrv.readings,
        hrv['readings'],
        reason: row['name'] as String,
      );
      expect(
        actual.hrv.samplingDays,
        hrv['sampling_days'],
        reason: row['name'] as String,
      );
      expect(actual.hrv.readyForAlert, isFalse, reason: row['name'] as String);
    }
  });
}
