import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// Keep this host replay runnable with the Dart SDK alone, before pub get.
// ignore: avoid_relative_lib_imports
import '../../lib/features/voice/aggregator.dart';
// ignore: avoid_relative_lib_imports
import '../../lib/features/voice/pcm_chunk.dart';

const _epoch = 1800000000000000;
const _boundary = 30000000;

class _Replay {
  final List<VoiceWindowCapture> windows;
  final Uint8List nativeFromBoundary;
  final List<int> segmentStarts;
  final int? frameGapUs;

  const _Replay(
    this.windows,
    this.nativeFromBoundary,
    this.segmentStarts,
    this.frameGapUs,
  );
}

_Replay _replay(String path) {
  final windows = <VoiceWindowCapture>[];
  final native = BytesBuilder(copy: false);
  final times = <int>[];
  final segmentStarts = <int>[];
  final aggregator = VoiceWindowAggregator(onWindow: windows.add);

  for (final line in File(path).readAsLinesSync()) {
    final event = jsonDecode(line) as Map<String, dynamic>;
    event['pcm'] = base64Decode(event['pcm'] as String);
    final chunk = voicePcmChunkFromEvent(event);
    final us = chunk.capturedAt.microsecondsSinceEpoch - _epoch;
    times.add(us);
    if (us >= _boundary) native.add(chunk.pcm);
    if (chunk.startsNewSegment) segmentStarts.add(us);
    aggregator.add(
      chunk.pcm,
      chunk.capturedAt,
      retainAudio: false,
      startsNewSegment: chunk.startsNewSegment,
    );
  }
  aggregator.stop();

  final boundaryIndex = times.indexOf(_boundary);
  final gap = boundaryIndex > 0
      ? times[boundaryIndex] - (times[boundaryIndex - 1] + 50000)
      : null;
  return _Replay(windows, native.takeBytes(), segmentStarts, gap);
}

List<int> _windowStarts(List<VoiceWindowCapture> windows) => [
  for (final capture in windows)
    capture.window.startsAt.microsecondsSinceEpoch - _epoch,
];

int _mismatches(Uint8List left, Uint8List right) {
  if (left.length != right.length) return -1;
  final a = ByteData.sublistView(left);
  final b = ByteData.sublistView(right);
  var wrong = 0;
  for (var offset = 0; offset < left.length; offset += 2) {
    if (a.getInt16(offset, Endian.little) !=
        b.getInt16(offset, Endian.little)) {
      wrong++;
    }
  }
  return wrong;
}

bool _checkCase(
  String label,
  _Replay short,
  _Replay full,
  _Replay extra,
  _Replay reference, {
  required bool expectsMarker,
}) {
  final errors = <String>[];
  final expectedMarkers = expectsMarker ? <int>[_boundary] : <int>[];

  if (reference.windows.length != 1 ||
      _windowStarts(reference.windows).single != _boundary) {
    errors.add('reference windows=${_windowStarts(reference.windows)}');
  }
  if (reference.segmentStarts.isNotEmpty) {
    errors.add('reference markers=${reference.segmentStarts}');
  }
  if (short.windows.isNotEmpty) {
    errors.add('one-short windows=${_windowStarts(short.windows)}');
  }
  if (short.segmentStarts.join(',') != expectedMarkers.join(',')) {
    errors.add(
      'one-short markers=${short.segmentStarts}, expected=$expectedMarkers',
    );
  }
  if (_windowStarts(full.windows).join(',') != '$_boundary') {
    errors.add('full windows=${_windowStarts(full.windows)}');
  }
  if (full.segmentStarts.join(',') != expectedMarkers.join(',')) {
    errors.add('full markers=${full.segmentStarts}, expected=$expectedMarkers');
  }
  final nativeDifferences = _mismatches(
    reference.nativeFromBoundary,
    full.nativeFromBoundary,
  );
  if (nativeDifferences != 0) {
    errors.add('full native PCM differences=$nativeDifferences');
  }
  if (full.windows.length == 1 && reference.windows.length == 1) {
    final windowDifferences = _mismatches(
      reference.windows.single.pcm,
      full.windows.single.pcm,
    );
    if (windowDifferences != 0) {
      errors.add('full window PCM differences=$windowDifferences');
    }
  }
  if (_windowStarts(extra.windows).join(',') != '$_boundary') {
    errors.add('extra windows=${_windowStarts(extra.windows)}');
  }
  if (extra.segmentStarts.join(',') != expectedMarkers.join(',')) {
    errors.add(
      'extra markers=${extra.segmentStarts}, expected=$expectedMarkers',
    );
  }
  if (extra.windows.length == 1 && reference.windows.length == 1) {
    final extraDifferences = _mismatches(
      reference.windows.single.pcm,
      extra.windows.single.pcm,
    );
    if (extraDifferences != 0) {
      errors.add('extra window PCM differences=$extraDifferences');
    }
  }

  final ok = errors.isEmpty;
  stdout.writeln(
    '${ok ? 'PASS' : 'FAIL'} $label; gap=${full.frameGapUs}us; '
    'windows=${_windowStarts(full.windows)}; markers=${full.segmentStarts}; '
    '${errors.join('; ')}',
  );
  return ok;
}

void main(List<String> args) {
  final directory = args.single;
  final phases = [48900, 49000, 49500, 50500, 99500, 50000];
  var failures = 0;

  for (final rate in [16000, 44100, 48000]) {
    for (final phase in phases) {
      final reference = _replay('$directory/cut-$rate-$phase-reference.jsonl');
      final jitters = phase == 49500 ? [-900, 0, 900] : [0];
      for (final jitter in jitters) {
        final base = '$directory/cut-$rate-$phase-j$jitter';
        final short = _replay('$base-short.jsonl');
        final full = _replay('$base-full.jsonl');
        final extra = _replay('$base-extra.jsonl');
        if (!_checkCase(
          '$rate Hz phase=${phase}us jitter=${jitter}us',
          short,
          full,
          extra,
          reference,
          expectsMarker: phase != 50000,
        )) {
          failures++;
        }
      }
    }
  }
  if (failures != 0) {
    stderr.writeln('FAIL iOS UTC cut replay: $failures case(s)');
    exitCode = 1;
  }
}
