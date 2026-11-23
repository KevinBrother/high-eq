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
///
/// Time contract: [add] receives the hardware-clock UTC time of the chunk's
/// first sample. Adjacent chunk endpoints may differ by at most 1 ms and remain
/// locally continuous. At segment start, adjacent timestamps are projected back
/// to sample zero to corroborate the clock phase. Once aligned, UTC cuts advance
/// by sample count. A discontinuity discards the affected partial window.
class VoiceWindowAggregator {
  static const windowWidth = Duration(seconds: 30);
  static const _continuityToleranceUs = 1000;
  static const _usPerSecond = Duration.microsecondsPerSecond;
  static const _windowUs = 30 * _usPerSecond;

  final void Function(VoiceWindowCapture capture) onWindow;
  final int sampleRate;
  final PcmAnalyzer analyzer;

  late final int _windowSamples = sampleRate * 30;
  final BytesBuilder _bytes = BytesBuilder(copy: true);
  final _anchors = <_VoicePcmAnchor>[];
  DateTime? _start;
  int? _nextChunkUs;
  int _anchorSamples = 0;
  int _leadingSamples = 0;
  int _sampleCount = 0;
  bool _retainCurrent = false;

  VoiceWindowAggregator({
    required this.onWindow,
    this.sampleRate = 16000,
    PcmAnalyzer? analyzer,
  }) : analyzer = analyzer ?? PcmAnalyzer(sampleRate: sampleRate);

  DateTime? get currentStart => _leadingSamples == 0 ? _start : null;
  int get bufferedSamples => _sampleCount;

  void add(
    Uint8List pcm,
    DateTime capturedAt, {
    required bool retainAudio,
    bool startsNewSegment = false,
  }) {
    if (pcm.length.isOdd) throw const FormatException('PCM must be 16-bit');
    if (pcm.isEmpty) return;

    final chunkUs = capturedAt.microsecondsSinceEpoch;
    final next = _nextChunkUs;
    if (startsNewSegment ||
        (next != null && (chunkUs - next).abs() > _continuityToleranceUs)) {
      // A reported capture boundary takes precedence over timestamp proximity.
      _discardPartial();
    }
    // Keep the next hardware-block estimate independent of UTC window cuts.
    final samples = pcm.length ~/ 2;
    _nextChunkUs = chunkUs + _durationUs(samples);

    if (_start == null) {
      final projectedUs = chunkUs - _durationUs(_anchorSamples);
      final agreedUs = _corroboratedOrigin(projectedUs);
      final firstOriginUs = _anchors.isEmpty
          ? projectedUs
          : _anchors.first.originUs;
      final phase = firstOriginUs % _windowUs;
      final distanceToBoundaryUs = math.min(phase, _windowUs - phase);
      final unresolvedBoundary =
          agreedUs == null &&
          _anchors.length == 2 &&
          distanceToBoundaryUs > 0 &&
          distanceToBoundaryUs <= _continuityToleranceUs;
      if (unresolvedBoundary) {
        // Restart observation at a new block when a disputed, off-grid phase
        // could put sample zero on either side of the UTC boundary.
        _anchors.clear();
        _anchorSamples = 0;
      }
      final singleBlockWindow =
          _anchors.isEmpty &&
          !unresolvedBoundary &&
          samples >= _windowSamples + _samplesUntilWindow(phase) &&
          (phase == 0 || distanceToBoundaryUs > _continuityToleranceUs);
      if (agreedUs == null && _anchors.length < 2 && !singleBlockWindow) {
        _anchors.add(
          _VoicePcmAnchor(
            unresolvedBoundary ? chunkUs : projectedUs,
            Uint8List.fromList(pcm),
            retainAudio,
          ),
        );
        _anchorSamples += samples;
        return;
      }

      // Without a stable pair, keep the first clock phase as the nominal
      // origin. Clock drift after startup still uses the adjacent gap check.
      final originUs = agreedUs ?? firstOriginUs;
      final originPhase = originUs % _windowUs;
      _leadingSamples = _samplesUntilWindow(originPhase);
      _start = DateTime.fromMicrosecondsSinceEpoch(
        originUs - originPhase + (_leadingSamples == 0 ? 0 : _windowUs),
        isUtc: true,
      );
      for (final anchor in _anchors) {
        _addSamples(anchor.pcm, anchor.retainAudio);
      }
      _anchors.clear();
      _anchorSamples = 0;
    }
    _addSamples(pcm, retainAudio);
  }

  int? _corroboratedOrigin(int projectedUs) {
    if (_anchors.any((anchor) => anchor.originUs == projectedUs)) {
      return projectedUs;
    }
    if (_anchors.length != 2) return null;

    // Prefer an exact pair before allowing a microsecond of clock rounding.
    final estimates = [
      for (final anchor in _anchors) anchor.originUs,
      projectedUs,
    ]..sort();
    if (estimates[1] - estimates[0] <= 1 || estimates[2] - estimates[1] <= 1) {
      return estimates[1];
    }
    return null;
  }

  void _addSamples(Uint8List pcm, bool retainAudio) {
    final skip = math.min(_leadingSamples, pcm.length ~/ 2);
    _leadingSamples -= skip;
    var offset = skip * 2;
    while (offset < pcm.length) {
      final available = (pcm.length - offset) ~/ 2;
      final take = math.min(available, _windowSamples - _sampleCount);
      _retainCurrent = _sampleCount == 0
          ? retainAudio
          : _retainCurrent && retainAudio;
      _bytes.add(Uint8List.sublistView(pcm, offset, offset + take * 2));
      offset += take * 2;
      _sampleCount += take;
      if (_sampleCount == _windowSamples) _emit();
    }
  }

  void setRetention(bool enabled) {
    if (!enabled) {
      _retainCurrent = false;
      for (final anchor in _anchors) {
        anchor.retainAudio = false;
      }
    }
  }

  void stop() {
    _discardPartial();
    _nextChunkUs = null;
  }

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
    _sampleCount = 0;
    _retainCurrent = false;
  }

  void _discardPartial() {
    _bytes.clear();
    _anchors.clear();
    _anchorSamples = 0;
    _leadingSamples = 0;
    _sampleCount = 0;
    _start = null;
    _retainCurrent = false;
  }

  int _durationUs(int samples) =>
      (samples * _usPerSecond + sampleRate ~/ 2) ~/ sampleRate;

  int _samplesUntilWindow(int phaseUs) {
    // The boundary falls between sample positions. Accept sample zero when
    // it is the first sample of that window's lattice.
    if (phaseUs * sampleRate < _usPerSecond) return 0;
    return ((_windowUs - phaseUs) * sampleRate + _usPerSecond - 1) ~/
        _usPerSecond;
  }
}

class _VoicePcmAnchor {
  final int originUs;
  final Uint8List pcm;
  bool retainAudio;

  _VoicePcmAnchor(this.originUs, this.pcm, this.retainAudio);
}
