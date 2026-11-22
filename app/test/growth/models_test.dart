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
      expect(full.maximum, 100);
      expect(full.targetItem, isNull);
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
      sessions: const [
        PracticeScoreData(
          sessionId: 'single',
          mode: 'single_skill',
          targetItem: 'feeling',
          total: 20,
          maximum: 25,
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
