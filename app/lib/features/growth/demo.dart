import '../practice/demo.dart';
import 'models.dart';
import 'repository.dart';

/// Account-lifetime synthetic contract examples. Nothing here is persisted or
/// sent to a server; it exists so T27 can be exercised before T26 is ready.
class DemoGrowthRepository implements GrowthRepository {
  DemoGrowthRepository({this.practice}) {
    final now = DateTime.now();
    final exerciseId = '85b72033-9f07-4bbc-8567-fc31f26508a1';
    final cardId = '85b72033-9f07-4bbc-8567-fc31f26508a2';
    _plan = PlanData(
      day: now.toIso8601String().substring(0, 10),
      personalized: true,
      items: [
        PlanItemData(
          id: '85b72033-9f07-4bbc-8567-fc31f26508b1',
          kind: PlanKind.exercise,
          title: '读人小练习 · 听出弦外之音',
          contentId: exerciseId,
          completed: false,
        ),
        PlanItemData(
          id: '85b72033-9f07-4bbc-8567-fc31f26508b2',
          kind: PlanKind.card,
          title: '知识卡 · 事实和评价要分开',
          contentId: cardId,
          completed: false,
        ),
        PlanItemData(
          id: '85b72033-9f07-4bbc-8567-fc31f26508b3',
          kind: PlanKind.level,
          title: '对练 · 把拒绝说得清楚又不伤人',
          contentId: demoPlanLevelId,
          completed: false,
        ),
      ],
    );
    _growth = GrowthData(
      latestAssessment: '85b72033-9f07-4bbc-8567-fc31f26508c1',
      wleisPercent: 68,
      trainingReference: 70,
      validBehaviorCount: 2,
      streak: 6,
      achievements: const [3],
    );
    _assessments = [
      AssessmentData(
        id: '85b72033-9f07-4bbc-8567-fc31f26508c1',
        completedAt: now.subtract(const Duration(days: 14)),
        nextEligibleAt: now.add(const Duration(days: 14)),
        dimensions: const {'SEA': 70, 'OEA': 64, 'UOE': 74, 'ROE': 63},
        totalPercent: 68,
      ),
      AssessmentData(
        id: '85b72033-9f07-4bbc-8567-fc31f26508c2',
        completedAt: now.subtract(const Duration(days: 70)),
        nextEligibleAt: now.subtract(const Duration(days: 42)),
        dimensions: const {'SEA': 58, 'OEA': 62, 'UOE': 55, 'ROE': 61},
        totalPercent: 59,
      ),
    ];
    _sessions = const [
      PracticeScoreData(
        sessionId: '85b72033-9f07-4bbc-8567-fc31f26508d1',
        mode: 'full_session',
        targetItem: null,
        total: 74,
        maximum: 100,
      ),
      PracticeScoreData(
        sessionId: '85b72033-9f07-4bbc-8567-fc31f26508d2',
        mode: 'single_skill',
        targetItem: 'feeling',
        total: 20,
        maximum: 25,
      ),
      PracticeScoreData(
        sessionId: '85b72033-9f07-4bbc-8567-fc31f26508d3',
        mode: 'full_session',
        targetItem: null,
        total: 66,
        maximum: 100,
      ),
    ];
    _cards = const [
      KnowledgeCardData(
        id: '85b72033-9f07-4bbc-8567-fc31f26508a2',
        title: '事实和评价要分开',
        body: '“你总是迟到”是评价；“这周有两次会议你晚到了十分钟”是事实。先说可观察的事实，再说感受和需要，对方更不容易进入防御。',
        scene: 'work',
      ),
      KnowledgeCardData(
        id: '85b72033-9f07-4bbc-8567-fc31f26508a3',
        title: '先确认，再给建议',
        body: '当对方情绪很高时，先问一句“你现在更需要我听一听，还是一起想办法？”确认需要后，再给建议。',
        scene: 'partner',
      ),
    ];
    _exercise = ExerciseData(
      id: exerciseId,
      question: '同事说“随便吧”，但你感觉他并不轻松。下面哪种回应更可能读懂对方？',
      choices: const [
        '那就按我的方案定了。',
        '我听到你说随便，但好像还有点顾虑。要不要说说你最担心哪一点？',
        '你每次都这样，有话就直说。',
      ],
    );
  }

  final DemoPractice? practice;
  late PlanData _plan;
  late GrowthData _growth;
  late List<AssessmentData> _assessments;
  late List<PracticeScoreData> _sessions;
  late List<KnowledgeCardData> _cards;
  late ExerciseData _exercise;

  GrowthSnapshot get _snapshot => GrowthSnapshot(
    plan: _plan,
    growth: _growth,
    assessments: _assessments,
    sessions: _sessions,
    cards: _cards,
  );

  @override
  Future<GrowthSnapshot> load() async {
    final practice = this.practice;
    if (practice != null && practice.completedLevel(demoPlanLevelId)) {
      final item = _plan.items
          .where(
            (item) =>
                item.kind == PlanKind.level &&
                item.contentId == demoPlanLevelId,
          )
          .firstOrNull;
      if (item != null && !item.completed) _plan = _plan.complete(item.id);
    }
    return _snapshot;
  }

  @override
  Future<GrowthSnapshot?> cached() async => null;

  @override
  Future<void> saveCache(GrowthSnapshot snapshot) async {
    _plan = snapshot.plan;
    _growth = snapshot.growth;
  }

  @override
  Future<void> clearCache() async {}

  @override
  Future<ExerciseData> exercise(String id) async {
    if (id != _exercise.id) throw const FormatException('练习不存在');
    return _exercise;
  }

  @override
  Future<AnswerData> answer(String id, int choiceIndex) async {
    if (id != _exercise.id || choiceIndex < 0 || choiceIndex >= 3) {
      throw const FormatException('选项无效');
    }
    return AnswerData(
      correct: choiceIndex == 1,
      explanation: choiceIndex == 1
          ? '你保留了对方“随便”的字面意思，也用开放问题确认了顾虑，没有替对方下结论。'
          : '这句话很快进入了评价或决定。先描述你听见的内容，再邀请对方补充，会更容易读懂真实需要。',
    );
  }

  @override
  Future<KnowledgeCardData> card(String id) async {
    final found = _cards.where((item) => item.id == id).firstOrNull;
    if (found == null) throw const FormatException('知识卡不存在');
    return found;
  }

  @override
  Future<CompletionData> complete(String itemId) async {
    if (!_plan.items.any((item) => item.id == itemId)) {
      throw const FormatException('计划项不存在');
    }
    _plan = _plan.complete(itemId);
    final achievements = _plan.items.every((item) => item.completed)
        ? const [3, 7]
        : const [3, 7];
    _growth = _growth.withCompletion(7, achievements);
    return CompletionData(streak: 7, achievements: achievements);
  }
}
