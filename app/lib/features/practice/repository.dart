import 'dart:convert';
import '../../core/api.dart';
import '../../core/endpoints.g.dart';
import '../../core/session.dart';
import '../../core/sse.dart';
import '../../core/transport.dart';
import '../contacts/scene.dart';

const skills = {
  'observation': '观察',
  'feeling': '感受',
  'need': '需要',
  'request': '请求',
};
const safetyHelp =
    '听起来你现在可能正经历很难受的事。这里不适合继续练习，建议你马上联系专业的人：全国心理援助热线 12356；如果有人身危险，请立即拨打 110 或 120。';
const moderationHelp = '服务暂不可用，可重试';
String settlementLabel(Json? ledger) => switch (ledger?['status']) {
  'charged' => '本场净扣 ${ledger!['net_charge']} 次',
  'refunded' => '已退回 ${ledger!['charged_day']} 的额度 · 净扣 0 次',
  'uncharged' => '本场未扣次',
  _ => '正在核对扣次结果',
};
String problem(Object e) {
  if (e is! ApiFailure) return '暂时无法连接，请重试。';
  if (e.status != 429) return e.message;
  final at = e.retryAt?.toLocal();
  if (at == null) return '今日对练剩余 0 次，请在额度重置后再试。';
  final time =
      '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
  return '今日对练剩余 0 次，${at.month} 月 ${at.day} 日 $time 重置（本地时间）。';
}

abstract interface class PracticeRepository {
  Future<bool> practiceConsent();
  Future<void> grantPracticeConsent();
  Future<List<Json>> levels(Scene scene, int? difficulty);
  Future<Json?> findLevel(String id);
  Future<List<Json>> history();
  Future<Json> create(Json body);
  Future<Json> get(String id);
  Stream<ReplyEvent> send(String id, Json body);
  Future<Json> finish(String id);
  Future<Json> exit(String id);
  Future<Json?> read(String key);
  Future<void> remember(String key, Json? value);
}

class ApiPractice implements PracticeRepository {
  final AppApi api;
  final AccountScope scope;
  ApiPractice(this.api, this.scope);
  MobileEndpoints get wire => MobileEndpoints(api);
  Future<List<Json>> _pages(Future<Json> Function(String?) fetch) async {
    final all = <Json>[], seen = <String>{};
    String? cursor;
    do {
      final page = await fetch(cursor);
      all.addAll((page['items'] as List).cast<Json>());
      cursor = page['next_cursor'] as String?;
      if (cursor != null && !seen.add(cursor)) {
        throw const FormatException('分页异常');
      }
    } while (cursor != null);
    return all;
  }

  @override
  Future<List<Json>> levels(Scene scene, int? difficulty) => _pages(
    (c) => wire.listLevels(
      scope: scope,
      cursor: c,
      limit: 100,
      scene: scene.name,
      difficulty: difficulty,
    ),
  );
  @override
  Future<Json?> findLevel(String id) async {
    for (final scene in Scene.values) {
      final rows = await levels(scene, null);
      final match = rows.where((row) => row['id'] == id).firstOrNull;
      if (match != null) return match;
    }
    return null;
  }

  @override
  Future<List<Json>> history() =>
      _pages((c) => wire.listSessions(scope: scope, cursor: c, limit: 100));
  @override
  Future<Json> create(Json body) =>
      wire.createSession(scope: scope, body: body);
  @override
  Future<Json> get(String id) => wire.getSession(scope: scope, sessionId: id);
  @override
  Stream<ReplyEvent> send(String id, Json body) =>
      api.messages(scope, id, body['client_message_id'], body['text']);
  @override
  Future<Json> finish(String id) =>
      wire.finishSession(scope: scope, sessionId: id);
  @override
  Future<Json> exit(String id) => wire.exitSession(scope: scope, sessionId: id);
  @override
  Future<bool> practiceConsent() async {
    final seen = <String>{};
    String? cursor;
    do {
      final page = await wire.listConsents(
        scope: scope,
        cursor: cursor,
        limit: 100,
      );
      for (final item in (page['items'] as List).cast<Json>()) {
        if (item['purpose'] == 'practice') return item['granted'] == true;
      }
      cursor = page['next_cursor'] as String?;
      if (cursor != null && !seen.add(cursor)) {
        throw const FormatException('分页异常');
      }
    } while (cursor != null);
    return false;
  }

  @override
  Future<void> grantPracticeConsent() async {
    final value = await wire.setConsent(
      scope: scope,
      purpose: 'practice',
      body: {'version': 'v1', 'granted': true},
    );
    if (value['purpose'] != 'practice' || value['granted'] != true) {
      throw const FormatException('练习授权未生效');
    }
  }

  @override
  Future<Json?> read(String key) async {
    final bytes = await api.sessions.get(
      scope,
      CacheKind.continuation,
      'practice.$key',
    );
    return bytes == null ? null : jsonDecode(utf8.decode(bytes)) as Json;
  }

  @override
  Future<void> remember(String key, Json? value) => value == null
      ? api.sessions.remove(scope, CacheKind.continuation, 'practice.$key')
      : api.sessions.put(
          scope,
          CacheKind.continuation,
          'practice.$key',
          utf8.encode(jsonEncode(value)),
        );
}
