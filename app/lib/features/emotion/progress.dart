import 'dart:math' as math;

import 'signal_contract.dart';

const _durationSignals = <String>[
  'heart_rate',
  'speech_rate',
  'volume',
  'pitch',
];

class DurationProgress {
  final int validDays;
  final int todayValidSeconds;
  final bool ready;
  final String reason;
  final double? baseline;
  final double? threshold;

  const DurationProgress({
    required this.validDays,
    required this.todayValidSeconds,
    required this.ready,
    required this.reason,
    this.baseline,
    this.threshold,
  });
}

class HrvTrend {
  final int readings;
  final int samplingDays;
  final bool readyForAlert;
  final String reason;

  const HrvTrend({
    required this.readings,
    required this.samplingDays,
    required this.readyForAlert,
    required this.reason,
  });
}

class SignalProgress {
  final DurationProgress heartRate;
  final DurationProgress speechRate;
  final DurationProgress volume;
  final DurationProgress pitch;
  final HrvTrend hrv;

  const SignalProgress({
    required this.heartRate,
    required this.speechRate,
    required this.volume,
    required this.pitch,
    required this.hrv,
  });

  DurationProgress forSignal(String signal) => switch (signal) {
    'heart_rate' => heartRate,
    'speech_rate' => speechRate,
    'volume' => volume,
    'pitch' => pitch,
    _ => throw ArgumentError.value(signal, 'signal'),
  };

  /// Folds the real T30 progress vectors. Production reads progress from the
  /// server; this pure engine is used by the client contract tests and keeps
  /// missing, silent and motion-masked seconds out of every total.
  static SignalProgress fromWindows({
    required DateTime now,
    required String zone,
    required List<Map<String, dynamic>> windows,
    Map<String, int> falsePositives = const {},
  }) {
    final local = _LocalZone(zone);
    final slots = <DateTime, _Slot>{};
    for (final raw in windows) {
      final at = DateTime.tryParse(raw['starts_at'] as String? ?? '')?.toUtc();
      if (at == null) throw const FormatException('无效的信号窗口时间');
      if (raw['duration_seconds'] != 30) {
        throw const FormatException('信号窗口必须为 30 秒');
      }
      final channel = raw['channel'];
      if (channel != 'health' && channel != 'voice') {
        throw const FormatException('无效的信号窗口通道');
      }
      final slot = slots.putIfAbsent(at, _Slot.new);
      if (channel == 'health') {
        if (slot.health != null) throw const FormatException('重复的健康窗口');
        slot.health = raw;
      } else {
        if (slot.voice != null) throw const FormatException('重复的语音窗口');
        slot.voice = raw;
      }
    }

    final accumulator = _Accumulator(local);
    final ordered = slots.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final cadence = <_Cadence>[];
    for (final entry in ordered) {
      final at = entry.key;
      cadence.removeWhere(
        (point) => !point.at.isAfter(at.subtract(const Duration(minutes: 2))),
      );
      final slot = entry.value;
      final health = slot.health;
      final voice = slot.voice;
      if (health != null) {
        final cadenceStat = _stat(health['cadence']);
        if (cadenceStat != null && cadenceStat.validSeconds > 0) {
          cadence.add(_Cadence(at, cadenceStat.mean, cadenceStat.validSeconds));
        }
      }
      var seconds = 0;
      var weighted = 0.0;
      for (final point in cadence) {
        seconds += point.seconds;
        weighted += point.mean * point.seconds;
      }
      final cadenceMean = seconds == 0 ? 0.0 : weighted / seconds;
      final exercise =
          health?['exercise'] == true || voice?['exercise'] == true;
      final masked = exercise || cadenceMean > 100;

      if (health != null) {
        final hrv = _hrvStat(health['hrv']);
        if (hrv != null && hrv.sampleCount > 0) {
          accumulator.hrvReadings += hrv.sampleCount;
          accumulator.hrvDays.add(local.dayKey(at));
        }
        if (!masked) {
          _addStat(accumulator, at, 'heart_rate', health['heart_rate']);
        }
      }
      if (voice != null && !masked) {
        if (voice['speech_rate_unit'] == charactersPerSecondUnit) {
          _addStat(accumulator, at, 'speech_rate', voice['speech_rate']);
        }
        _addStat(accumulator, at, 'volume', voice['volume']);
        _addStat(accumulator, at, 'pitch', voice['pitch']);
      }
    }
    return accumulator.result(now, falsePositives);
  }
}

class _Slot {
  Map<String, dynamic>? health;
  Map<String, dynamic>? voice;
}

class _Cadence {
  final DateTime at;
  final double mean;
  final int seconds;

  const _Cadence(this.at, this.mean, this.seconds);
}

class _Stat {
  final double mean;
  final int sampleCount;
  final int validSeconds;

  const _Stat(this.mean, this.sampleCount, this.validSeconds);
}

_Stat? _stat(Object? value) {
  if (value is! Map) return null;
  final mean = value['mean'];
  final count = value['sample_count'];
  final seconds = value['valid_seconds'];
  if (mean is! num || count is! int || seconds is! int) return null;
  final number = mean.toDouble();
  if (!number.isFinite || count < 0 || seconds < 0) return null;
  return _Stat(number, count, seconds);
}

_Stat? _hrvStat(Object? value) {
  if (value is! Map) return null;
  final mean = value['mean'];
  final count = value['sample_count'];
  if (mean is! num || count is! int) return null;
  final number = mean.toDouble();
  if (!number.isFinite || count < 0) return null;
  return _Stat(number, count, 0);
}

void _addStat(
  _Accumulator accumulator,
  DateTime at,
  String signal,
  Object? value,
) {
  final stat = _stat(value);
  if (stat == null || stat.validSeconds <= 0) return;
  accumulator.add(at, signal, stat.mean, stat.validSeconds);
}

class _Totals {
  int seconds = 0;
  double weighted = 0;
  final days = <String, int>{};
}

class _Accumulator {
  final _LocalZone local;
  final stats = <String, _Totals>{};
  final hrvDays = <String>{};
  int hrvReadings = 0;

  _Accumulator(this.local);

  void add(DateTime at, String signal, double mean, int seconds) {
    if (seconds <= 0) return;
    final total = stats.putIfAbsent(signal, _Totals.new);
    total.seconds += seconds;
    total.weighted += mean * seconds;
    final day = local.dayKey(at);
    total.days[day] = (total.days[day] ?? 0) + seconds;
  }

  SignalProgress result(DateTime now, Map<String, int> falsePositives) {
    final today = local.dayKey(now);
    final progress = <String, DurationProgress>{};
    for (final signal in _durationSignals) {
      final total = stats[signal];
      if (total == null || total.seconds == 0) {
        progress[signal] = DurationProgress(
          validDays: 0,
          todayValidSeconds: 0,
          ready: false,
          reason: signal == 'heart_rate' ? '尚无有效覆盖' : '尚无人声特征有效时长',
        );
        continue;
      }
      final days = total.days.values.where((seconds) => seconds >= 1800).length;
      final todaySeconds = total.days[today] ?? 0;
      if (days < 7) {
        progress[signal] = DurationProgress(
          validDays: days,
          todayValidSeconds: todaySeconds,
          ready: false,
          reason: '有效日不足 7 天（每天需 1800 秒）',
        );
        continue;
      }
      final baseline = total.weighted / total.seconds;
      final factor = EmotionDecisionFactor.forCount(
        falsePositives[signal] ?? 0,
      );
      final threshold = switch (signal) {
        'heart_rate' => baseline * 1.20 * factor,
        'speech_rate' => baseline * 1.25 * factor,
        'pitch' => baseline * 1.15 * factor,
        'volume' => baseline + 6 * factor,
        _ => throw StateError('unknown signal'),
      };
      progress[signal] = DurationProgress(
        validDays: days,
        todayValidSeconds: todaySeconds,
        ready: true,
        reason: '基线已就绪',
        baseline: baseline,
        threshold: threshold,
      );
    }
    return SignalProgress(
      heartRate: progress['heart_rate']!,
      speechRate: progress['speech_rate']!,
      volume: progress['volume']!,
      pitch: progress['pitch']!,
      hrv: HrvTrend(
        readings: hrvReadings,
        samplingDays: hrvDays.length,
        readyForAlert: false,
        reason: hrvReadings == 0 ? '暂无离散读数，不影响提醒' : '仅供历史趋势，不参与提醒',
      ),
    );
  }
}

class EmotionDecisionFactor {
  static double forCount(int count) =>
      math.min(1.5, math.pow(1.05, math.max(0, count)).toDouble());
}

class _LocalZone {
  final String name;
  const _LocalZone(this.name);

  String dayKey(DateTime value) {
    final at = _at(value);
    return '${at.year.toString().padLeft(4, '0')}-'
        '${at.month.toString().padLeft(2, '0')}-'
        '${at.day.toString().padLeft(2, '0')}';
  }

  DateTime _at(DateTime value) {
    final utc = value.toUtc();
    if (name == 'UTC' || name == 'Etc/UTC') return utc;
    // China has no daylight-saving transition. Other zones are not silently
    // approximated: callers must pass a supported account timezone.
    if (const {
      'Asia/Shanghai',
      'Asia/Chongqing',
      'Asia/Hong_Kong',
      'Asia/Macau',
      'Asia/Singapore',
      'Asia/Taipei',
    }.contains(name)) {
      return utc.add(const Duration(hours: 8));
    }
    throw UnsupportedError('不支持的账号时区：$name');
  }
}
