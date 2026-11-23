import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// Keep this host replay runnable with the Dart SDK alone, before pub get.
// ignore: avoid_relative_lib_imports
import '../../lib/features/voice/aggregator.dart';
// ignore: avoid_relative_lib_imports
import '../../lib/features/voice/pcm_chunk.dart';

void main(List<String> args) {
  const base = 1800000000000000;
  final directory = args.single;
  var failures = 0;

  Uint8List? check(
    String name,
    List<int> expected, {
    Uint8List? alignedPcm,
    List<int>? expectedSegmentStarts,
    int? timestampGapUs,
  }) {
    final starts = <int>[];
    Uint8List? windowPcm;
    final aggregator = VoiceWindowAggregator(
      onWindow: (capture) {
        if (capture.pcm.length != 960000) {
          throw StateError('$name produced ${capture.pcm.length} PCM bytes');
        }
        if (name.startsWith('phase-')) {
          final signal = ByteData.sublistView(capture.pcm);
          for (
            var offset = 958400;
            offset < signal.lengthInBytes;
            offset += 2
          ) {
            if (signal.getInt16(offset, Endian.little) < 1000) {
              throw StateError(
                '$name produced a silent sample at ${offset ~/ 2}',
              );
            }
          }
        }
        windowPcm = capture.pcm;
        starts.add(capture.window.startsAt.microsecondsSinceEpoch - base);
      },
    );
    final segmentStarts = <int>[];
    int? segmentGapUs;
    int? previousEndUs;
    for (final line in File('$directory/$name').readAsLinesSync()) {
      final event = jsonDecode(line) as Map<String, dynamic>;
      event['pcm'] = base64Decode(event['pcm'] as String);
      final chunk = voicePcmChunkFromEvent(event);
      final startUs = chunk.capturedAt.microsecondsSinceEpoch;
      if (chunk.pcm.length != 1600) {
        throw StateError(
          '$name produced ${chunk.pcm.length} PCM bytes per frame',
        );
      }
      if (chunk.startsNewSegment) {
        segmentStarts.add(startUs - base);
        if (previousEndUs != null) segmentGapUs = startUs - previousEndUs;
      }
      previousEndUs = startUs + 50000;
      aggregator.add(
        chunk.pcm,
        chunk.capturedAt,
        retainAudio: false,
        startsNewSegment: chunk.startsNewSegment,
      );
    }
    final matchingBoundary = expectedSegmentStarts == null
        ? segmentStarts.isEmpty
        : segmentStarts.length == expectedSegmentStarts.length &&
              Iterable<int>.generate(
                segmentStarts.length,
              ).every((i) => segmentStarts[i] == expectedSegmentStarts[i]);
    if (!matchingBoundary ||
        (timestampGapUs != null && segmentGapUs != timestampGapUs)) {
      failures++;
      stderr.writeln(
        'FAIL $name: expected segments $expectedSegmentStarts and timestamp gap '
        '$timestampGapUs, got segments $segmentStarts and gap $segmentGapUs',
      );
    }
    final matching =
        starts.length == expected.length &&
        Iterable<int>.generate(
          starts.length,
        ).every((i) => starts[i] == expected[i]);
    if (!matching) failures++;
    if (matching && alignedPcm != null) {
      for (var i = 0; i < alignedPcm.length; i++) {
        if (windowPcm![i] != alignedPcm[i]) {
          throw StateError('$name changed aligned PCM at byte $i');
        }
      }
    }
    stdout.writeln(
      '${matching ? 'PASS' : 'FAIL'} $name: expected $expected, got $starts '
      '(${aggregator.bufferedSamples} samples pending before stop)',
    );
    final beforeStop = starts.length;
    aggregator.stop();
    if (starts.length != beforeStop) {
      throw StateError('$name emitted a window on stop');
    }
    return windowPcm;
  }

  Uint8List? reference16k;
  Uint8List? reference48k;
  for (final rate in [16000, 44100, 48000]) {
    final reference = check('phase-$rate-0-0', [0]);
    if (rate == 16000) reference16k = reference;
    if (rate == 48000) reference48k = reference;
    check('phase-$rate-0-1', []);
    for (final phase in [
      -20,
      -1,
      1,
      62,
      137,
      25000,
      49999,
      50001,
      63137,
      12345678,
    ]) {
      check(
        'phase-$rate-$phase-0',
        [0],
        alignedPcm: reference,
        expectedSegmentStarts: const {50001, 63137, 12345678}.contains(phase)
            ? const [0]
            : null,
      );
      check(
        'phase-$rate-$phase-1',
        [],
        expectedSegmentStarts: const {50001, 63137, 12345678}.contains(phase)
            ? const [0]
            : null,
      );
    }
    for (final jitter in [-900, 900]) {
      check('signed-$rate-$jitter-0', [0], alignedPcm: reference);
      check('signed-$rate-$jitter-1', []);
    }
    check(
      'signed-late-$rate',
      [30000000],
      alignedPcm: reference,
      expectedSegmentStarts: const [30000000],
    );
  }
  check('signed-disputed', [30000000], alignedPcm: reference16k);
  check('gap-0', [240000000, 270000000]);
  for (final gap in [-5000, 24999, 25000, 25001, 26000, 40000]) {
    check(
      'gap-$gap',
      [270000000],
      expectedSegmentStarts: gap == 25000
          ? [249975000 + gap]
          : [249975000 + gap, 270000000],
    );
  }
  check(
    'recovery-visible',
    [30000000],
    alignedPcm: reference48k,
    expectedSegmentStarts: const [30000000],
    timestampGapUs: 100000,
  );
  check(
    'recovery-utc',
    [0, 30000000],
    alignedPcm: reference48k,
    expectedSegmentStarts: const [30000000],
    timestampGapUs: 0,
  );
  check(
    'recovery-utc-one-short',
    [0],
    expectedSegmentStarts: const [30000000],
    timestampGapUs: 0,
  );
  final partialReference = check('recovery-partial-reference', [30000000]);
  check(
    'recovery-partial',
    [30000000],
    alignedPcm: partialReference,
    expectedSegmentStarts: const [15000000],
    timestampGapUs: 0,
  );
  if (failures != 0) exitCode = 1;
}
