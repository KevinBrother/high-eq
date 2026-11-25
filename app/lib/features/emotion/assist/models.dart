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
