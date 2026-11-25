import '../../../core/api.dart';
import '../../../core/app_op.g.dart';
import '../../../core/session.dart';
import '../../../core/transport.dart';
import '../../privacy/account_access.dart';
import 'models.dart';

class SummaryRequestCancelled implements Exception {
  const SummaryRequestCancelled();
}

abstract interface class AssistRepository {
  Future<AssistAccess> access({bool Function()? canSend});
  Future<List<EmotionGroup>> summary({bool Function()? canSend});
  Future<BaselineProgress> baselineProgress({bool Function()? canSend});
}

class ApiAssistRepository implements AssistRepository {
  ApiAssistRepository(this.api, this.scope)
    : _admission = AccountAccess.of(api, scope);

  final AppApi api;
  final AccountScope scope;
  final AccountAccess _admission;

  @override
  Future<AssistAccess> access({bool Function()? canSend}) async =>
      AssistAccess.fromJson(
        await _read(AppOp.getEntitlements, canSend: canSend),
      );

  @override
  Future<List<EmotionGroup>> summary({bool Function()? canSend}) async =>
      emotionSummaryFromJson(
        await _read(AppOp.emotionSummary, canSend: canSend),
      );

  @override
  Future<BaselineProgress> baselineProgress({bool Function()? canSend}) async {
    final before = await _consentGrants(canSend);
    if (before['health'] != true && before['voice'] != true) {
      return const BaselineProgress();
    }

    final baselines = await _read(AppOp.getBaselines, canSend: canSend);
    // The aggregate endpoint is not purpose-scoped. Re-read consent after the
    // response so a withdrawal committed while it was in flight cannot surface
    // stale rows; require both reads to agree before showing a signal.
    final after = await _consentGrants(canSend);
    final healthGranted = before['health'] == true && after['health'] == true;
    final voiceGranted = before['voice'] == true && after['voice'] == true;
    if (!healthGranted && !voiceGranted) return const BaselineProgress();

    return BaselineProgress.fromJson(
      baselines,
      healthGranted: healthGranted,
      voiceGranted: voiceGranted,
    );
  }

  Future<Map<String, bool>> _consentGrants(bool Function()? canSend) async {
    final decisions = api.sessions.consentVersions();
    final grants = <String, bool>{};
    final seenCursors = <String>{};
    String? cursor;
    do {
      final page = await _read(
        AppOp.listConsents,
        query: {'cursor': ?cursor},
        canSend: canSend,
      );
      final items = page['items'];
      if (items is! List) throw const FormatException('无效的授权清单');
      for (final item in items) {
        if (item is! Map || item['purpose'] is! String) {
          throw const FormatException('无效的授权记录');
        }
        final purpose = item['purpose'] as String;
        if (purpose != 'health' && purpose != 'voice') continue;
        final granted = item['granted'];
        if (granted is! bool || grants.containsKey(purpose)) {
          throw const FormatException('无效的采集授权状态');
        }
        grants[purpose] = granted;
      }
      final next = page['next_cursor'];
      if (next == null) break;
      if (next is! String || next.isEmpty || !seenCursors.add(next)) {
        throw const FormatException('无效的授权清单游标');
      }
      cursor = next;
    } while (true);
    for (final entry in grants.entries) {
      if (entry.value) continue;
      // Drop the observation when a newer local decision landed mid-read.
      api.sessions.noteObservedWithdrawal(
        scope,
        entry.key,
        decisions[entry.key] ?? 0,
      );
    }
    return grants;
  }

  Future<Json> _read(
    AppOp op, {
    Map<String, String> query = const {},
    bool Function()? canSend,
  }) async {
    final account = _admission.requireOrdinary();
    void checkRequestCurrent() {
      if (canSend?.call() == false) throw const SummaryRequestCancelled();
      _admission.requireOrdinary(account);
    }

    final result = await api.jsonGuarded(
      op,
      scope: scope,
      query: query,
      beforeSend: () async {},
      checkRequestCurrent: checkRequestCurrent,
      retainSuccessfulRefresh: true,
    );
    checkRequestCurrent();
    return result;
  }
}
