import '../../core/api.dart';
import '../../core/app_op.g.dart';
import '../../core/endpoints.g.dart';
import '../../core/session.dart';
import '../../core/transport.dart';
import '../onboarding/login.dart' show vendorChannel;
import 'account_access.dart';

const privacyAppleSubscriptionReminder = '请先在苹果设置取消订阅';
const _platformProviders = {'apple', 'wechat'};
final _phonePattern = RegExp(r'^\+[1-9][0-9]{7,14}$');
final _codePattern = RegExp(r'^[0-9]{6}$');

class PrivacyFailure implements Exception {
  const PrivacyFailure(this.message);

  final String message;
}

class ClosureUnconfirmed implements Exception {
  const ClosureUnconfirmed();
}

typedef ClosureSubmission = ({
  DateTime deadline,
  LogoutRound round,
  bool localCleanupConfirmed,
});

class PrivacyStore {
  PrivacyStore(this.api, this.scope);

  final AppApi api;
  final AccountScope scope;
  AccountAccess get admission => AccountAccess.of(api, scope);
  MobileEndpoints get _wire => MobileEndpoints(api);

  String normalizePhone(String phone) {
    final value = phone.trim();
    if (!_phonePattern.hasMatch(value)) {
      throw const PrivacyFailure('请输入带国家区号的手机号。');
    }
    return value;
  }

  Future<void> requestPhoneCode(String phone) async {
    final value = normalizePhone(phone);
    final expected = admission.requireOrdinary();
    await api.jsonGuarded(
      AppOp.requestCode,
      scope: scope,
      beforeSend: () async {},
      checkBeforeSend: () => admission.requireOrdinary(expected),
      body: {'phone': value},
    );
  }

  Json phoneCredential({required String phone, required String code}) {
    final value = normalizePhone(phone);
    final proof = code.trim();
    if (!_codePattern.hasMatch(proof)) {
      throw const PrivacyFailure('请输入 6 位数字验证码。');
    }
    return {'provider': 'phone', 'proof': proof, 'phone': value};
  }

  Future<Json> platformCredential(String provider) async {
    final expected = admission.requireOrdinary();
    if (!_platformProviders.contains(provider)) {
      throw const PrivacyFailure('请选择已绑定的 Apple 或微信账号。');
    }
    final proof = api.transport is ExampleTransport
        ? 'contract-only'
        : await vendorChannel.invokeMethod<String>('authorize', {
            'provider': provider,
          });
    admission.requireOrdinary(expected);
    if (proof == null || proof.isEmpty) {
      throw const PrivacyFailure('身份验证未完成，请重试。');
    }
    return {'provider': provider, 'proof': proof};
  }

  Future<PrivacyAccount> updateTimezone(String timezone) async {
    final value = timezone.trim();
    if (value.isEmpty) throw const PrivacyFailure('时区不能为空。');
    final expected = admission.requireOrdinary();
    final corrected = PrivacyAccount.fromJson(
      await admission.ordinaryJson(
        AppOp.updateMe,
        expected,
        body: {'timezone': value},
      ),
    );
    if (corrected.userId != scope.account ||
        corrected.isFrozen ||
        corrected.timezone != value) {
      throw const PrivacyFailure('更正结果未确认，请重新读取账号资料。');
    }
    final account = await admission.refresh();
    if (account.isFrozen || account.timezone != value) {
      throw const PrivacyFailure('更正结果未确认，请重新读取账号资料。');
    }
    return account;
  }

  Future<ClosureSubmission> freezeAccount({required Json proof}) async {
    final expected = admission.requireOrdinary();
    if (!expected.bindings.contains(proof['provider'])) {
      throw const PrivacyFailure('请选择当前账号已绑定的认证方式。');
    }
    var dispatched = false;
    final Json result;
    try {
      result = await admission.ordinaryJson(
        AppOp.freezeAccount,
        expected,
        body: {'proof': proof},
        onDispatch: () => dispatched = true,
      );
    } catch (error) {
      if (!dispatched || (error is ApiFailure && error.status < 500)) rethrow;
      throw const ClosureUnconfirmed();
    }
    final raw = result['frozen_until'];
    final deadline = raw is String ? parseFreezeDeadline(raw) : null;
    if (deadline == null) throw const ClosureUnconfirmed();

    // Freeze revoked every server session. Use the existing account
    // retirement transaction without sending a second logout or withdrawal.
    final (:round, :cleanup) = api.sessions.beginLogout(scope);
    final local = await cleanup;
    return (
      deadline: deadline,
      round: round,
      localCleanupConfirmed: local.error == null,
    );
  }

  Future<void> cancelClosure() async {
    if (admission.frozenUntil == null) throw const AccountAdmissionRequired();
    final receipt = await _wire.cancelClosure(scope: scope);
    if (receipt.length != 1 || receipt['ok'] != true) {
      throw const FormatException('注销撤销回执异常');
    }
  }
}
