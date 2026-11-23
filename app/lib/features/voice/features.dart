import 'dart:math' as math;
import 'dart:typed_data';

enum TranscriptionStatus { unavailable }

class VoiceStat {
  final double mean;
  final double maximum;
  final int sampleCount;
  final int validSeconds;

  const VoiceStat({
    required this.mean,
    required this.maximum,
    required this.sampleCount,
    required this.validSeconds,
  });

  Map<String, dynamic> toWire() => {
    'mean': mean,
    'maximum': maximum,
    'sample_count': sampleCount,
    'valid_seconds': validSeconds,
  };

  factory VoiceStat.fromWire(Map<String, dynamic> json) => VoiceStat(
    mean: (json['mean'] as num).toDouble(),
    maximum: (json['maximum'] as num).toDouble(),
    sampleCount: json['sample_count'] as int,
    validSeconds: json['valid_seconds'] as int,
  );
}

class VoiceAnalysis {
  final int voicedSeconds;
  final VoiceStat? speechRate;
  final VoiceStat? volume;
  final VoiceStat? pitch;

  const VoiceAnalysis({
    required this.voicedSeconds,
    this.speechRate,
    this.volume,
    this.pitch,
  });

  TranscriptionStatus get transcriptionStatus =>
      TranscriptionStatus.unavailable;
  String? get transcript => null;
  bool get requiresCloudTranscription => false;

  factory VoiceAnalysis.fromWire(Map<String, dynamic> json) => VoiceAnalysis(
    voicedSeconds: json['voiced_seconds'] as int,
    speechRate: json['speech_rate'] == null
        ? null
        : VoiceStat.fromWire(json['speech_rate'] as Map<String, dynamic>),
    volume: json['volume'] == null
        ? null
        : VoiceStat.fromWire(json['volume'] as Map<String, dynamic>),
    pitch: json['pitch'] == null
        ? null
        : VoiceStat.fromWire(json['pitch'] as Map<String, dynamic>),
  );
}

class VoiceWindow {
  final DateTime startsAt;
  final VoiceAnalysis analysis;

  const VoiceWindow({required this.startsAt, required this.analysis});

  Map<String, dynamic> toWire() => {
    'channel': 'voice',
    'starts_at': startsAt.toUtc().toIso8601String(),
    'duration_seconds': 30,
    'exercise': false,
    'voiced_seconds': analysis.voicedSeconds,
    if (analysis.volume != null) 'volume': analysis.volume!.toWire(),
    if (analysis.pitch != null) 'pitch': analysis.pitch!.toWire(),
  };

  factory VoiceWindow.fromWire(Map<String, dynamic> json) {
    if (json['channel'] != 'voice' ||
        json['duration_seconds'] != 30 ||
        json['exercise'] != false ||
        json['voiced_seconds'] is! int) {
      throw const FormatException('invalid voice window');
    }
    final startsAt = DateTime.tryParse(json['starts_at'] as String? ?? '');
    if (startsAt == null) throw const FormatException('invalid starts_at');
    return VoiceWindow(
      startsAt: startsAt.toUtc(),
      analysis: VoiceAnalysis.fromWire(json),
    );
  }
}

/// Local DSP over 16-bit little-endian mono PCM.
///
/// The analyzer derives one-second volume, pitch and acoustic syllable-peak
/// samples, then reduces them to one 30-second wire object. Per-second samples
/// are never returned or persisted. `speech_rate` is an acoustic
/// syllable-peak proxy, not a transcript-derived character rate. No offline
/// recognizer is bundled, so transcription remains explicitly unavailable and
/// is never sent to a cloud fallback.
class PcmAnalyzer {
  final int sampleRate;
  final int frameMillis;

  const PcmAnalyzer({this.sampleRate = 16000, this.frameMillis = 50});

  VoiceAnalysis analyze(Uint8List pcm) {
    if (pcm.length.isOdd) throw const FormatException('PCM must be 16-bit');
    final samples = ByteData.sublistView(pcm);
    final frameSamples = sampleRate * frameMillis ~/ 1000;
    if (frameSamples <= 0) throw ArgumentError('invalid frame size');
    final levels = <double>[];
    final voiced = <bool>[];
    final seconds = <_SecondSamples>[];

    for (
      var offset = 0;
      offset + frameSamples * 2 <= pcm.length;
      offset += frameSamples * 2
    ) {
      final values = Float64List(frameSamples);
      var sum = 0.0;
      for (var i = 0; i < frameSamples; i++) {
        final value = samples
            .getInt16(offset + i * 2, Endian.little)
            .toDouble();
        values[i] = value;
        sum += value;
      }
      final mean = sum / frameSamples;
      var energy = 0.0;
      for (var i = 0; i < frameSamples; i++) {
        values[i] -= mean;
        energy += values[i] * values[i];
      }
      final rms = math.sqrt(energy / frameSamples);
      final db = rms <= 0 ? -90.0 : 20 * math.log(rms / 32768) / math.ln10;
      levels.add(db);
      final active = db >= -48;
      voiced.add(active);

      final secondIndex = offset ~/ (sampleRate * 2);
      final bucket = seconds.length > secondIndex
          ? seconds[secondIndex]
          : (seconds..add(_SecondSamples())).last;
      if (active) {
        bucket.voicedFrames++;
        bucket.volumeDb.add(db);
        final pitch = _pitch(values);
        if (pitch != null) bucket.pitchHz.add(pitch);
      }
    }

    final voicedFrames = voiced.where((value) => value).length;
    final voicedSeconds = math.min(30, voicedFrames * frameMillis ~/ 1000);
    if (voicedFrames == 0 || voicedSeconds == 0) {
      return const VoiceAnalysis(voicedSeconds: 0);
    }

    final volumeSamples = <double>[];
    final pitchSamples = <double>[];
    for (final bucket in seconds) {
      if (bucket.voicedFrames == 0) continue;
      volumeSamples.add(
        bucket.volumeDb.reduce((a, b) => a + b) / bucket.volumeDb.length,
      );
      if (bucket.pitchHz.isNotEmpty) {
        pitchSamples.add(
          bucket.pitchHz.reduce((a, b) => a + b) / bucket.pitchHz.length,
        );
      }
    }

    final peakSeconds = <int, int>{};
    for (final frameIndex in _syllablePeakIndexes(levels)) {
      final secondIndex = frameIndex * frameMillis ~/ 1000;
      peakSeconds[secondIndex] = (peakSeconds[secondIndex] ?? 0) + 1;
    }
    final speechSamples = <double>[
      for (final peaks in peakSeconds.values) peaks * 60.0,
    ];

    return VoiceAnalysis(
      voicedSeconds: voicedSeconds,
      speechRate: speechSamples.isEmpty
          ? null
          : _stat(speechSamples, voicedSeconds: voicedSeconds),
      volume: volumeSamples.isEmpty
          ? null
          : _stat(volumeSamples, voicedSeconds: voicedSeconds),
      pitch: pitchSamples.isEmpty
          ? null
          : _stat(pitchSamples, voicedSeconds: voicedSeconds),
    );
  }

  static double level(Uint8List pcm) {
    if (pcm.length < 2) return -90;
    final data = ByteData.sublistView(pcm);
    var sum = 0.0;
    final count = pcm.length ~/ 2;
    for (var i = 0; i < count; i++) {
      final value = data.getInt16(i * 2, Endian.little).toDouble();
      sum += value * value;
    }
    final rms = math.sqrt(sum / count);
    return rms <= 0 ? -90 : 20 * math.log(rms / 32768) / math.ln10;
  }

  double? _pitch(Float64List frame) {
    // Autocorrelation at 8 kHz is sufficient for 80-400 Hz and roughly halves
    // the work done for every voiced frame on the UI isolate.
    final decimated = <double>[
      for (var i = 0; i < frame.length; i += 2) frame[i],
    ];
    final pitchRate = sampleRate / 2;
    final minLag = (pitchRate / 400).floor();
    final maxLag = math.min((pitchRate / 80).ceil(), decimated.length ~/ 2);
    if (maxLag <= minLag) return null;

    final scores = List<double>.filled(maxLag + 1, 0);
    var bestScore = 0.0;
    var bestLag = 0;
    for (var lag = minLag; lag <= maxLag; lag++) {
      var cross = 0.0;
      var left = 0.0;
      var right = 0.0;
      final count = decimated.length - lag;
      for (var i = 0; i < count; i++) {
        final a = decimated[i];
        final b = decimated[i + lag];
        cross += a * b;
        left += a * a;
        right += b * b;
      }
      final denominator = math.sqrt(left * right);
      if (denominator == 0) continue;
      final score = cross / denominator;
      scores[lag] = score;
      if (score > bestScore) {
        bestScore = score;
        bestLag = lag;
      }
    }
    if (bestScore < 0.45 || bestLag == 0) return null;

    // The highest autocorrelation peak can be a multiple of the period when
    // the frame boundary is not exact. Prefer the first sufficiently strong
    // local peak, then interpolate its lag to avoid quantizing pitch to the
    // decimated sample rate.
    final strongPeak = math.max(0.55, bestScore * 0.85);
    var selectedLag = bestLag;
    for (var lag = minLag + 1; lag < maxLag; lag++) {
      if (scores[lag] >= strongPeak &&
          scores[lag] >= scores[lag - 1] &&
          scores[lag] > scores[lag + 1]) {
        selectedLag = lag;
        break;
      }
    }
    var refinedLag = selectedLag.toDouble();
    if (selectedLag > minLag && selectedLag < maxLag) {
      final previous = scores[selectedLag - 1];
      final current = scores[selectedLag];
      final next = scores[selectedLag + 1];
      final denominator = previous - 2 * current + next;
      if (denominator.abs() > 1e-9) {
        final offset = 0.5 * (previous - next) / denominator;
        if (offset.abs() <= 1) refinedLag += offset;
      }
    }
    return refinedLag > 0 ? pitchRate / refinedLag : null;
  }

  List<int> _syllablePeakIndexes(List<double> levels) {
    if (levels.length < 3) return const [];
    final smoothed = List<double>.generate(levels.length, (i) {
      final previous = levels[i == 0 ? 0 : i - 1];
      final next = levels[i == levels.length - 1 ? i : i + 1];
      return (previous + levels[i] * 2 + next) / 4;
    });
    final peaks = <int>[];
    var lastPeak = -100;
    final minimumGap = math.max(2, (120 / frameMillis).ceil());
    for (var i = 1; i < smoothed.length - 1; i++) {
      final isPeak =
          smoothed[i] >= -45 &&
          smoothed[i] >= smoothed[i - 1] &&
          smoothed[i] > smoothed[i + 1];
      if (isPeak && i - lastPeak >= minimumGap) {
        peaks.add(i);
        lastPeak = i;
      }
    }
    return peaks;
  }

  VoiceStat _stat(
    List<double> values, {
    required int voicedSeconds,
  }) => VoiceStat(
    mean: values.reduce((a, b) => a + b) / values.length,
    maximum: values.reduce(math.max),
    sampleCount: values.length,
    // Sparse speech can touch two one-second buckets while flooring to one
    // voiced second. The server treats voiced_seconds as the upper bound for
    // every feature's valid_seconds, so the wire value must obey that bound.
    validSeconds: math.min(values.length, voicedSeconds),
  );
}

class _SecondSamples {
  int voicedFrames = 0;
  final volumeDb = <double>[];
  final pitchHz = <double>[];
}
