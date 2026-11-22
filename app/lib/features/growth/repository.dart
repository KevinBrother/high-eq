import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/endpoints.g.dart';
import '../../core/providers.dart';
import '../../core/session.dart';
import '../../core/transport.dart';
import '../practice/providers.dart';
import 'demo.dart';
import 'models.dart';

abstract interface class GrowthRepository {
  Future<GrowthSnapshot> load();
  Future<GrowthSnapshot?> cached();
  Future<void> saveCache(GrowthSnapshot snapshot);
  Future<void> clearCache();
  Future<ExerciseData> exercise(String id);
  Future<AnswerData> answer(String id, int choiceIndex);
  Future<KnowledgeCardData> card(String id);
  Future<CompletionData> complete(String itemId);
}

class ApiGrowthRepository implements GrowthRepository {
  ApiGrowthRepository(this.api, this.scope);

  final AppApi api;
  final AccountScope scope;
  MobileEndpoints get _wire => MobileEndpoints(api);
  static const _cacheId = 'growth.snapshot.v1';
  int _cacheGeneration = 0;

  @override
  Future<GrowthSnapshot> load() async {
    final cacheGeneration = _cacheGeneration;
    final outcomes = await Future.wait([
      for (final read in <Future<Json>>[
        _wire.getTodayPlan(scope: scope),
        _wire.getGrowth(scope: scope),
        _wire.listAssessments(scope: scope, limit: 2),
        _loadSessions(),
        _wire.listCards(scope: scope, limit: 20),
      ])
        _captureRead(read),
    ]);
    final failures = outcomes.where((outcome) => outcome.failed).toList();
    if (failures.isNotEmpty) {
      // A parallel ordinary failure must not hide an authorization rejection:
      // the page relies on 401/403 to discard stale sensitive data.
      final failure = failures.reduce(
        (selected, candidate) =>
            _readFailurePriority(candidate.error!) <
                _readFailurePriority(selected.error!)
            ? candidate
            : selected,
      );
      Error.throwWithStackTrace(failure.error!, failure.stackTrace!);
    }
    final responses = [for (final outcome in outcomes) outcome.value!];
    final snapshot = GrowthSnapshot.fromApi(
      plan: responses[0],
      growth: responses[1],
      assessments: responses[2],
      sessions: responses[3],
      cards: responses[4],
    );
    try {
      // A completion may have started while these reads were in flight. In
      // that case this snapshot predates the successful write and must not
      // replace the newer completion cache.
      if (cacheGeneration == _cacheGeneration) await saveCache(snapshot);
    } catch (_) {
      // A successful online read must not be presented as an offline snapshot
      // merely because the encrypted cache is unavailable.
    }
    return snapshot;
  }

  @override
  Future<GrowthSnapshot?> cached() async {
    final bytes = await api.sessions.get(
      scope,
      CacheKind.continuation,
      _cacheId,
    );
    if (bytes == null) return null;
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) throw const FormatException('成长缓存无效');
    return GrowthSnapshot.fromCache(decoded.cast<String, dynamic>());
  }

  @override
  Future<void> saveCache(GrowthSnapshot snapshot) => api.sessions.put(
    scope,
    CacheKind.continuation,
    _cacheId,
    utf8.encode(jsonEncode(snapshot.asCached(DateTime.now()).toJson())),
  );

  @override
  Future<void> clearCache() =>
      api.sessions.remove(scope, CacheKind.continuation, _cacheId);

  Future<Json> _loadSessions() async {
    final rows = <dynamic>[];
    final seen = <String>{};
    String? cursor;
    do {
      final page = await _wire.listSessions(
        scope: scope,
        cursor: cursor,
        limit: 100,
      );
      final items = page['items'];
      if (items is! List) throw const FormatException('对练列表无效');
      rows.addAll(items);
      final next = page['next_cursor'];
      if (next == null) break;
      if (next is! String || next.isEmpty || !seen.add(next)) {
        throw const FormatException('对练分页无效');
      }
      cursor = next;
    } while (true);
    return {'items': rows};
  }

  @override
  Future<ExerciseData> exercise(String id) async =>
      ExerciseData.fromJson(await _wire.getExercise(scope: scope, id: id));

  @override
  Future<AnswerData> answer(String id, int choiceIndex) async =>
      AnswerData.fromJson(
        await _wire.answerExercise(
          scope: scope,
          id: id,
          body: {'choice_index': choiceIndex},
        ),
      );

  @override
  Future<KnowledgeCardData> card(String id) async =>
      KnowledgeCardData.fromJson(await _wire.getCard(scope: scope, id: id));

  @override
  Future<CompletionData> complete(String itemId) async {
    _cacheGeneration++;
    try {
      return CompletionData.fromJson(
        await _wire.completePlanItem(scope: scope, id: itemId),
      );
    } finally {
      // Also invalidate reads that started after this write was dispatched but
      // before its authoritative result became available.
      _cacheGeneration++;
    }
  }
}

class _ReadOutcome {
  const _ReadOutcome.success(Json this.value) : error = null, stackTrace = null;

  const _ReadOutcome.failure(Object this.error, StackTrace this.stackTrace)
    : value = null;

  final Json? value;
  final Object? error;
  final StackTrace? stackTrace;

  bool get failed => error != null;
}

Future<_ReadOutcome> _captureRead(Future<Json> read) async {
  try {
    return _ReadOutcome.success(await read);
  } catch (error, stackTrace) {
    return _ReadOutcome.failure(error, stackTrace);
  }
}

int _readFailurePriority(Object error) {
  if (error is SessionChanged) return 0;
  if (error is ApiFailure && (error.status == 401 || error.status == 403)) {
    return 1;
  }
  return 2;
}

/// One repository survives tab replacement, so demo completion and training
/// state do not disappear while switching between practice and growth. It is
/// rebuilt when the active account changes.
final growthRepositoryProvider = Provider<GrowthRepository?>((ref) {
  final api = ref.watch(apiProvider).requireValue;
  final scope = ref.watch(accountScopeProvider);
  if (scope == null) return null;
  if (api.transport is ExampleTransport) {
    final practice = ref.watch(demoPracticeProvider);
    return DemoGrowthRepository(practice: practice);
  }
  return ApiGrowthRepository(api, scope);
});

String growthProblem(Object error) {
  if (error is SessionChanged) return '账号已切换，请重新打开页面。';
  if (error is ApiFailure) {
    return switch (error.status) {
      401 => '登录凭证无效或已过期，请重新验证。',
      403 => '没有获得所需授权，请重新确认。',
      404 => '这项内容暂时不可用，请稍后再试。',
      409 => '记录有冲突，请刷新后再试。',
      429 => '操作过于频繁，请稍后再试。',
      _ => '服务暂不可用，请稍后重试。',
    };
  }
  return '暂时无法加载，请检查连接后重试。';
}

bool growthAccessDenied(Object error) =>
    error is ApiFailure && (error.status == 401 || error.status == 403);
