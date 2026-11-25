import 'dart:math' as math;

import 'signal_contract.dart';

const selfFluctuation = 'self_fluctuation';
const conversationRhythm = 'conversation_rhythm';
const noEmotionSignal = 'none';

const emotionSignals = <String>['heart_rate', 'speech_rate', 'volume', 'pitch'];

/// Pure port of the T30 classifier. The input is the exact JSON frame shape
/// used by the server vectors, so missing and explicit-null values stay
/// distinct from zero.
class EmotionDecision {
  final String kind;
  final List<String> signals;

  const EmotionDecision(this.kind, [this.signals = const []]);

  static EmotionDecision evaluate(Map<String, dynamic> frame) {
    const none = EmotionDecision(noEmotionSignal);
    final start = _date(frame['starts_at']);
    final voiceAt = _date(frame['voice_at']);
    if (start == null || !_isUtcAligned(start) || voiceAt != start) {
      return none;
    }
    if (frame['exercise'] == true) return none;

    final cadence = _number(frame['cadence_2m']) ?? 0;
    if (!cadence.isFinite || cadence > 100) return none;

    final lastAlert = _date(frame['last_alert']);
    if (lastAlert != null &&
        start.difference(lastAlert) < const Duration(minutes: 10)) {
      return none;
    }

    final healthAt = _date(frame['health_at']);
    final source = frame['source'];
    final watchReleased = frame['watch_released'] == true;
    final means = _map(frame['means']);
    final thresholds = _map(frame['thresholds']);
    final hits = <String>[];
    for (final signal in emotionSignals) {
      final mean = _number(means[signal]);
      final threshold = _number(thresholds[signal]);
      if (mean == null ||
          threshold == null ||
          !mean.isFinite ||
          !threshold.isFinite ||
          mean < threshold) {
        continue;
      }
      if (signal == 'speech_rate' &&
          frame['speech_rate_unit'] != charactersPerSecondUnit) {
        continue;
      }
      if (signal == 'heart_rate' &&
          (healthAt != start || source != 'watch_live' || !watchReleased)) {
        continue;
      }
      hits.add(signal);
    }

    if (hits.length < 2) return none;
    if (hits.first == 'heart_rate') {
      return EmotionDecision(selfFluctuation, List.unmodifiable(hits));
    }
    if (hits.first == 'speech_rate') {
      return EmotionDecision(conversationRhythm, List.unmodifiable(hits));
    }
    return none;
  }

  static bool _isUtcAligned(DateTime value) =>
      value.isUtc &&
      value.millisecond == 0 &&
      value.microsecond == 0 &&
      value.second % 30 == 0;

  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value)?.toUtc() : null;

  static double? _number(Object? value) =>
      value is num ? value.toDouble() : null;

  static Map<String, dynamic> _map(Object? value) =>
      value is Map ? value.cast<String, dynamic>() : const {};

  static double rounded(double value) =>
      (value * 1000000).roundToDouble() / 1000000;

  static double cooldownFactor(int falsePositiveCount) =>
      math.min(1.5, math.pow(1.05, math.max(0, falsePositiveCount)).toDouble());
}
