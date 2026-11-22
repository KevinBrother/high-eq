import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/features/voice/aggregator.dart';
import 'synthetic.dart';

void main() {
  test('aligns capture to UTC 30 second windows and carries overflow', () {
    final windows = <VoiceWindowCapture>[];
    final aggregator = VoiceWindowAggregator(onWindow: windows.add);
    final pcm = tone(duration: const Duration(seconds: 31), syllableHz: 4);
    final split = 16000 * 2 * 20;

    aggregator.add(
      Uint8List.sublistView(pcm, 0, split),
      DateTime.utc(2026, 11, 21, 9, 0),
      retainAudio: true,
    );
    expect(windows, isEmpty);
    aggregator.add(
      Uint8List.sublistView(pcm, split),
      DateTime.utc(2026, 11, 21, 9, 0, 20),
      retainAudio: true,
    );

    expect(windows, hasLength(1));
    expect(windows.single.window.startsAt, DateTime.utc(2026, 11, 21, 9, 0));
    expect(windows.single.window.analysis.voicedSeconds, greaterThan(20));
    expect(windows.single.pcm.length, 16000 * 2 * 30);
    expect(windows.single.retained, isTrue);

    aggregator.stop();
  });

  test('drops leading fragments and starts at the next UTC boundary', () {
    final windows = <VoiceWindowCapture>[];
    final aggregator = VoiceWindowAggregator(onWindow: windows.add);
    final pcm = tone(duration: const Duration(seconds: 43), syllableHz: 4);
    final split = 16000 * 2 * 20;

    aggregator.add(
      Uint8List.sublistView(pcm, 0, split),
      DateTime.utc(2026, 11, 21, 9, 0, 17),
      retainAudio: false,
    );
    aggregator.add(
      Uint8List.sublistView(pcm, split),
      DateTime.utc(2026, 11, 21, 9, 0, 37),
      retainAudio: false,
    );

    expect(windows, hasLength(1));
    expect(
      windows.single.window.startsAt,
      DateTime.utc(2026, 11, 21, 9, 0, 30),
    );
    aggregator.stop();
  });

  test(
    'drops an incomplete window instead of uploading a false 30 seconds',
    () {
      final windows = <VoiceWindowCapture>[];
      final aggregator = VoiceWindowAggregator(onWindow: windows.add);
      aggregator.add(
        tone(duration: const Duration(seconds: 12)),
        DateTime.utc(2026, 11, 21, 9, 0, 0),
        retainAudio: false,
      );
      aggregator.stop();
      expect(windows, isEmpty);
    },
  );

  test('retention disabled during a window excludes that whole window', () {
    final windows = <VoiceWindowCapture>[];
    final aggregator = VoiceWindowAggregator(onWindow: windows.add);
    final pcm = tone(duration: const Duration(seconds: 30));
    final split = 16000 * 2 * 10;
    aggregator.add(
      Uint8List.sublistView(pcm, 0, split),
      DateTime.utc(2026, 11, 21, 9, 0, 0),
      retainAudio: true,
    );
    aggregator.setRetention(false);
    aggregator.add(
      Uint8List.sublistView(pcm, split),
      DateTime.utc(2026, 11, 21, 9, 0, 10),
      retainAudio: false,
    );
    expect(windows.single.retained, isFalse);
  });
  test('a sampling gap discards the partial window instead of splicing it', () {
    final windows = <VoiceWindowCapture>[];
    final aggregator = VoiceWindowAggregator(onWindow: windows.add);
    aggregator.add(
      tone(duration: const Duration(seconds: 20), syllableHz: 4),
      DateTime.utc(2026, 11, 21, 9, 0),
      retainAudio: false,
    );
    aggregator.add(
      tone(duration: const Duration(seconds: 10), syllableHz: 4),
      DateTime.utc(2026, 11, 21, 9, 0, 20, 100),
      retainAudio: false,
    );
    aggregator.stop();

    expect(windows, isEmpty);
  });
}
