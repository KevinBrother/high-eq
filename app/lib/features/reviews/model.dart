import '../../core/transport.dart';
import '../contacts/scene.dart';

class ReviewPrefill {
  const ReviewPrefill({
    required this.markId,
    this.occurredAt,
    this.contactId,
    this.scene,
  });

  /// Adapts the route payload produced by T32A without depending on its model.
  static ReviewPrefill? tryFromRoute(Object? arguments) {
    if (arguments is! Map) return null;
    final markId = arguments['mark_id'];
    if (markId is! String || markId.trim().isEmpty) return null;
    final occurredAt = arguments['occurred_at'];
    final contactId = arguments['contact_id'];
    final sceneName = arguments['scene'];
    Scene? scene;
    if (sceneName is String) {
      for (final value in Scene.values) {
        if (value.name == sceneName) {
          scene = value;
          break;
        }
      }
    }
    return ReviewPrefill(
      markId: markId,
      occurredAt: occurredAt is String ? DateTime.tryParse(occurredAt) : null,
      contactId: contactId is String && contactId.isNotEmpty ? contactId : null,
      scene: scene,
    );
  }

  final String markId;
  final DateTime? occurredAt;
  final String? contactId;
  final Scene? scene;
}

class ReviewDraft {
  const ReviewDraft({
    required this.requestId,
    required this.happened,
    required this.myFeeling,
    required this.theirFeeling,
    required this.myAction,
    required this.nextAction,
    this.possibleAttempts = const [],
    this.contactId,
    this.markId,
    this.scene,
    this.occurredAt,
  });

  factory ReviewDraft.blank({
    required String requestId,
    ReviewPrefill? prefill,
  }) => ReviewDraft(
    requestId: requestId,
    happened: '',
    myFeeling: '',
    theirFeeling: '',
    myAction: '',
    nextAction: '',
    contactId: prefill?.contactId,
    markId: prefill?.markId,
    scene: prefill?.scene,
    occurredAt: prefill?.occurredAt,
  );

  factory ReviewDraft.fromCacheJson(Json json) {
    final draft = ReviewDraft._fromPayload(json);
    final attempts = json['possible_attempts'];
    if (attempts is List) {
      return draft.copyWith(
        possibleAttempts: List.unmodifiable([
          for (final entry in attempts)
            if (entry is Json)
              ReviewDraft._fromPayload(entry)
            else
              throw const FormatException('复盘提交快照无效'),
        ]),
      );
    }
    if (json.containsKey('possible_attempts')) {
      throw const FormatException('复盘提交快照无效');
    }

    // Older caches put a prepared key on the current body and the prior
    // possible request in frozen_attempt. With different keys, either may
    // have reached the server; with the same key, only the frozen body has.
    final attempted = json['attempted'];
    final frozen = json['frozen_attempt'];
    if ((attempted != null && attempted is! bool) ||
        (frozen != null && (frozen is! Json || attempted != true))) {
      throw const FormatException('复盘提交快照无效');
    }
    if (attempted != true) return draft;
    final previous = frozen is Json ? ReviewDraft._fromPayload(frozen) : null;
    return draft.copyWith(
      possibleAttempts: List.unmodifiable([
        ?previous,
        if (previous?.requestId != draft.requestId) draft,
      ]),
    );
  }

  factory ReviewDraft._fromPayload(Json json) {
    String text(String key) {
      final value = json[key];
      if (value is! String) throw const FormatException('复盘草稿字段无效');
      return value;
    }

    final requestId = text('request_id');
    if (requestId.trim().isEmpty) {
      throw const FormatException('复盘请求编号为空');
    }
    final sceneName = json['scene'];
    final occurredAt = json['occurred_at'];
    final contactId = json['contact_id'];
    final markId = json['mark_id'];
    if (sceneName != null && (sceneName is! String || sceneName.isEmpty)) {
      throw const FormatException('复盘场景无效');
    }
    if (occurredAt != null && occurredAt is! String) {
      throw const FormatException('复盘时间无效');
    }
    if (contactId != null && (contactId is! String || contactId.isEmpty)) {
      throw const FormatException('复盘关系人无效');
    }
    if (markId != null && (markId is! String || markId.isEmpty)) {
      throw const FormatException('复盘标记无效');
    }
    try {
      return ReviewDraft(
        requestId: requestId,
        happened: text('happened'),
        myFeeling: text('my_feeling'),
        theirFeeling: text('their_possible_feeling'),
        myAction: text('my_action'),
        nextAction: text('next_action'),
        contactId: contactId as String?,
        markId: markId as String?,
        scene: sceneName == null ? null : Scene.values.byName(sceneName),
        occurredAt: occurredAt == null ? null : DateTime.parse(occurredAt),
      );
    } on ArgumentError {
      throw const FormatException('复盘草稿无效');
    } on FormatException {
      throw const FormatException('复盘草稿无效');
    }
  }

  factory ReviewDraft.fromJson(Json json) {
    final draft = ReviewDraft._fromPayload(json);
    if ([
      draft.happened,
      draft.myFeeling,
      draft.theirFeeling,
      draft.myAction,
      draft.nextAction,
    ].any((value) => value.trim().isEmpty)) {
      throw const FormatException('复盘草稿不完整');
    }
    return draft;
  }

  final String requestId;
  final String happened;
  final String myFeeling;
  final String theirFeeling;
  final String myAction;
  final String nextAction;
  // Flat snapshots: each binds a possibly sent request ID to its payload.
  final List<ReviewDraft> possibleAttempts;
  final String? contactId;
  final String? markId;
  final Scene? scene;
  final DateTime? occurredAt;

  ReviewDraft copyWith({
    String? requestId,
    List<ReviewDraft>? possibleAttempts,
  }) => ReviewDraft(
    requestId: requestId ?? this.requestId,
    happened: happened,
    myFeeling: myFeeling,
    theirFeeling: theirFeeling,
    myAction: myAction,
    nextAction: nextAction,
    possibleAttempts: possibleAttempts ?? this.possibleAttempts,
    contactId: contactId,
    markId: markId,
    scene: scene,
    occurredAt: occurredAt,
  );

  Json toWire() => {
    'request_id': requestId,
    'happened': happened,
    'my_feeling': myFeeling,
    'their_possible_feeling': theirFeeling,
    'my_action': myAction,
    'next_action': nextAction,
    'contact_id': ?contactId,
    'mark_id': ?markId,
    'scene': ?scene?.name,
    'occurred_at': ?occurredAt?.toUtc().toIso8601String(),
  };

  Json toCacheJson() => {
    ...toWire(),
    'possible_attempts': [
      for (final attempt in possibleAttempts) attempt.toWire(),
    ],
  };

  bool sameSubmission(ReviewDraft other) {
    String normalized(String value) => value.trim();
    String? occurredAtWire(DateTime? value) => value?.toUtc().toIso8601String();
    return normalized(happened) == normalized(other.happened) &&
        normalized(myFeeling) == normalized(other.myFeeling) &&
        normalized(theirFeeling) == normalized(other.theirFeeling) &&
        normalized(myAction) == normalized(other.myAction) &&
        normalized(nextAction) == normalized(other.nextAction) &&
        contactId == other.contactId &&
        markId == other.markId &&
        scene == other.scene &&
        occurredAtWire(occurredAt) == occurredAtWire(other.occurredAt);
  }
}

sealed class ReviewAttempt {
  const ReviewAttempt();
}

class ReviewProcessing extends ReviewAttempt {
  const ReviewProcessing();
}

class ReviewSafety extends ReviewAttempt {
  const ReviewSafety(this.message);
  final String message;
}

class ReviewReady extends ReviewAttempt {
  const ReviewReady(this.record);
  final ReviewRecord record;
}

class ReviewRecord {
  const ReviewRecord({
    required this.id,
    required this.submitted,
    required this.score,
    required this.repairPhrase,
  });

  factory ReviewRecord.fromJson(Json json) {
    final id = json['id'];
    final submitted = json['submitted'];
    final score = json['score'];
    final repair = json['repair_phrase'];
    if (id is! String ||
        id.trim().isEmpty ||
        submitted is! Json ||
        score is! Json ||
        repair is! String ||
        repair.trim().isEmpty) {
      throw const FormatException('复盘结果不完整');
    }
    return ReviewRecord(
      id: id,
      submitted: ReviewDraft.fromJson(submitted),
      score: ReviewScore.fromJson(score),
      repairPhrase: repair,
    );
  }

  final String id;
  final ReviewDraft submitted;
  final ReviewScore score;
  final String repairPhrase;
}

class ScoreLine {
  const ScoreLine({required this.score, required this.reason});
  final int score;
  final String reason;
}

class LevelLine {
  const LevelLine({required this.level, required this.reason});
  final int level;
  final String reason;
}

class ReviewScore {
  const ReviewScore({
    required this.scoreId,
    required this.total,
    required this.observation,
    required this.feeling,
    required this.need,
    required this.request,
    required this.readOthers,
    required this.selfManagement,
    required this.relationship,
    required this.betterVersion,
    required this.whyBetter,
  });

  factory ReviewScore.fromJson(Json json) {
    ScoreLine scoreLine(Json source, String key) {
      final value = source[key];
      if (value is! Json) throw const FormatException('评分为空');
      final score = value['score'];
      final reason = value['reason'];
      if (score is! int ||
          score < 0 ||
          score > 25 ||
          reason is! String ||
          reason.trim().isEmpty) {
        throw const FormatException('评分无效');
      }
      return ScoreLine(score: score, reason: reason);
    }

    LevelLine levelLine(Json source, String key) {
      final value = source[key];
      if (value is! Json) throw const FormatException('情绪评分为空');
      final level = value['level'];
      final reason = value['reason'];
      if (level is! int ||
          level < 1 ||
          level > 5 ||
          reason is! String ||
          reason.trim().isEmpty) {
        throw const FormatException('情绪评分无效');
      }
      return LevelLine(level: level, reason: reason);
    }

    final scoreId = json['score_id'];
    final nvc = json['nvc'];
    final emotion = json['emotion'];
    final better = json['better_version'];
    final why = json['why_better'];
    if (scoreId is! String ||
        nvc is! Json ||
        emotion is! Json ||
        better is! String ||
        why is! String ||
        why.trim().isEmpty) {
      throw const FormatException('评分结果不完整');
    }
    final total = nvc['total'];
    if (total is! int || total < 0 || total > 100) {
      throw const FormatException('总分无效');
    }
    return ReviewScore(
      scoreId: scoreId,
      total: total,
      observation: scoreLine(nvc, 'observation'),
      feeling: scoreLine(nvc, 'feeling'),
      need: scoreLine(nvc, 'need'),
      request: scoreLine(nvc, 'request'),
      readOthers: levelLine(emotion, 'read_others'),
      selfManagement: levelLine(emotion, 'self_management'),
      relationship: levelLine(emotion, 'relationship'),
      betterVersion: better,
      whyBetter: why,
    );
  }

  final String scoreId;
  final int total;
  final ScoreLine observation, feeling, need, request;
  final LevelLine readOthers, selfManagement, relationship;
  final String betterVersion, whyBetter;
}

class ReviewPerson {
  const ReviewPerson({required this.id, required this.name});
  final String id, name;
}

class ReviewHistoryPage {
  const ReviewHistoryPage({required this.items, required this.next});
  final List<ReviewRecord> items;
  final String? next;
}

ReviewAttempt decodeReviewAttempt(int status, Json value, String requestId) {
  if (status == 202 &&
      value.length == 2 &&
      value['request_id'] == requestId &&
      value['status'] == 'in_progress') {
    return const ReviewProcessing();
  }
  if (status != 200) throw const FormatException('复盘响应状态无效');
  if (value.length == 2 &&
      value['safety'] == true &&
      value['message'] is String &&
      (value['message'] as String).trim().isNotEmpty) {
    return ReviewSafety(value['message'] as String);
  }
  final record = ReviewRecord.fromJson(value);
  if (record.submitted.requestId != requestId) {
    throw const FormatException('复盘请求不匹配');
  }
  return ReviewReady(record);
}
