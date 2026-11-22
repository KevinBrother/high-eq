import 'dart:convert';

import '../../core/api.dart';
import '../../core/app_op.g.dart';
import '../../core/endpoints.g.dart';
import '../../core/session.dart';
import '../../core/transport.dart';
import '../contacts/scene.dart';
import 'model.dart';

abstract interface class ReviewRepository {
  Future<ReviewDraft?> loadDraft();
  Future<void> saveDraft(ReviewDraft draft);
  Future<void> discardDraft(ReviewDraft submitted);
  Future<ReviewAttempt> submit(ReviewDraft draft);
  Future<ReviewHistoryPage> history({
    String? cursor,
    int limit = 20,
    Scene? scene,
    String? contactId,
  });
  Future<List<ReviewPerson>> people();
}

/// Optional capability kept separate so pure component fakes need no consent
/// transport. The production repository always implements it.
abstract interface class ReviewConsent {
  Future<bool> allowed();
  Future<void> grant();
}

class ApiReviews implements ReviewRepository, ReviewConsent {
  ApiReviews(this.api, this.scope) : _wire = MobileEndpoints(api);

  static const _draftId = 'review.form';
  static const _consentVersion = 'v1';
  static final _draftTails = <String, Future<void>>{};

  final AppApi api;
  final AccountScope scope;
  final MobileEndpoints _wire;

  Future<T> _draftOperation<T>(Future<T> Function() action) {
    final tail = _draftTails[scope.account] ?? Future.value();
    final next = tail.then((_) => action());
    _draftTails[scope.account] = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  Future<ReviewDraft?> _readDraft() async {
    final bytes = await api.sessions.get(scope, CacheKind.draft, _draftId);
    if (bytes == null) return null;
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Json) throw const FormatException('复盘草稿无效');
    return ReviewDraft.fromCacheJson(value);
  }

  @override
  Future<ReviewDraft?> loadDraft() => _draftOperation(_readDraft);

  @override
  Future<void> saveDraft(ReviewDraft draft) => _draftOperation(
    () => api.sessions.put(
      scope,
      CacheKind.draft,
      _draftId,
      utf8.encode(jsonEncode(draft.toCacheJson())),
    ),
  );

  @override
  Future<void> discardDraft(ReviewDraft submitted) => _draftOperation(() async {
    final current = await _readDraft();
    if (current == null ||
        current.requestId != submitted.requestId ||
        !current.sameSubmission(submitted)) {
      return;
    }
    await api.sessions.remove(scope, CacheKind.draft, _draftId);
  });

  @override
  Future<bool> allowed() async {
    String? cursor;
    final seen = <String>{};
    do {
      final page = await _wire.listConsents(
        scope: scope,
        cursor: cursor,
        limit: 100,
      );
      final rows = page['items'];
      if (rows is! List) throw const FormatException('授权记录无效');
      for (final row in rows) {
        if (row is! Json) throw const FormatException('授权记录无效');
        if (row['purpose'] == 'review') {
          return row['granted'] == true && row['version'] == _consentVersion;
        }
      }
      final next = page['next_cursor'];
      if (next is! String?) throw const FormatException('授权分页无效');
      cursor = next;
      if (cursor != null && !seen.add(cursor)) {
        throw const FormatException('授权分页异常');
      }
    } while (cursor != null);
    return false;
  }

  @override
  Future<void> grant() async {
    final row = await _wire.setConsent(
      scope: scope,
      purpose: 'review',
      body: {'granted': true, 'version': _consentVersion},
    );
    if (row['purpose'] != 'review' ||
        row['granted'] != true ||
        row['version'] != _consentVersion) {
      throw const FormatException('复盘授权未确认');
    }
  }

  @override
  Future<ReviewAttempt> submit(ReviewDraft draft) async {
    var status = 0;
    final payload = await api
        .bytes(
          AppOp.createReview,
          scope: scope,
          body: draft.toWire(),
          onStatus: (value) => status = value,
        )
        .transform(utf8.decoder)
        .join();
    api.sessions.require(scope);
    final value = jsonDecode(payload);
    if (value is! Json) throw const FormatException('复盘响应无效');
    return decodeReviewAttempt(status, value, draft.requestId);
  }

  @override
  Future<ReviewHistoryPage> history({
    String? cursor,
    int limit = 20,
    Scene? scene,
    String? contactId,
  }) async {
    final page = await _wire.listReviews(
      scope: scope,
      cursor: cursor,
      limit: limit,
      scene: scene?.name,
      contactId: contactId,
    );
    final rows = page['items'];
    final next = page['next_cursor'];
    if (rows is! List || next is! String?) {
      throw const FormatException('复盘列表无效');
    }
    final items = <ReviewRecord>[];
    for (final row in rows) {
      if (row is! Json) throw const FormatException('复盘记录无效');
      items.add(ReviewRecord.fromJson(row));
    }
    return ReviewHistoryPage(items: items, next: next);
  }

  @override
  Future<List<ReviewPerson>> people() async {
    final result = <ReviewPerson>[];
    final seenCursors = <String>{};
    String? cursor;
    do {
      final page = await _wire.listContacts(
        scope: scope,
        cursor: cursor,
        limit: 100,
      );
      final rows = page['items'];
      if (rows is! List) throw const FormatException('关系人列表无效');
      for (final row in rows) {
        if (row is! Json ||
            row['id'] is! String ||
            row['nickname'] is! String) {
          throw const FormatException('关系人信息无效');
        }
        result.add(
          ReviewPerson(
            id: row['id'] as String,
            name: row['nickname'] as String,
          ),
        );
      }
      final next = page['next_cursor'];
      if (next is! String?) throw const FormatException('关系人分页无效');
      cursor = next;
      if (cursor != null && !seenCursors.add(cursor)) {
        throw const FormatException('关系人分页异常');
      }
    } while (cursor != null);
    return result;
  }
}
