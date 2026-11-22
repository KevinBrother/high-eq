import 'dart:math' as math;
import 'dart:typed_data';

import 'features.dart';

class VoiceWindowCapture {
  final VoiceWindow window;
  final Uint8List pcm;
  final bool retained;

  const VoiceWindowCapture({
    required this.window,
    required this.pcm,
    required this.retained,
  });
}

/// Buffers complete UTC-aligned 30-second windows. A capture that starts in the
/// middle of a window discards its leading fragment; partial windows are never
/// emitted or uploaded.
class VoiceWindowAggregator {
  static const windowWidth = Duration(seconds: 30);
  static const _alignmentTolerance = Duration(milliseconds: 20);
  static const _continuityTolerance = Duration(milliseconds: 20);

  final void Function(VoiceWindowCapture capture) onWindow;
  final int sampleRate;
  final PcmAnalyzer analyzer;

  late final int _windowSamples = sampleRate * 30;
  final BytesBuilder _bytes = BytesBuilder(copy: true);
  DateTime? _start;
  DateTime? _nextSampleAt;
  int _sampleCount = 0;
  bool _retainCurrent = false;

  VoiceWindowAggregator({
    required this.onWindow,
    this.sampleRate = 16000,
    PcmAnalyzer? analyzer,
  }) : analyzer = analyzer ?? PcmAnalyzer(sampleRate: sampleRate);

  DateTime? get currentStart => _start;
  int get bufferedSamples => _sampleCount;

  void add(Uint8List pcm, DateTime capturedAt, {required bool retainAudio}) {
    if (pcm.length.isOdd) throw const FormatException('PCM must be 16-bit');
    if (pcm.isEmpty) return;

    final chunkStart = capturedAt.toUtc();
    final next = _nextSampleAt;
    if (_start != null &&
        next != null &&
        chunkStart.difference(next).abs() > _continuityTolerance) {
      // A missing or overlapping chunk must never be hidden by appending the
      // next samples as if the audio were continuous.
      _discardPartial();
    }

    var offset = 0;
    while (offset < pcm.length) {
      final at = _timeAt(chunkStart, offset);
      final bucket = _floorWindow(at);
      final offsetInBucket = at.difference(bucket);
      if (_start == null) {
        final nearBoundary = offsetInBucket <= _alignmentTolerance;
        final aligned = nearBoundary ? bucket : bucket.add(windowWidth);
        final skipSamples = math.max(
          0,
          ((aligned.difference(at).inMicroseconds * sampleRate) / 1000000)
              .ceil(),
        );
        final available = (pcm.length - offset) ~/ 2;
        if (skipSamples >= available) return;
        offset += skipSamples * 2;
        _start = aligned;
        _nextSampleAt = _timeAt(chunkStart, offset);
        _retainCurrent = retainAudio;
        continue;
      }

      if (bucket.isAfter(_start!)) {
        _discardPartial();
        continue;
      }
      if (bucket.isBefore(_start!)) return;

      final available = (pcm.length - offset) ~/ 2;
      final take = math.min(available, _windowSamples - _sampleCount);
      if (take <= 0) {
        _emit();
        continue;
      }
      _retainCurrent = _sampleCount == 0
          ? retainAudio
          : _retainCurrent && retainAudio;
      _bytes.add(Uint8List.sublistView(pcm, offset, offset + take * 2));
      offset += take * 2;
      _sampleCount += take;
      _nextSampleAt = _timeAt(chunkStart, offset);
      if (_sampleCount == _windowSamples) _emit();
    }
  }

  void setRetention(bool enabled) {
    if (!enabled) _retainCurrent = false;
  }

  void stop() => _discardPartial();

  void _emit() {
    final start = _start;
    if (start == null) return;
    final pcm = _bytes.takeBytes();
    final analysis = analyzer.analyze(pcm);
    onWindow(
      VoiceWindowCapture(
        window: VoiceWindow(startsAt: start, analysis: analysis),
        pcm: pcm,
        retained: _retainCurrent,
      ),
    );
    _start = start.add(windowWidth);
    _nextSampleAt = _start;
    _sampleCount = 0;
    _retainCurrent = false;
  }

  void _discardPartial() {
    _bytes.clear();
    _sampleCount = 0;
    _start = null;
    _nextSampleAt = null;
    _retainCurrent = false;
  }

  DateTime _timeAt(DateTime start, int byteOffset) {
    final samples = byteOffset ~/ 2;
    return start.add(
      Duration(microseconds: (samples * 1000000 / sampleRate).round()),
    );
  }

  DateTime _floorWindow(DateTime time) {
    final millis = time.millisecondsSinceEpoch;
    const width = 30000;
    final floored = millis - millis % width;
    return DateTime.fromMillisecondsSinceEpoch(floored, isUtc: true);
  }
}
