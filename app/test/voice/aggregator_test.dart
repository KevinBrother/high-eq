import 'dart:math' as math;
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
  test(
    'a 5 ms sampling gap discards the partial window instead of splicing it',
    () {
      final windows = <VoiceWindowCapture>[];
      final aggregator = VoiceWindowAggregator(onWindow: windows.add);
      aggregator.add(
        tone(duration: const Duration(seconds: 20), syllableHz: 4),
        DateTime.utc(2026, 11, 21, 9, 0),
        retainAudio: false,
      );
      aggregator.add(
        tone(duration: const Duration(seconds: 10), syllableHz: 4),
        DateTime.utc(2026, 11, 21, 9, 0, 20, 5),
        retainAudio: false,
      );
      aggregator.stop();

      expect(windows, isEmpty);
    },
  );
  test('continuous BOOTTIME jitter across a boundary keeps full windows', () {
    final windows = <VoiceWindowCapture>[];
    final aggregator = VoiceWindowAggregator(onWindow: windows.add);

    _feedBoottime(
      aggregator,
      blocks: 900,
      startOffsetUs: (block) => block == 300 ? 1030 : 50,
    );

    expect(windows.map((capture) => capture.window.startsAt), [
      _boottimeAt(0),
      _boottimeAt(30),
      _boottimeAt(60),
    ]);
    expect(
      windows.map((capture) => capture.pcm.length),
      everyElement(16000 * 2 * 30),
    );
    aggregator.stop();
  });
  test(
    'continuous BOOTTIME drift beyond 1 ms across a window keeps full windows',
    () {
      final windows = <VoiceWindowCapture>[];
      final aggregator = VoiceWindowAggregator(onWindow: windows.add);

      _feedBoottime(
        aggregator,
        blocks: 900,
        startOffsetUs: (block) => math.min(block, 300) * 4,
      );

      expect(windows.map((capture) => capture.window.startsAt), [
        _boottimeAt(0),
        _boottimeAt(30),
        _boottimeAt(60),
      ]);
      aggregator.stop();
    },
  );
  test('a non-aligned first chunk keeps later windows on the UTC grid', () {
    final windows = <VoiceWindowCapture>[];
    final aggregator = VoiceWindowAggregator(onWindow: windows.add);

    _feedBoottime(aggregator, blocks: 1100, startOffsetUs: (_) => 17000000);

    expect(windows.map((capture) => capture.window.startsAt), [
      _boottimeAt(30),
      _boottimeAt(60),
      _boottimeAt(90),
    ]);
    aggregator.stop();
  });
  test(
    'a 900 us boundary timestamp jitter keeps the first full UTC window',
    () {
      final windows = <VoiceWindowCapture>[];
      final aggregator = VoiceWindowAggregator(onWindow: windows.add);

      _feedBoottime(
        aggregator,
        firstBlock: -1,
        blocks: 301,
        startOffsetUs: (block) => block == 0 ? 900 : 0,
        firstSample: (block) => block,
      );

      expect(windows, hasLength(1));
      final capture = windows.single;
      expect(capture.window.startsAt, _boottimeAt(0));
      expect(capture.pcm.length, 16000 * 2 * 30);
      final samples = ByteData.sublistView(capture.pcm);
      expect(samples.getInt16(0, Endian.little), 0);
      expect(samples.getInt16(299 * 1600 * 2, Endian.little), 299);
      aggregator.stop();
    },
  );
  for (final rate in [16000, 44100, 48000]) {
    test('$rate Hz cuts the UTC window at the numbered sample', () {
      for (final originUs in [
        -100000,
        -50137,
        -900,
        0,
        250,
        900,
        1100,
        25137,
      ]) {
        for (final sizes in [
          [rate ~/ 10],
          [rate ~/ 400, rate ~/ 16, 333],
        ]) {
          for (final jitterUs in [-900, -1, 0, 1, 900]) {
            for (final jitterBlock in [0, 1]) {
              if (jitterUs == 0 && jitterBlock != 0) continue;
              final label =
                  '$originUs µs, $sizes, $jitterUs µs at $jitterBlock';
              final windows = <VoiceWindowCapture>[];
              final aggregator = VoiceWindowAggregator(
                sampleRate: rate,
                onWindow: windows.add,
              );
              final first = _sampleCut(-originUs, rate);
              final end = _sampleCut(30000000 - originUs, rate);
              final pcm = _numberedPcm(end + rate ~/ 10);
              var offset = 0;
              var block = 0;
              void feedUntil(int limit) {
                while (offset < limit) {
                  final end = math.min(
                    limit,
                    offset + sizes[block % sizes.length],
                  );
                  final timestamp =
                      originUs +
                      (offset * 1000000 / rate).round() +
                      (block == jitterBlock ? jitterUs : 0);
                  aggregator.add(
                    Uint8List.sublistView(pcm, offset * 2, end * 2),
                    DateTime.fromMicrosecondsSinceEpoch(
                      _boottimeEpochUs + timestamp,
                      isUtc: true,
                    ),
                    retainAudio: false,
                  );
                  offset = end;
                  block++;
                }
              }

              feedUntil(end - 1);
              expect(windows, isEmpty, reason: '$label, one sample short');
              feedUntil(end);
              if (originUs > 0) {
                expect(windows, isEmpty, reason: '$label, late start');
              } else {
                expect(windows, hasLength(1), reason: label);
                expect(
                  windows.single.window.startsAt,
                  _boottimeAt(0),
                  reason: label,
                );
                _expectSameSamples(windows.single.pcm, pcm, first, label);
              }
              feedUntil(end + rate ~/ 10);
              aggregator.stop();
              expect(windows, hasLength(originUs > 0 ? 0 : 1), reason: label);
            }
          }
        }
      }
    });
  }
  test(
    'disputed startup anchors close to UTC leave that window incomplete',
    () {
      final windows = <VoiceWindowCapture>[];
      final aggregator = VoiceWindowAggregator(onWindow: windows.add);
      const samplesPerBlock = 1600;
      final pcm = _numberedPcm(60 * 16000);
      const startupJitter = [-900, 30, 500];
      for (var block = 0; block < 600; block++) {
        final offset = block * samplesPerBlock * 2;
        final jitter = block < startupJitter.length ? startupJitter[block] : 0;
        aggregator.add(
          Uint8List.sublistView(pcm, offset, offset + samplesPerBlock * 2),
          _boottimeAt(0).add(Duration(microseconds: block * 100000 + jitter)),
          retainAudio: false,
        );
        if (block == 299) expect(windows, isEmpty);
      }
      expect(windows.single.window.startsAt, _boottimeAt(30));
      _expectSameSamples(
        windows.single.pcm,
        pcm,
        480000,
        'after phase settles',
      );
    },
  );
  test(
    'a 5 ms sampling interruption drops the affected window and recovers',
    () {
      final windows = <VoiceWindowCapture>[];
      final aggregator = VoiceWindowAggregator(onWindow: windows.add);

      _feedBoottime(
        aggregator,
        blocks: 900,
        startOffsetUs: (block) => block >= 200 ? 5000 : 0,
      );

      expect(windows.map((capture) => capture.window.startsAt), [
        _boottimeAt(30),
        _boottimeAt(60),
      ]);
      aggregator.stop();
    },
  );
  test(
    'a 5 ms sampling overlap needs five real ms to finish the recovered window',
    () {
      final windows = <VoiceWindowCapture>[];
      final aggregator = VoiceWindowAggregator(onWindow: windows.add);

      _feedBoottime(
        aggregator,
        blocks: 900,
        startOffsetUs: (block) => block >= 200 ? -5000 : 0,
      );

      // The overlap discards [0, 30). At 89.995 s the next window still lacks
      // 80 real samples; it must not be fabricated from timestamps or zeros.
      expect(windows.map((capture) => capture.window.startsAt), [
        _boottimeAt(30),
      ]);
      expect(aggregator.bufferedSamples, 480000 - 80);

      const tailSamples = 80;
      final tail = Uint8List(tailSamples * 2);
      for (var sample = 0; sample < tailSamples; sample++) {
        ByteData.sublistView(tail).setInt16(sample * 2, 1, Endian.little);
      }
      aggregator.add(
        tail,
        _boottimeAt(90).subtract(const Duration(milliseconds: 5)),
        retainAudio: false,
      );

      expect(windows.map((capture) => capture.window.startsAt), [
        _boottimeAt(30),
        _boottimeAt(60),
      ]);
      expect(aggregator.bufferedSamples, 0);
      expect(
        ByteData.sublistView(
          windows.last.pcm,
        ).getInt16(windows.last.pcm.length - 2, Endian.little),
        1,
      );
      aggregator.stop();
    },
  );
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

const _boottimeEpochUs = 1800000000000000;

int _sampleCut(int relativeUs, int rate) =>
    (relativeUs * rate / 1000000).ceil();

Uint8List _numberedPcm(int count) {
  // Four consecutive words encode a unique group number in this fixture.
  // Keep them below the voice detector's energy threshold.
  final pcm = ByteData(count * 2);
  for (var sample = 0; sample < count; sample++) {
    final digit = (sample ~/ 4) >> ((sample % 4) * 5) & 31;
    pcm.setInt16(sample * 2, digit + (sample % 4) * 32 - 64, Endian.little);
  }
  return pcm.buffer.asUint8List();
}

void _expectSameSamples(
  Uint8List actual,
  Uint8List source,
  int first,
  String label,
) {
  final observed = ByteData.sublistView(actual);
  final expected = ByteData.sublistView(source, first * 2);
  for (var byte = 0; byte < actual.length; byte += 2) {
    final sample = observed.getInt16(byte, Endian.little);
    if (sample != expected.getInt16(byte, Endian.little)) {
      fail('$label: incorrect PCM at window sample ${byte ~/ 2}');
    }
  }
}

DateTime _boottimeAt(int seconds) => DateTime.fromMicrosecondsSinceEpoch(
  _boottimeEpochUs + seconds * Duration.microsecondsPerSecond,
  isUtc: true,
);

void _feedBoottime(
  VoiceWindowAggregator aggregator, {
  int firstBlock = 0,
  required int blocks,
  required int Function(int block) startOffsetUs,
  int Function(int block)? firstSample,
}) {
  const blockSamples = 16000 ~/ 10;
  for (var block = firstBlock; block < firstBlock + blocks; block++) {
    final pcm = Uint8List(blockSamples * 2);
    if (firstSample != null) {
      ByteData.sublistView(pcm).setInt16(0, firstSample(block), Endian.little);
    }
    final startUs = block * 100000 + startOffsetUs(block);
    aggregator.add(
      pcm,
      DateTime.fromMicrosecondsSinceEpoch(
        _boottimeEpochUs + startUs,
        isUtc: true,
      ),
      retainAudio: false,
    );
  }
}
