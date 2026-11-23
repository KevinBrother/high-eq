import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/features/voice/features.dart';
import 'synthetic.dart';

void main() {
  const analyzer = PcmAnalyzer();

  test(
    'synthetic 220 Hz PCM yields local volume, pitch and syllable proxy',
    () {
      final result = analyzer.analyze(
        tone(
          duration: const Duration(seconds: 10),
          frequency: 220,
          amplitude: 8000,
          syllableHz: 4,
        ),
      );

      expect(result.voicedSeconds, inInclusiveRange(8, 10));
      expect(result.volume, isNotNull);
      expect(result.volume!.mean, inInclusiveRange(-30, -18));
      expect(result.volume!.maximum, greaterThanOrEqualTo(result.volume!.mean));
      expect(result.pitch, isNotNull);
      expect(result.pitch!.mean, closeTo(220, 8));
      expect(result.speechRate, isNotNull);
      expect(result.speechRate!.mean, inInclusiveRange(160, 320));
      expect(result.speechRate!.validSeconds, result.voicedSeconds);
    },
  );

  test(
    'sparse short utterance keeps feature seconds within voiced seconds',
    () {
      final pcm = Uint8List(16000 * 2 * 30);
      final utterance = tone(
        duration: const Duration(seconds: 1),
        frequency: 220,
        amplitude: 8000,
        syllableHz: 4,
      );
      pcm.setRange(16000, 16000 + utterance.length, utterance);

      final result = analyzer.analyze(pcm);

      expect(result.voicedSeconds, 1);
      for (final stat in [result.speechRate, result.volume, result.pitch]) {
        if (stat != null) {
          expect(stat.validSeconds, lessThanOrEqualTo(result.voicedSeconds));
        }
      }
    },
  );

  test('pure synthetic silence never counts as voiced or emits features', () {
    final result = analyzer.analyze(
      silence(duration: const Duration(seconds: 30)),
    );

    expect(result.voicedSeconds, 0);
    expect(result.volume, isNull);
    expect(result.pitch, isNull);
    expect(result.speechRate, isNull);
  });

  test('transcription is explicitly unavailable and never cloud-backed', () {
    final result = analyzer.analyze(
      tone(duration: const Duration(seconds: 1), syllableHz: 4),
    );

    expect(result.transcriptionStatus, TranscriptionStatus.unavailable);
    expect(result.transcript, isNull);
    expect(result.requiresCloudTranscription, isFalse);
  });

  test('window wire body is a strict statistics whitelist', () {
    final analysis = analyzer.analyze(
      tone(duration: const Duration(seconds: 30), syllableHz: 4),
    );
    final wire = VoiceWindow(
      startsAt: DateTime.utc(2026, 11, 21, 1, 0),
      analysis: analysis,
    ).toWire();

    expect(wire.keys, {
      'channel',
      'starts_at',
      'duration_seconds',
      'exercise',
      'voiced_seconds',
      'volume',
      'pitch',
    });
    expect(wire['channel'], 'voice');
    expect(wire['starts_at'], '2026-11-21T01:00:00.000Z');
    expect(wire['duration_seconds'], 30);
    expect(analysis.speechRate, isNotNull);
    expect(wire.containsKey('speech_rate'), isFalse);
    expect(wire.containsKey('speech_rate_unit'), isFalse);
    expect(wire['volume'], isNotNull);
    expect(wire['pitch'], isNotNull);
    expect(wire.toString(), isNot(contains('pcm')));
    expect(wire.toString(), isNot(contains('transcript')));
  });

  test('legacy queued acoustic proxy is removed at the upload boundary', () {
    final legacy = VoiceWindow.fromWire({
      'channel': 'voice',
      'starts_at': '2026-11-21T01:00:00.000Z',
      'duration_seconds': 30,
      'exercise': false,
      'voiced_seconds': 18,
      'speech_rate': {
        'mean': 238,
        'maximum': 270,
        'sample_count': 18,
        'valid_seconds': 18,
      },
      'volume': {
        'mean': -31,
        'maximum': -20,
        'sample_count': 18,
        'valid_seconds': 18,
      },
      'pitch': {
        'mean': 220,
        'maximum': 240,
        'sample_count': 18,
        'valid_seconds': 18,
      },
    });

    final wire = legacy.toWire();

    expect(legacy.analysis.speechRate?.mean, 238);
    expect(wire.containsKey('speech_rate'), isFalse);
    expect(wire.containsKey('speech_rate_unit'), isFalse);
    expect(wire['volume'], isNotNull);
    expect(wire['pitch'], isNotNull);
  });
}
