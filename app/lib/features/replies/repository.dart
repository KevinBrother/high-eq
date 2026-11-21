import 'dart:convert';
import '../../core/api.dart';
import '../../core/app_op.g.dart';
import '../../core/endpoints.g.dart';
import '../../core/session.dart';
import '../../core/transport.dart';
import '../contacts/models.dart';
import '../contacts/repository.dart';
import 'result.dart';

const _version = '2026-11';
const replyRequestLimitBytes = 32 << 10;

typedef ReplyQuota = ({int? remaining, DateTime resetsAt});

class ReplyInputTooLarge implements Exception {
  const ReplyInputTooLarge();
}

bool replyInputFits(Json input) =>
    utf8.encode(jsonEncode(input)).length <= replyRequestLimitBytes;

abstract interface class ReplyRepository {
  Future<bool> allowed();
  Future<void> grant();
  Future<List<Contact>> contacts();
  Future<ReplyQuota?> quota();
  Future<ReplyResult> analyze(Json input);
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
  @override
  Future<List<Contact>> contacts() async {
    final people = await (book ?? ApiContacts(wire, scope)).load();
    return people.people.where(people.usable).toList();
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
  Future<bool> allowed() async {
    if (demo) {
      final data = await api.sessions.get(
        scope,
        CacheKind.continuation,
        'reply.notice',
      );
      return data != null && utf8.decode(data) == _version;
    }
    String? cursor;
    final seen = <String>{};
    do {
      final page = await wire.listConsents(scope: scope, cursor: cursor);
      for (final row in page['items'] as List) {
        if (row['purpose'] == 'chat_import') {
          return row['granted'] == true && row['version'] == _version;
        }
      }
      cursor = page['next_cursor'];
      if (cursor != null && !seen.add(cursor)) throw const FormatException();
    } while (cursor != null);
    return false;
  }

  @override
  Future<void> grant() async {
    if (demo) {
      await api.sessions.put(
        scope,
        CacheKind.continuation,
        'reply.notice',
        utf8.encode(_version),
      );
      return;
    }
    final row = await wire.setConsent(
      scope: scope,
      purpose: 'chat_import',
      body: {'granted': true, 'version': _version},
    );
    if (row['purpose'] != 'chat_import' ||
        row['granted'] != true ||
        row['version'] != _version) {
      throw const FormatException();
    }
  }

  @override
  Future<ReplyResult> analyze(Json input) async {
    if (!replyInputFits(input)) throw const ReplyInputTooLarge();
    var status = 0;
    final stream = api.bytes(
      AppOp.createReply,
      scope: scope,
      body: input,
      onStatus: (s) => status = s,
    );
    final data = jsonDecode(await stream.transform(utf8.decoder).join());
    api.sessions.require(scope);
    if (data is! Json) return NoResult();
    return decodeReplyResult(status, data, input['request_id']);
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
