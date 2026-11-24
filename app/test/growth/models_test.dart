import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/features/growth/models.dart';

void main() {
  group('GrowthData', () {
    test('完成打卡合并历史成就而不是用服务端列表覆盖', () {
      const growth = GrowthData(
        latestAssessment: null,
        wleisPercent: null,
        trainingReference: null,
        validBehaviorCount: 0,
        streak: 6,
        achievements: [3, 7],
      );

      final next = growth.withCompletion(7, [7, 30]);

      expect(next.streak, 7);
      expect(next.achievements, [3, 7, 30]);
    });

    test('无有效行为记录时拒绝服务端伪训练参考分', () {
      expect(
        () => GrowthData.fromJson({
          'latest_assessment': null,
          'wleis_percent': null,
          'training_reference': 70,
          'valid_behavior_count': 0,
          'streak': 3,
          'achievements': [3],
        }),
        throwsFormatException,
      );
    });

    test('有有效行为记录时允许训练参考分为空', () {
      final growth = GrowthData.fromJson({
        'latest_assessment': null,
        'wleis_percent': null,
        'training_reference': null,
        'valid_behavior_count': 2,
        'streak': 3,
        'achievements': [3],
      });

      expect(growth.trainingReference, isNull);
      expect(growth.validBehaviorCount, 2);
    });
  });

  group('PracticeScoreData.fromCache', () {
    test('接受契约内的单项与整场得分', () {
      final single = PracticeScoreData.fromCache({
        'session_id': 'single',
        'mode': 'single_skill',
        'target_item': 'feeling',
        'total': 20,
        'maximum': 25,
      });
      final full = PracticeScoreData.fromCache({
        'session_id': 'full',
        'mode': 'full_session',
        'target_item': null,
        'total': 74,
        'maximum': 100,
      });

      expect(single.maximum, 25);
      expect(single.targetItem, 'feeling');
      expect(single.completedAt, isNull);
      expect(full.maximum, 100);
      expect(full.targetItem, isNull);
      expect(full.completedAt, isNull);
    });

    for (final invalid in <Map<String, dynamic>>[
      {
        'session_id': 'zero',
        'mode': 'full_session',
        'target_item': null,
        'total': 0,
        'maximum': 0,
      },
      {
        'session_id': 'over',
        'mode': 'full_session',
        'target_item': null,
        'total': 101,
        'maximum': 100,
      },
      {
        'session_id': 'wrong-max',
        'mode': 'single_skill',
        'target_item': 'need',
        'total': 20,
        'maximum': 100,
      },
      {
        'session_id': 'missing-target',
        'mode': 'single_skill',
        'target_item': null,
        'total': 20,
        'maximum': 25,
      },
      {
        'session_id': 'full-with-target',
        'mode': 'full_session',
        'target_item': 'request',
        'total': 70,
        'maximum': 100,
      },
      {
        'session_id': 'unknown-mode',
        'mode': 'behavior',
        'target_item': null,
        'total': 70,
        'maximum': 100,
      },
      {
        'session_id': 'invalid-completed-at',
        'mode': 'full_session',
        'target_item': null,
        'total': 70,
        'maximum': 100,
        'completed_at': 'not-a-date',
      },
    ]) {
      test('拒绝无效缓存 ${invalid['session_id']}', () {
        expect(
          () => PracticeScoreData.fromCache(invalid),
          throwsFormatException,
        );
      });
    }
  });

  test('测评按完成时间排序，不依赖接口列表顺序', () {
    final snapshot = GrowthSnapshot.fromApi(
      plan: {'day': '2026-11-22', 'personalized': false, 'items': []},
      growth: {
        'latest_assessment': 'older',
        'wleis_percent': 50,
        'training_reference': null,
        'valid_behavior_count': 0,
        'streak': 0,
        'achievements': [],
      },
      assessments: {
        'items': [
          _assessment('older', DateTime.utc(2026, 8)),
          _assessment('latest', DateTime.utc(2026, 11)),
        ],
      },
      sessions: {
        'items': [
          {
            'session_id': 'pending',
            'status': 'active',
            'mode': 'single_skill',
            'target_item': 'feeling',
            'messages': [],
            'settlement': {
              'status': 'uncharged',
              'net_charge': 0,
              'charged_day': null,
            },
          },
          {
            'session_id': 'scored',
            'status': 'complete',
            'mode': 'full_session',
            'target_item': null,
            'messages': [],
            'settlement': {
              'status': 'charged',
              'net_charge': 1,
              'charged_day': '2026-11-22',
            },
            'result': {
              'mode': 'full_session',
              'score': {
                'nvc': {'total': 75},
              },
              'settlement': {
                'status': 'charged',
                'net_charge': 1,
                'charged_day': '2026-11-22',
              },
            },
          },
        ],
      },
      cards: {'items': []},
    );

    expect(snapshot.latestAssessment?.id, 'latest');
    expect(snapshot.previousAssessment?.id, 'older');
    expect(snapshot.scoredSessions.map((score) => score.sessionId), ['scored']);
  });

  test('历次得分按实际完成时间排序，未知时间排最后且并列稳定', () {
    final snapshot = GrowthSnapshot.fromApi(
      plan: {'day': '2026-11-22', 'personalized': false, 'items': []},
      growth: {
        'latest_assessment': null,
        'wleis_percent': null,
        'training_reference': null,
        'valid_behavior_count': 0,
        'streak': 0,
        'achievements': [],
      },
      assessments: {'items': []},
      sessions: {
        'items': [
          _scoredSession(
            'created-second',
            completedAt: DateTime.utc(2026, 11, 10),
            total: 61,
          ),
          _scoredSession(
            'tie-a',
            completedAt: DateTime.utc(2026, 11, 15),
            total: 72,
          ),
          _scoredSession(
            'created-first',
            completedAt: DateTime.utc(2026, 11, 20),
            total: 84,
          ),
          _scoredSession('unknown-a', total: 55),
          _scoredSession('unknown-b', total: 58),
          _scoredSession(
            'tie-b',
            completedAt: DateTime.utc(2026, 11, 15),
            total: 66,
          ),
        ],
      },
      cards: {'items': []},
    );

    expect(snapshot.scoredSessions.map((score) => score.sessionId), [
      'created-first',
      'tie-b',
      'tie-a',
      'created-second',
      'unknown-b',
      'unknown-a',
    ]);
  });

  test('同一快照的1000条得分复用排序结果且不修改原集合', () {
    final source = List<PracticeScoreData>.generate(1000, (index) {
      return PracticeScoreData(
        sessionId: 'session-$index',
        mode: 'full_session',
        targetItem: null,
        total: index % 101,
        maximum: 100,
        completedAt: index.isEven
            ? null
            : DateTime.utc(2026, 11, 1).add(Duration(minutes: index)),
      );
    });
    final originalIds = [for (final score in source) score.sessionId];
    final snapshot = GrowthSnapshot(
      plan: const PlanData(day: '2026-11-22', personalized: false, items: []),
      growth: const GrowthData(
        latestAssessment: null,
        wleisPercent: null,
        trainingReference: null,
        validBehaviorCount: 0,
        streak: 0,
        achievements: [],
      ),
      assessments: const [],
      sessions: source,
      cards: const [],
    );

    final ordered = snapshot.scoredSessions;

    expect(ordered, hasLength(1000));
    expect(identical(ordered, snapshot.scoredSessions), isTrue);
    expect([for (final score in source) score.sessionId], originalIds);
  });

  test('成长快照缓存往返保留四维与得分边界', () {
    final snapshot = GrowthSnapshot(
      plan: const PlanData(
        day: '2026-11-22',
        personalized: true,
        items: [
          PlanItemData(
            id: 'plan',
            kind: PlanKind.exercise,
            title: '读人小练习',
            contentId: 'exercise',
            completed: false,
          ),
        ],
      ),
      growth: const GrowthData(
        latestAssessment: 'latest',
        wleisPercent: 68,
        trainingReference: null,
        validBehaviorCount: 0,
        streak: 3,
        achievements: [3],
      ),
      assessments: [
        AssessmentData.fromJson(_assessment('latest', DateTime.utc(2026, 11))),
      ],
      sessions: [
        PracticeScoreData(
          sessionId: 'single',
          mode: 'single_skill',
          targetItem: 'feeling',
          total: 20,
          maximum: 25,
          completedAt: DateTime.utc(2026, 11, 20),
        ),
      ],
      cards: const [],
    );

    final cached = GrowthSnapshot.fromCache(
      snapshot.asCached(DateTime.utc(2026, 11, 22)).toJson(),
    );

    expect(cached.latestAssessment?.dimensions, {
      'SEA': 68.0,
      'OEA': 68.0,
      'UOE': 68.0,
      'ROE': 68.0,
    });
    expect(cached.sessions.single.total, 20);
    expect(cached.sessions.single.maximum, 25);
    expect(cached.sessions.single.completedAt, DateTime.utc(2026, 11, 20));
    expect(cached.cachedAt, DateTime.utc(2026, 11, 22));
  });
}

Map<String, dynamic> _assessment(String id, DateTime completedAt) => {
  'id': id,
  'completed_at': completedAt.toIso8601String(),
  'next_eligible_at': completedAt
      .add(const Duration(days: 28))
      .toIso8601String(),
  'dimensions': {
    for (final axis in wleisAxisLabels.keys) axis: {'percent': 68},
  },
  'total': {'percent': 68},
};

Map<String, dynamic> _scoredSession(
  String id, {
  DateTime? completedAt,
  int total = 70,
}) => {
  'session_id': id,
  'status': 'complete',
  'mode': 'full_session',
  'target_item': null,
  'messages': <Object>[],
  'settlement': {
    'status': 'charged',
    'net_charge': 1,
    'charged_day': '2026-11-22',
  },
  'completed_at': completedAt?.toIso8601String(),
  'result': {
    'mode': 'full_session',
    'score': {
      'nvc': {'total': total},
    },
    'settlement': {
      'status': 'charged',
      'net_charge': 1,
      'charged_day': '2026-11-22',
    },
  },
};
