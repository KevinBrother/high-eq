import '../progress.dart';

const _scenes = {'work', 'partner', 'family', 'friends', 'social'};

class AssistAccess {
  final String tier;
  final DateTime? expiresAt;
  final bool autoWatchAlertAvailable;

  const AssistAccess({
    required this.tier,
    required this.expiresAt,
    required this.autoWatchAlertAvailable,
  });

  factory AssistAccess.fromJson(Map<String, dynamic> json) {
    final tier = json['tier'];
    final rawExpiry = json['expires_at'];
    final autoWatch = json['auto_watch_alert_available'];
    if (tier != 'free' && tier != 'member') {
      throw const FormatException('无效的会员等级');
    }
    if (rawExpiry != null && rawExpiry is! String) {
      throw const FormatException('无效的会员到期时间');
    }
    final expiresAt = rawExpiry == null
        ? null
        : DateTime.tryParse(rawExpiry)?.toUtc();
    if (rawExpiry != null && expiresAt == null) {
      throw const FormatException('无效的会员到期时间');
    }
    if (autoWatch is! bool) {
      throw const FormatException('无效的手表提醒状态');
    }
    return AssistAccess(
      tier: tier as String,
      expiresAt: expiresAt,
      autoWatchAlertAvailable: autoWatch,
    );
  }

  bool activeAt(DateTime at) =>
      tier == 'member' && expiresAt != null && expiresAt!.isAfter(at.toUtc());
}

class EmotionGroup {
  final String? contactId;
  final String? scene;
  final int manualCount;
  final int confirmedSelfCount;

  const EmotionGroup({
    this.contactId,
    required this.scene,
    required this.manualCount,
    required this.confirmedSelfCount,
  });
}

List<EmotionGroup> emotionSummaryFromJson(Map<String, dynamic> json) {
  final groups = json['groups'];
  if (groups is! List) throw const FormatException('无效的情绪汇总');
  return List.unmodifiable(
    groups.map((value) {
      final raw = _object(value, '情绪汇总分组');
      final contactId = _nullableText(raw['contact_id'], 'group.contact_id');
      final scene = _nullableText(raw['scene'], 'group.scene', nonEmpty: true);
      if (scene != null && !_scenes.contains(scene)) {
        throw const FormatException('无效的汇总场景');
      }
      return EmotionGroup(
        contactId: contactId,
        scene: scene,
        manualCount: _nonNegativeInt(raw['manual_count'], 'group.manual_count'),
        confirmedSelfCount: _nonNegativeInt(
          raw['confirmed_self_count'],
          'group.confirmed_self_count',
        ),
      );
    }),
  );
}

/// A missing signal here means its account consent is absent or withdrawn.
class BaselineProgress {
  const BaselineProgress({
    this.heartRate,
    this.speechRate,
    this.volume,
    this.pitch,
    this.hrv,
  });

  final DurationProgress? heartRate;
  final DurationProgress? speechRate;
  final DurationProgress? volume;
  final DurationProgress? pitch;
  final HrvTrend? hrv;

  factory BaselineProgress.fromJson(
    Map<String, dynamic> json, {
    required bool healthGranted,
    required bool voiceGranted,
  }) {
    DurationProgress duration(String key) {
      final row = _object(json[key], '$key 进度');
      final ready = row['ready'];
      if (ready is! bool) throw FormatException('无效的$key 就绪状态');
      final baseline = _nullableFiniteNumber(row, 'baseline');
      final threshold = _nullableFiniteNumber(row, 'threshold');
      // T30 uses dB for volume. Both values can legitimately be negative.
      if (ready != (baseline != null) || ready != (threshold != null)) {
        throw FormatException('无效的$key 基线与阈值');
      }
      return DurationProgress(
        validDays: _nonNegativeInt(row['valid_days'], '$key.valid_days'),
        todayValidSeconds: _nonNegativeInt(
          row['today_valid_seconds'],
          '$key.today_valid_seconds',
        ),
        ready: ready,
        reason: _progressReason(row, key),
        baseline: baseline,
        threshold: threshold,
      );
    }

    HrvTrend trend() {
      final row = _object(json['hrv'], 'HRV 趋势');
      if (row['ready_for_alert'] != false) {
        throw const FormatException('无效的 HRV 趋势状态');
      }
      return HrvTrend(
        readings: _nonNegativeInt(row['readings'], 'hrv.readings'),
        samplingDays: _nonNegativeInt(
          row['sampling_days'],
          'hrv.sampling_days',
        ),
        readyForAlert: false,
        reason: _progressReason(row, 'HRV'),
      );
    }

    return BaselineProgress(
      heartRate: healthGranted ? duration('heart_rate') : null,
      speechRate: voiceGranted ? duration('speech_rate') : null,
      volume: voiceGranted ? duration('volume') : null,
      pitch: voiceGranted ? duration('pitch') : null,
      hrv: healthGranted ? trend() : null,
    );
  }
}

String _progressReason(Map<String, dynamic> row, String key) =>
    _nullableText(row['reason'], '$key.reason', nonEmpty: true) ??
    (throw FormatException('缺少$key 进度说明'));

double? _nullableFiniteNumber(Map<String, dynamic> row, String key) {
  final value = row[key];
  if (value == null && row.containsKey(key)) return null;
  if (value is num && value.isFinite) return value.toDouble();
  throw FormatException('无效的$key');
}

Map<String, dynamic> _object(Object? value, String name) {
  if (value is! Map) throw FormatException('无效的$name');
  try {
    return value.cast<String, dynamic>();
  } on TypeError {
    throw FormatException('无效的$name');
  }
}

String? _nullableText(Object? value, String name, {bool nonEmpty = false}) {
  if (value == null) return null;
  if (value is! String) throw FormatException('无效的$name');
  if (nonEmpty && value.trim().isEmpty) throw FormatException('无效的$name');
  return value;
}

int _nonNegativeInt(Object? value, String name) {
  if (value is! int || value < 0) throw FormatException('无效的$name');
  return value;
}
