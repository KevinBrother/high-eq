import '../../core/transport.dart';

const wleisAxisLabels = {
  'SEA': '自我觉察',
  'OEA': '读懂别人',
  'UOE': '自我激励',
  'ROE': '自我管理',
};

const achievementDays = [3, 7, 30];
const unlockBehaviorCopy = '完成一次整场对练或完整复盘后解锁训练参考分';

Json _json(Object? value, String field) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.cast<String, dynamic>();
  throw FormatException('$field 不是对象');
}

List<dynamic> _list(Object? value, String field) {
  if (value is List) return value;
  throw FormatException('$field 不是列表');
}

String _string(Object? value, String field) {
  if (value is String && value.isNotEmpty) return value;
  throw FormatException('$field 缺失');
}

bool _bool(Object? value, String field) {
  if (value is bool) return value;
  throw FormatException('$field 缺失');
}

int _int(Object? value, String field, {int min = 0, int? max}) {
  if (value is int && value >= min && (max == null || value <= max)) {
    return value;
  }
  throw FormatException('$field 无效');
}

double _percent(Object? value, String field) {
  if (value is num) {
    final parsed = value.toDouble();
    if (parsed.isFinite && parsed >= 0 && parsed <= 100) return parsed;
  }
  throw FormatException('$field 无效');
}

double? _optionalPercent(Object? value, String field) =>
    value == null ? null : _percent(value, field);

DateTime _time(Object? value, String field) {
  final parsed = value is String ? DateTime.tryParse(value) : null;
  if (parsed == null) throw FormatException('$field 无效');
  return parsed;
}

String _date(Object? value, String field) {
  final text = _string(value, field);
  if (DateTime.tryParse(text) == null) throw FormatException('$field 无效');
  return text;
}

enum PlanKind { exercise, level, card }

class PlanItemData {
  const PlanItemData({
    required this.id,
    required this.kind,
    required this.title,
    required this.contentId,
    required this.completed,
  });

  final String id;
  final PlanKind kind;
  final String title;
  final String contentId;
  final bool completed;

  factory PlanItemData.fromJson(Json json) => PlanItemData(
    id: _string(json['id'], '计划项 id'),
    kind: switch (json['kind']) {
      'exercise' => PlanKind.exercise,
      'level' => PlanKind.level,
      'card' => PlanKind.card,
      _ => throw const FormatException('计划项类型无效'),
    },
    title: _string(json['title'], '计划项标题'),
    contentId: _string(json['content_id'], '内容 id'),
    completed: _bool(json['completed'], '完成状态'),
  );

  PlanItemData complete() => PlanItemData(
    id: id,
    kind: kind,
    title: title,
    contentId: contentId,
    completed: true,
  );

  Json toJson() => {
    'id': id,
    'kind': kind.name,
    'title': title,
    'content_id': contentId,
    'completed': completed,
  };
}

class PlanData {
  const PlanData({
    required this.day,
    required this.personalized,
    required this.items,
  });

  final String day;
  final bool personalized;
  final List<PlanItemData> items;

  int get completed => items.where((item) => item.completed).length;
  bool get empty => items.isEmpty;

  factory PlanData.fromJson(Json json) => PlanData(
    day: _date(json['day'], '计划日期'),
    personalized: _bool(json['personalized'], '个性化标记'),
    items: [
      for (final row in _list(json['items'], '计划项'))
        PlanItemData.fromJson(_json(row, '计划项')),
    ],
  );

  PlanData complete(String id) => PlanData(
    day: day,
    personalized: personalized,
    items: [
      for (final item in items)
        if (item.id == id) item.complete() else item,
    ],
  );

  Json toJson() => {
    'day': day,
    'personalized': personalized,
    'items': [for (final item in items) item.toJson()],
  };
}

class GrowthData {
  const GrowthData({
    required this.latestAssessment,
    required this.wleisPercent,
    required this.trainingReference,
    required this.validBehaviorCount,
    required this.streak,
    required this.achievements,
  });

  final String? latestAssessment;
  final double? wleisPercent;
  final double? trainingReference;
  final int validBehaviorCount;
  final int streak;
  final List<int> achievements;

  factory GrowthData.fromJson(Json json) {
    final validBehaviorCount = _int(json['valid_behavior_count'], '有效行为数');
    final trainingReference = _optionalPercent(
      json['training_reference'],
      '训练参考分',
    );
    if (validBehaviorCount == 0 && trainingReference != null) {
      throw const FormatException('无有效行为记录时训练参考分必须为空');
    }
    return GrowthData(
      latestAssessment: json['latest_assessment'] == null
          ? null
          : _string(json['latest_assessment'], '最近测评 id'),
      wleisPercent: _optionalPercent(json['wleis_percent'], 'WLEIS 总分'),
      trainingReference: trainingReference,
      validBehaviorCount: validBehaviorCount,
      streak: _int(json['streak'], '连续天数'),
      achievements: [
        for (final row in _list(json['achievements'], '成就'))
          _int(row, '成就天数', min: 1),
      ],
    );
  }

  GrowthData withCompletion(int nextStreak, List<int> nextAchievements) =>
      GrowthData(
        latestAssessment: latestAssessment,
        wleisPercent: wleisPercent,
        trainingReference: trainingReference,
        validBehaviorCount: validBehaviorCount,
        streak: nextStreak,
        achievements: ({...achievements, ...nextAchievements}.toList()..sort()),
      );

  Json toJson() => {
    'latest_assessment': latestAssessment,
    'wleis_percent': wleisPercent,
    'training_reference': trainingReference,
    'valid_behavior_count': validBehaviorCount,
    'streak': streak,
    'achievements': achievements,
  };
}

class AssessmentData {
  const AssessmentData({
    required this.id,
    required this.completedAt,
    required this.nextEligibleAt,
    required this.dimensions,
    required this.totalPercent,
  });

  final String id;
  final DateTime completedAt;
  final DateTime nextEligibleAt;
  final Map<String, double> dimensions;
  final double totalPercent;

  factory AssessmentData.fromJson(Json json) {
    final dimensions = _json(json['dimensions'], '测评维度');
    final parsed = <String, double>{};
    for (final axis in wleisAxisLabels.keys) {
      final dimension = _json(dimensions[axis], '$axis 维度');
      parsed[axis] = _percent(dimension['percent'], '$axis 百分比');
    }
    return AssessmentData(
      id: _string(json['id'], '测评 id'),
      completedAt: _time(json['completed_at'], '测评时间'),
      nextEligibleAt: _time(json['next_eligible_at'], '复测时间'),
      dimensions: parsed,
      totalPercent: _percent(_json(json['total'], '测评总分')['percent'], '测评总分'),
    );
  }

  Json toJson() => {
    'id': id,
    'completed_at': completedAt.toIso8601String(),
    'next_eligible_at': nextEligibleAt.toIso8601String(),
    'dimensions': {
      for (final entry in dimensions.entries) entry.key: entry.value,
    },
    'total_percent': totalPercent,
  };

  factory AssessmentData.fromCache(Json json) {
    final dimensions = _json(json['dimensions'], '测评维度');
    return AssessmentData(
      id: _string(json['id'], '测评 id'),
      completedAt: _time(json['completed_at'], '测评时间'),
      nextEligibleAt: _time(json['next_eligible_at'], '复测时间'),
      dimensions: {
        for (final axis in wleisAxisLabels.keys)
          axis: _percent(dimensions[axis], axis),
      },
      totalPercent: _percent(json['total_percent'], '测评总分'),
    );
  }
}

class PracticeScoreData {
  const PracticeScoreData({
    required this.sessionId,
    required this.mode,
    required this.targetItem,
    required this.total,
    required this.maximum,
  });

  final String sessionId;
  final String mode;
  final String? targetItem;
  final int total;
  final int maximum;

  factory PracticeScoreData.fromJson(Json json) {
    final resultValue = json['result'];
    if (resultValue == null) throw const FormatException('缺少评分');
    final result = _json(resultValue, '对练结果');
    if (result['mode'] == 'single_skill') {
      final progress = _json(result['progress'], '单项结果');
      return PracticeScoreData(
        sessionId: _string(json['session_id'], '对练 id'),
        mode: 'single_skill',
        targetItem: _string(progress['target_item'], '目标项'),
        total: _int(progress['score'], '单项得分', max: 25),
        maximum: 25,
      );
    }
    if (result['mode'] != 'full_session') {
      throw const FormatException('对练模式无效');
    }
    final score = _json(result['score'], '整场结果');
    final nvc = _json(score['nvc'], 'NVC 得分');
    return PracticeScoreData(
      sessionId: _string(json['session_id'], '对练 id'),
      mode: 'full_session',
      targetItem: null,
      total: _int(nvc['total'], 'NVC 总分', max: 100),
      maximum: 100,
    );
  }

  factory PracticeScoreData.fromCache(Json json) {
    final mode = _string(json['mode'], '对练模式');
    final targetItem = json['target_item'] == null
        ? null
        : _string(json['target_item'], '目标项');
    final maximum = _int(json['maximum'], '满分', min: 1);
    final total = _int(json['total'], '对练得分', max: maximum);
    if (mode == 'single_skill') {
      if (targetItem == null || maximum != 25) {
        throw const FormatException('单项练习缓存无效');
      }
    } else if (mode == 'full_session') {
      if (targetItem != null || maximum != 100) {
        throw const FormatException('整场对练缓存无效');
      }
    } else {
      throw const FormatException('对练模式无效');
    }
    return PracticeScoreData(
      sessionId: _string(json['session_id'], '对练 id'),
      mode: mode,
      targetItem: targetItem,
      total: total,
      maximum: maximum,
    );
  }

  Json toJson() => {
    'session_id': sessionId,
    'mode': mode,
    'target_item': targetItem,
    'total': total,
    'maximum': maximum,
  };
}

class KnowledgeCardData {
  const KnowledgeCardData({
    required this.id,
    required this.title,
    required this.body,
    required this.scene,
  });

  final String id;
  final String title;
  final String body;
  final String scene;

  factory KnowledgeCardData.fromJson(Json json) => KnowledgeCardData(
    id: _string(json['id'], '卡片 id'),
    title: _string(json['title'], '卡片标题'),
    body: _string(json['body'], '卡片正文'),
    scene: _string(json['scene'], '卡片场景'),
  );

  Json toJson() => {'id': id, 'title': title, 'body': body, 'scene': scene};
}

class GrowthSnapshot {
  const GrowthSnapshot({
    required this.plan,
    required this.growth,
    required this.assessments,
    required this.sessions,
    required this.cards,
    this.cachedAt,
  });

  final PlanData plan;
  final GrowthData growth;
  final List<AssessmentData> assessments;
  final List<PracticeScoreData> sessions;
  final List<KnowledgeCardData> cards;
  final DateTime? cachedAt;

  /// Contract lists are not a time-order guarantee. Growth comparisons must
  /// use the completion time so a retried or merged response cannot make an
  /// older self-report appear as the latest one.
  List<AssessmentData> get orderedAssessments {
    final ordered = [...assessments];
    ordered.sort((a, b) {
      final byTime = b.completedAt.compareTo(a.completedAt);
      return byTime != 0 ? byTime : b.id.compareTo(a.id);
    });
    return ordered;
  }

  AssessmentData? get latestAssessment => orderedAssessments.firstOrNull;
  AssessmentData? get previousAssessment =>
      orderedAssessments.length < 2 ? null : orderedAssessments[1];
  List<PracticeScoreData> get scoredSessions => sessions;

  factory GrowthSnapshot.fromApi({
    required Json plan,
    required Json growth,
    required Json assessments,
    required Json sessions,
    required Json cards,
  }) => GrowthSnapshot(
    plan: PlanData.fromJson(plan),
    growth: GrowthData.fromJson(growth),
    assessments: [
      for (final row in _list(assessments['items'], '测评列表'))
        AssessmentData.fromJson(_json(row, '测评')),
    ],
    sessions: [
      for (final row in _list(sessions['items'], '对练列表'))
        if (_json(row, '对练')['result'] != null)
          PracticeScoreData.fromJson(_json(row, '对练')),
    ],
    cards: [
      for (final row in _list(cards['items'], '卡片列表'))
        KnowledgeCardData.fromJson(_json(row, '知识卡')),
    ],
  );

  GrowthSnapshot withCompletion(
    String itemId,
    int streak,
    List<int> achievements,
  ) => GrowthSnapshot(
    plan: plan.complete(itemId),
    growth: growth.withCompletion(streak, achievements),
    assessments: assessments,
    sessions: sessions,
    cards: cards,
    cachedAt: cachedAt,
  );

  GrowthSnapshot asCached(DateTime at) => GrowthSnapshot(
    plan: plan,
    growth: growth,
    assessments: assessments,
    sessions: sessions,
    cards: cards,
    cachedAt: at,
  );

  Json toJson() => {
    'version': 1,
    'cached_at': (cachedAt ?? DateTime.now()).toIso8601String(),
    'plan': plan.toJson(),
    'growth': growth.toJson(),
    'assessments': [for (final item in assessments) item.toJson()],
    'sessions': [for (final item in sessions) item.toJson()],
    'cards': [for (final item in cards) item.toJson()],
  };

  factory GrowthSnapshot.fromCache(Json json) {
    if (json['version'] != 1) throw const FormatException('缓存版本无效');
    return GrowthSnapshot(
      plan: PlanData.fromJson(_json(json['plan'], '计划缓存')),
      growth: GrowthData.fromJson(_json(json['growth'], '成长缓存')),
      assessments: [
        for (final row in _list(json['assessments'], '测评缓存'))
          AssessmentData.fromCache(_json(row, '测评缓存')),
      ],
      sessions: [
        for (final row in _list(json['sessions'], '对练缓存'))
          PracticeScoreData.fromCache(_json(row, '对练缓存')),
      ],
      cards: [
        for (final row in _list(json['cards'], '卡片缓存'))
          KnowledgeCardData.fromJson(_json(row, '卡片缓存')),
      ],
      cachedAt: _time(json['cached_at'], '缓存时间'),
    );
  }
}

class ExerciseData {
  const ExerciseData({
    required this.id,
    required this.question,
    required this.choices,
  });

  final String id;
  final String question;
  final List<String> choices;

  factory ExerciseData.fromJson(Json json) {
    final choices = _list(json['choices'], '练习选项');
    if (choices.length < 2) throw const FormatException('练习选项不足');
    return ExerciseData(
      id: _string(json['id'], '练习 id'),
      question: _string(json['question'], '练习题目'),
      choices: [for (final row in choices) _string(row, '练习选项')],
    );
  }
}

class AnswerData {
  const AnswerData({required this.correct, required this.explanation});

  final bool correct;
  final String explanation;

  factory AnswerData.fromJson(Json json) => AnswerData(
    correct: _bool(json['correct'], '答案结果'),
    explanation: _string(json['explanation'], '答案解析'),
  );
}

class CompletionData {
  const CompletionData({required this.streak, required this.achievements});

  final int streak;
  final List<int> achievements;

  factory CompletionData.fromJson(Json json) => CompletionData(
    streak: _int(json['streak'], '连续天数'),
    achievements: [
      for (final row in _list(json['achievements'], '成就'))
        _int(row, '成就天数', min: 1),
    ],
  );
}
