import 'dart:convert';
import '../../core/api.dart';
import '../../core/endpoints.g.dart';
import '../../core/session.dart';
import '../../core/transport.dart';
import 'score.dart';

const policyVersion = '2026-11';

class AssessmentBook {
  final AppApi api;
  final AccountScope scope;
  AssessmentBook(this.api, this.scope);
  MobileEndpoints get wire => MobileEndpoints(api);
  bool get demo => api.transport is ExampleTransport;
  Future<Json?> read(String key) async {
    final raw = await api.sessions.get(
      scope,
      CacheKind.continuation,
      'assessment.$key',
    );
    return raw == null ? null : jsonDecode(utf8.decode(raw)) as Json;
  }

  Future<void> save(String key, Json value) => api.sessions.put(
    scope,
    CacheKind.continuation,
    'assessment.$key',
    utf8.encode(jsonEncode(value)),
  );
  Future<void> discardDraft() =>
      api.sessions.remove(scope, CacheKind.continuation, 'assessment.draft');
  Future<bool> allowed() async {
    if (demo) return (await read('consent'))?['version'] == policyVersion;
    String? cursor;
    final seen = <String>{};
    do {
      final page = await wire.listConsents(scope: scope, cursor: cursor);
      for (final row in page['items'] as List) {
        if (row['purpose'] == 'assessment') {
          return row['granted'] == true && row['version'] == policyVersion;
        }
      }
      cursor = page['next_cursor'];
      if (cursor != null && !seen.add(cursor)) throw const FormatException();
    } while (cursor != null);
    return false;
  }

  Future<void> grant() async {
    final decision = await wire.setConsent(
      scope: scope,
      purpose: 'assessment',
      body: {'version': policyVersion, 'granted': true},
    );
    if (demo) {
      await save('consent', {'version': policyVersion});
    } else if (decision['purpose'] != 'assessment' ||
        decision['granted'] != true ||
        decision['version'] != policyVersion) {
      throw const FormatException();
    }
  }

  Future<Json?> latest() async {
    if (demo) return read('result');
    // T08 orders by (completed_at, id) descending. This screen is not history.
    final page = await wire.listAssessments(scope: scope, limit: 1);
    return (page['items'] as List).cast<Json>().firstOrNull;
  }

  Future<Json> instrument() async {
    final q = await wire.getInstrument(scope: scope);
    final items = (q['items'] as List).cast<Json>().toList()
      ..sort((a, b) => (a['id'] as int).compareTo(b['id']));
    if (items.length != 16 ||
        (q['options'] as List).length != 7 ||
        q['version'] is! String) {
      throw const FormatException();
    }
    final counts = {for (final dim in abilities.keys) dim: 0};
    for (final (i, item) in items.indexed) {
      final dim = item['dimension'];
      if (item['id'] != i + 1 ||
          !counts.containsKey(dim) ||
          item['zh'] is! String) {
        throw const FormatException();
      }
      counts[dim] = counts[dim]! + 1;
    }
    if (counts.values.any((n) => n != 4)) throw const FormatException();
    return {...q, 'items': items};
  }

  Future<Json> submit(String version, List<int> answers) async {
    if (answers.length != 16 || answers.any((v) => v < 1 || v > 7)) {
      throw const FormatException();
    }
    final response = await wire.submitAssessment(
      scope: scope,
      body: {'version': version, 'answers': answers},
    );
    if (!demo) return response;
    final result = demoScore(answers, DateTime.now());
    await save('result', result);
    return result;
  }
}
