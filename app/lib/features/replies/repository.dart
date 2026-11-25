import 'dart:convert';
import '../../core/api.dart';
import '../../core/app_op.g.dart';
import '../../core/chat_import_consent.dart';
import '../../core/endpoints.g.dart';
import '../../core/session.dart';
import '../../core/transport.dart';
import '../contacts/models.dart';
import '../contacts/purpose.dart';
import '../contacts/repository.dart';
import 'result.dart';

const _consent = ChatImportConsent.reply;
const replyRequestLimitBytes = 32 << 10;

typedef ReplyQuota = ({int? remaining, DateTime resetsAt});
typedef ReplyContactAccess = ({String consentId, List<Contact> people});
typedef ReplyAuthorization = ({
  String replyConsentId,
  String? contactConsentId,
});

final _decisionId = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

final class ReplyAuthorizationChanged implements Exception {
  const ReplyAuthorizationChanged.reply() : contact = false;
  const ReplyAuthorizationChanged.contact() : contact = true;
  final bool contact;
}

final class ReplyAuthorizationUnavailable implements Exception {
  const ReplyAuthorizationUnavailable.reply() : contact = false;
  const ReplyAuthorizationUnavailable.contact() : contact = true;
  final bool contact;
}

class ReplyInputTooLarge implements Exception {
  const ReplyInputTooLarge();
}

class ReplyContactConsentMissing implements Exception {
  const ReplyContactConsentMissing();
}

bool replyInputFits(Json input) =>
    utf8.encode(jsonEncode(input)).length <= replyRequestLimitBytes;

abstract interface class ReplyRepository {
  Future<bool> allowed();
  Future<String?> replyConsentId();
  Future<void> grant();
  Future<List<Contact>> contacts({bool verifyConsent = false});
  Future<ReplyContactAccess> contactAccess();
  Future<ReplyQuota?> quota();
  Future<ReplyResult> analyze(
    Json input, {
    ReplyAuthorization? authorization,
    void Function()? checkBeforeSend,
  });
  Future<void> feedback(
    String id,
    int index,
    String outcome, [
    String? selfReport,
  ]);
}

class ReplyService implements ReplyRepository {
  ReplyService(this.api, this.scope, {this.book});
  final ContactsRepository? book;
  final AppApi api;
  final AccountScope scope;
  MobileEndpoints get wire => MobileEndpoints(api);
  bool get demo => api.transport is ExampleTransport;
  ContactsRepository get _contacts => book ?? ApiContacts(wire, scope);

  @override
  Future<List<Contact>> contacts({bool verifyConsent = false}) async {
    if (verifyConsent) return (await contactAccess()).people;
    final roster = await _contacts.load();
    // Roster and entitlements are separate reads. An inconsistent snapshot
    // cannot establish that any previously selected contact lost access.
    if (!roster.consistent) {
      throw const ReplyAuthorizationUnavailable.contact();
    }
    return roster.people.where((person) => person.editable).toList();
  }

  @override
  Future<ReplyContactAccess> contactAccess() async {
    final purpose = ContactPurpose.contacts.wire;
    final id = (await _consentIds({purpose: contactNoticeVersion}))[purpose];
    if (id == null) throw const ReplyContactConsentMissing();
    return (consentId: id, people: await contacts());
  }

  @override
  Future<ReplyQuota?> quota() async {
    final data = await wire.getEntitlements(scope: scope);
    final rows = data['allowances'];
    if (rows is! List) throw const FormatException();
    for (final row in rows) {
      if (row is! Json || row['feature'] != 'reply') continue;
      final remaining = row['remaining'];
      final resetsAt = DateTime.tryParse(row['resets_at'] as String? ?? '');
      if ((remaining != null && remaining is! int) || resetsAt == null) {
        throw const FormatException();
      }
      return (remaining: remaining as int?, resetsAt: resetsAt);
    }
    return null;
  }

  @override
  Future<bool> allowed() async => await replyConsentId() != null;

  @override
  Future<String?> replyConsentId() async => (await _consentIds({
    _consent.purpose: _consent.version,
  }))[_consent.purpose];

  Future<Map<String, String>> _consentIds(Map<String, String> versions) async {
    final result = <String, String>{};
    final contactPurpose = ContactPurpose.contacts.wire;
    if (demo) {
      if (versions.containsKey(_consent.purpose)) {
        final data = await api.sessions.get(
          scope,
          CacheKind.continuation,
          'reply.notice',
        );
        if (data != null && utf8.decode(data) == _consent.version) {
          result[_consent.purpose] = _consent.version;
        }
      }
      if (versions.containsKey(contactPurpose)) {
        final current = await _contacts.currentConsents();
        final revision = current.revisionFor(ContactPurpose.contacts);
        if (revision != null) result[contactPurpose] = revision;
      }
      return result;
    }
    String? cursor;
    final seenCursors = <String>{};
    final seenPurposes = <String>{};
    do {
      final page = await wire.listConsents(
        scope: scope,
        cursor: cursor,
        limit: 100,
      );
      for (final row in page['items'] as List) {
        if (row is! Json) throw const FormatException();
        final purpose = row['purpose'];
        if (purpose is! String) throw const FormatException();
        final version = versions[purpose];
        if (version == null) continue;
        if (!seenPurposes.add(purpose)) throw const FormatException();
        if (row['version'] != version || row['granted'] != true) continue;
        final id = row['decision_id'];
        if (id is! String || !_decisionId.hasMatch(id)) {
          throw const FormatException();
        }
        result[purpose] = id;
      }
      cursor = page['next_cursor'];
      if (cursor != null && !seenCursors.add(cursor)) {
        throw const FormatException();
      }
    } while (cursor != null);
    return result;
  }

  Future<ReplyAuthorization> _verifyAuthorization(
    String? contactId,
    ReplyAuthorization? expected,
  ) async {
    final contactPurpose = ContactPurpose.contacts.wire;
    Map<String, String> ids;
    try {
      ids = await _consentIds({
        _consent.purpose: _consent.version,
        if (contactId != null) contactPurpose: contactNoticeVersion,
      });
    } on SessionChanged {
      rethrow;
    } catch (_) {
      throw const ReplyAuthorizationUnavailable.reply();
    }
    api.sessions.require(scope);
    final replyId = ids[_consent.purpose];
    if (replyId == null ||
        (expected != null && expected.replyConsentId != replyId)) {
      throw const ReplyAuthorizationChanged.reply();
    }
    final contactConsentId = ids[contactPurpose];
    if ((contactId != null && contactConsentId == null) ||
        (expected != null && expected.contactConsentId != contactConsentId)) {
      throw const ReplyAuthorizationChanged.contact();
    }
    // End with roster/entitlements, not another consent GET. Separate reads
    // are not atomic: the server validates the submitted IDs and contact
    // entitlement in the transaction that would bind a new key.
    if (contactId != null) {
      List<Contact> people;
      try {
        people = await contacts();
      } on SessionChanged {
        rethrow;
      } catch (_) {
        throw const ReplyAuthorizationUnavailable.contact();
      }
      if (!people.any((person) => person.id == contactId)) {
        throw const ReplyAuthorizationChanged.contact();
      }
    }
    return (replyConsentId: replyId, contactConsentId: contactConsentId);
  }

  @override
  Future<void> grant() async {
    if (demo) {
      await api.sessions.put(
        scope,
        CacheKind.continuation,
        'reply.notice',
        utf8.encode(_consent.version),
      );
      return;
    }
    final row = await wire.setConsent(
      scope: scope,
      purpose: _consent.purpose,
      body: {'granted': true, 'version': _consent.version},
    );
    if (row['purpose'] != _consent.purpose ||
        row['granted'] != true ||
        row['version'] != _consent.version) {
      throw const FormatException();
    }
  }

  @override
  Future<ReplyResult> analyze(
    Json input, {
    ReplyAuthorization? authorization,
    void Function()? checkBeforeSend,
  }) async {
    // Owned by this invocation. The first guard sets the wire IDs before
    // AppApi encodes it; a 401 replay only verifies, never replaces them.
    final body = Map<String, dynamic>.of(input)
      ..remove('reply_consent_id')
      ..remove('contacts_consent_id');
    if (!replyInputFits(body)) throw const ReplyInputTooLarge();
    final contactId = body['contact_id'] as String?;
    var expected = authorization;
    var sealed = false;
    var status = 0;
    final stream = api.bytesGuarded(
      AppOp.createReply,
      beforeSend: () async {
        checkBeforeSend?.call();
        final current = await _verifyAuthorization(contactId, expected);
        if (!sealed) {
          expected ??= current;
          body['reply_consent_id'] = current.replyConsentId;
          if (current.contactConsentId case final id?) {
            body['contacts_consent_id'] = id;
          }
          if (!replyInputFits(body)) throw const ReplyInputTooLarge();
          sealed = true;
        }
      },
      checkBeforeSend: () {
        checkBeforeSend?.call();
        if (input['request_id'] != body['request_id'] ||
            input['chat_text'] != body['chat_text'] ||
            input['goal'] != body['goal'] ||
            input['contact_id'] != contactId) {
          throw const ReplyAuthorizationChanged.reply();
        }
      },
      scope: scope,
      body: body,
      onStatus: (s) => status = s,
    );
    final data = jsonDecode(await stream.transform(utf8.decoder).join());
    api.sessions.require(scope);
    if (data is! Json) return NoResult();
    return decodeReplyResult(status, data, body['request_id']);
  }

  @override
  Future<void> feedback(
    String id,
    int index,
    String outcome, [
    String? selfReport,
  ]) async {
    if ((await wire.rateReply(
          scope: scope,
          id: id,
          body: {
            'index': index,
            'outcome': outcome,
            'self_report': ?selfReport,
          },
        ))['ok'] !=
        true) {
      throw const FormatException();
    }
  }
}
