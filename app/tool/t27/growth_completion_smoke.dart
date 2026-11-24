import 'dart:io';

import 'package:high_eq/features/growth/models.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void main() {
  Map<String, dynamic> scored(String id, {DateTime? completedAt}) => {
    'session_id': id,
    'status': 'complete',
    'mode': 'full_session',
    'target_item': null,
    'messages': <Object>[],
    'completed_at': completedAt?.toIso8601String(),
    'settlement': {
      'status': 'charged',
      'net_charge': 1,
      'charged_day': '2026-11-22',
    },
    'result': {
      'mode': 'full_session',
      'score': {
        'nvc': {'total': 70},
      },
      'settlement': {
        'status': 'charged',
        'net_charge': 1,
        'charged_day': '2026-11-22',
      },
    },
  };

  final source = [
    scored('created-second', completedAt: DateTime.utc(2026, 11, 10)),
    scored('tie-a', completedAt: DateTime.utc(2026, 11, 15)),
    scored('created-first', completedAt: DateTime.utc(2026, 11, 20, 9)),
    scored('unknown-a'),
    scored('unknown-b'),
    scored('tie-b', completedAt: DateTime.utc(2026, 11, 15)),
  ];
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
    sessions: {'items': source},
    cards: {'items': []},
  );

  final expected = [
    'created-first',
    'tie-b',
    'tie-a',
    'created-second',
    'unknown-b',
    'unknown-a',
  ];
  check(
    snapshot.scoredSessions.map((score) => score.sessionId).join(',') ==
        expected.join(','),
    'unexpected order: ${snapshot.scoredSessions.map((score) => score.sessionId)}',
  );
  check(
    snapshot.sessions.map((score) => score.sessionId).join(',') ==
        source.map((row) => row['session_id']).join(','),
    'source list was mutated',
  );

  final cached = GrowthSnapshot.fromCache(
    snapshot.asCached(DateTime.utc(2026, 11, 22)).toJson(),
  );
  check(
    cached.sessions
            .singleWhere((score) => score.sessionId == 'created-first')
            .completedAt ==
        DateTime.utc(2026, 11, 20, 9),
    'cache did not preserve completion time',
  );

  var rejected = false;
  try {
    PracticeScoreData.fromCache({
      'session_id': 'bad-time',
      'mode': 'full_session',
      'target_item': null,
      'total': 70,
      'maximum': 100,
      'completed_at': 'not-a-date',
    });
  } on FormatException {
    rejected = true;
  }
  check(rejected, 'invalid completion time was accepted');
  stdout.writeln('T27 smoke passed: $expected');
}
