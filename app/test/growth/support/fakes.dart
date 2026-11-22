import 'dart:async';

import 'package:high_eq/features/growth/models.dart';
import 'package:high_eq/features/growth/repository.dart';

const testExerciseId = 'exercise-content';
const testCardId = 'card-content';

GrowthSnapshot sampleSnapshot({
  String planTitle = '读人小练习 · 听出弦外之音',
  bool includePlan = true,
  bool includeCards = true,
  bool personalized = true,
  double? trainingReference = 70,
  int validBehaviorCount = 2,
  int streak = 6,
  List<int> achievements = const [3],
  List<AssessmentData>? assessments,
  List<PracticeScoreData>? sessions,
  List<KnowledgeCardData>? cards,
}) {
  final resolvedAssessments =
      assessments ??
      [
        AssessmentData(
          id: 'assessment-latest',
          completedAt: DateTime.utc(2026, 11, 8),
          nextEligibleAt: DateTime.utc(2026, 12, 6),
          dimensions: const {'SEA': 70, 'OEA': 64, 'UOE': 74, 'ROE': 63},
          totalPercent: 68,
        ),
        AssessmentData(
          id: 'assessment-older',
          completedAt: DateTime.utc(2026, 9, 1),
          nextEligibleAt: DateTime.utc(2026, 9, 29),
          dimensions: const {'SEA': 58, 'OEA': 62, 'UOE': 55, 'ROE': 61},
          totalPercent: 59,
        ),
      ];
  final resolvedCards =
      cards ??
      [
        const KnowledgeCardData(
          id: testCardId,
          title: '事实和评价要分开',
          body: '先说可观察的事实，再说感受和需要。',
          scene: 'work',
        ),
        const KnowledgeCardData(
          id: 'card-secondary',
          title: '先确认，再给建议',
          body: '先问对方需要倾听还是一起想办法。',
          scene: 'partner',
        ),
      ];
  return GrowthSnapshot(
    plan: PlanData(
      day: '2026-11-22',
      personalized: personalized,
      items: includePlan
          ? [
              PlanItemData(
                id: 'plan-exercise',
                kind: PlanKind.exercise,
                title: planTitle,
                contentId: testExerciseId,
                completed: false,
              ),
              const PlanItemData(
                id: 'plan-card',
                kind: PlanKind.card,
                title: '知识卡 · 事实和评价要分开',
                contentId: testCardId,
                completed: false,
              ),
              const PlanItemData(
                id: 'plan-level',
                kind: PlanKind.level,
                title: '对练 · 把拒绝说得清楚又不伤人',
                contentId: 'level-content',
                completed: false,
              ),
            ]
          : const [],
    ),
    growth: GrowthData(
      latestAssessment: resolvedAssessments.isEmpty
          ? null
          : resolvedAssessments.first.id,
      wleisPercent: resolvedAssessments.isEmpty
          ? null
          : resolvedAssessments.first.totalPercent,
      trainingReference: trainingReference,
      validBehaviorCount: validBehaviorCount,
      streak: streak,
      achievements: achievements,
    ),
    assessments: resolvedAssessments,
    sessions:
        sessions ??
        const [
          PracticeScoreData(
            sessionId: 'session-latest',
            mode: 'full_session',
            targetItem: null,
            total: 74,
            maximum: 100,
          ),
          PracticeScoreData(
            sessionId: 'session-older',
            mode: 'single_skill',
            targetItem: 'feeling',
            total: 20,
            maximum: 25,
          ),
        ],
    cards: includeCards ? resolvedCards : const [],
  );
}

class FakeGrowthRepository implements GrowthRepository {
  FakeGrowthRepository({
    required this.snapshot,
    this.cachedSnapshot,
    this.loadCompleter,
    List<Completer<GrowthSnapshot>>? loadQueue,
    this.loadError,
    this.cacheError,
    this.exerciseError,
    this.answerError,
    this.cardError,
    this.completeError,
    this.completion = const CompletionData(streak: 7, achievements: [3]),
    this.exerciseData = const ExerciseData(
      id: testExerciseId,
      question: '同事说“随便吧”，但你感觉他并不轻松。下面哪种回应更可能读懂对方？',
      choices: ['那就按我的方案定了。', '我听到你有点顾虑，要不要说说最担心哪一点？', '你每次都这样。'],
    ),
    this.answerData = const AnswerData(
      correct: true,
      explanation: '你保留了对方的字面意思，也用开放问题确认了顾虑。',
    ),
    this.cardData = const KnowledgeCardData(
      id: testCardId,
      title: '事实和评价要分开',
      body: '“你总是迟到”是评价；“这周有两次会议你晚到了十分钟”是事实。',
      scene: 'work',
    ),
  }) : loadQueue = loadQueue ?? [];

  GrowthSnapshot snapshot;
  GrowthSnapshot? cachedSnapshot;
  Completer<GrowthSnapshot>? loadCompleter;
  final List<Completer<GrowthSnapshot>> loadQueue;
  Object? loadError;
  Object? cacheError;
  Object? exerciseError;
  Object? answerError;
  Object? cardError;
  Object? completeError;
  CompletionData completion;
  ExerciseData exerciseData;
  AnswerData answerData;
  KnowledgeCardData cardData;

  int loadCalls = 0;
  int cachedCalls = 0;
  int saveCalls = 0;
  int clearCacheCalls = 0;
  int exerciseCalls = 0;
  int answerCalls = 0;
  int cardCalls = 0;
  int completeCalls = 0;
  GrowthSnapshot? savedSnapshot;

  @override
  Future<GrowthSnapshot> load() {
    loadCalls++;
    if (loadQueue.isNotEmpty) return loadQueue.removeAt(0).future;
    final completer = loadCompleter;
    if (completer != null) return completer.future;
    final error = loadError;
    if (error != null) return Future.error(error);
    return Future.value(snapshot);
  }

  @override
  Future<GrowthSnapshot?> cached() async {
    cachedCalls++;
    final error = cacheError;
    if (error != null) throw error;
    return cachedSnapshot;
  }

  @override
  Future<void> saveCache(GrowthSnapshot snapshot) async {
    saveCalls++;
    savedSnapshot = snapshot;
  }

  @override
  Future<void> clearCache() async {
    clearCacheCalls++;
    cachedSnapshot = null;
  }

  @override
  Future<ExerciseData> exercise(String id) async {
    exerciseCalls++;
    final error = exerciseError;
    if (error != null) throw error;
    return exerciseData;
  }

  @override
  Future<AnswerData> answer(String id, int choiceIndex) async {
    answerCalls++;
    final error = answerError;
    if (error != null) throw error;
    return answerData;
  }

  @override
  Future<KnowledgeCardData> card(String id) async {
    cardCalls++;
    final error = cardError;
    if (error != null) throw error;
    return cardData;
  }

  @override
  Future<CompletionData> complete(String itemId) async {
    completeCalls++;
    final error = completeError;
    if (error != null) throw error;
    snapshot = snapshot.withCompletion(
      itemId,
      completion.streak,
      completion.achievements,
    );
    return completion;
  }
}
