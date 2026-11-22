import 'dart:convert';
import '../../core/api.dart';
import '../../core/endpoints.g.dart';
import '../../core/session.dart';
import '../../core/transport.dart';
import '../contacts/scene.dart';

class Mark {
  Mark.fromJson(Json j)
    : id = j['id'] as String,
      at = DateTime.parse(j['marked_at'] as String),
      contact = j['contact_id'] as String?,
      scene = j['scene'] == null ? null : Scene.values.byName(j['scene']);
  Mark.fromReview(Map<String, dynamic> seed)
    : this.fromJson({
        ...seed,
        'id': seed['mark_id'],
        'marked_at': seed['occurred_at'],
      });
  final String id;
  final DateTime at;
  final String? contact;
  final Scene? scene;
  Json get review => {
    'mark_id': id,
    'occurred_at': at.toUtc().toIso8601String(),
    'contact_id': ?contact,
    'scene': ?scene?.name,
  };
}

class MarkBook {
  MarkBook(this.api, this.scope) : endpoints = MobileEndpoints(api);
  final AppApi api;
  final AccountScope scope;
  final MobileEndpoints endpoints;
  bool get demo => api.transport is ExampleTransport;
  Future<bool> consented() async {
    String? cursor;
    final seen = <String>{};
    do {
      final p = await endpoints.listConsents(
        scope: scope,
        cursor: cursor,
        limit: 100,
      );
      for (final x in p['items'] as List) {
        if (x['purpose'] == 'manual_mark') return x['granted'] == true;
      }
      cursor = p['next_cursor'];
      if (cursor != null && !seen.add(cursor)) {
        throw const FormatException('分页异常');
      }
    } while (cursor != null);
    return false;
  }

  Future<void> grant() async {
    await endpoints.setConsent(
      scope: scope,
      purpose: 'manual_mark',
      body: {'version': 'v1', 'granted': true},
    );
  }

  Future<Mark> create(String request) async => Mark.fromJson(
    await endpoints.createMark(scope: scope, body: {'request_id': request}),
  );
  Future<({List<Mark> items, String? next})> history([String? cursor]) async {
    final p = await endpoints.listMarks(scope: scope, cursor: cursor);
    return (
      items: [for (final j in p['items']) Mark.fromJson(j)],
      next: p['next_cursor'] as String?,
    );
  }

  Future<Map<String, String>> people() async {
    final names = <String, String>{};
    String? cursor;
    final seen = <String>{};
    do {
      final p = await endpoints.listContacts(
        scope: scope,
        cursor: cursor,
        limit: 100,
      );
      for (final x in p['items']) {
        names[x['id'] as String] = x['nickname'] as String;
      }
      cursor = p['next_cursor'];
      if (cursor != null && !seen.add(cursor)) {
        throw const FormatException('分页异常');
      }
    } while (cursor != null);
    return names;
  }

  Future<Mark> edit(String id, Json fields) async => Mark.fromJson(
    await endpoints.editMark(scope: scope, id: id, body: fields),
  );
  Future<void> remove(String id) async {
    try {
      await endpoints.deleteMark(scope: scope, id: id);
    } on ApiFailure catch (e) {
      // The server may have committed the delete before the response was lost.
      // A subsequent 404 means the desired state is already reached.
      if (e.status != 404) rethrow;
    }
    await api.sessions.remove(scope, CacheKind.draft, 'mark:$id');
  }

  // Keep only a resumable pointer, never a second copy of history or text.
  Future<void> bookmark(Mark m) => api.sessions.put(
    scope,
    CacheKind.draft,
    'mark:${m.id}',
    utf8.encode(m.id),
  );
  Future<bool> bookmarked(Mark m) async =>
      await api.sessions.get(scope, CacheKind.draft, 'mark:${m.id}') != null;
}
