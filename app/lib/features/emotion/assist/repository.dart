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

  Future<Json> _read(AppOp op, {bool Function()? canSend}) async {
    final account = _admission.requireOrdinary();
    void checkRequestCurrent() {
      if (canSend?.call() == false) throw const SummaryRequestCancelled();
      _admission.requireOrdinary(account);
    }

    final result = await api.jsonGuarded(
      op,
      scope: scope,
      beforeSend: () async {},
      checkRequestCurrent: checkRequestCurrent,
      retainSuccessfulRefresh: true,
    );
    checkRequestCurrent();
    return result;
  }
}
