import 'package:flutter/foundation.dart';

import '../../core/api.dart';
import '../../core/app_op.g.dart';
import '../../core/session.dart';
import '../../core/transport.dart';

class PrivacyAccount {
  PrivacyAccount({
    required this.userId,
    required this.timezone,
    required List<String> bindings,
    required this.frozenUntil,
  }) : bindings = List.unmodifiable(bindings);

  final String userId;
  final String timezone;
  final List<String> bindings;
  final DateTime? frozenUntil;

  /// Server state, not the device clock, decides whether closure is pending.
  bool get isFrozen => frozenUntil != null;

  factory PrivacyAccount.fromJson(Json json) {
    final userId = _requiredString(json, 'user_id');
    final timezone = _requiredString(json, 'timezone');
    final rawBindings = json['bindings'];
    if (rawBindings is! List ||
        rawBindings.any((value) => value is! String || value.isEmpty)) {
      throw const FormatException('账号绑定信息异常');
    }
    final rawFrozen = json['frozen_until'];
    if (!json.containsKey('frozen_until') ||
        (rawFrozen != null && rawFrozen is! String)) {
      throw const FormatException('账号冻结信息异常');
    }
    final frozen = rawFrozen == null ? null : parseFreezeDeadline(rawFrozen);
    if (rawFrozen != null && frozen == null) {
      throw const FormatException('账号冻结时间异常');
    }
    return PrivacyAccount(
      userId: userId,
      timezone: timezone,
      bindings: rawBindings.cast<String>(),
      frozenUntil: frozen,
    );
  }
}

// DateTime.parse also accepts date-only values, local times and rollover
// dates. The Account wire field is a date-time with an explicit offset.
final _dateTime = RegExp(
  r'^(\d{4})-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])[Tt]'
  r'(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d+)?'
  r'(?:[Zz]|[+-](?:[01]\d|2[0-3]):[0-5]\d)$',
);

DateTime? parseFreezeDeadline(String value) {
  final match = _dateTime.firstMatch(value);
  if (match == null || match.end != value.length) return null;
  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  if (day > DateTime.utc(year, month + 1, 0).day) return null;
  return DateTime.tryParse(value.toUpperCase());
}

String _requiredString(Json json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) throw FormatException('账号信息异常', key);
  return value;
}

class AccountAdmissionRequired implements Exception {
  const AccountAdmissionRequired();
}

/// One admission record per login lease. A re-read closes ordinary access
/// before any I/O and retains only the last confirmed freeze deadline.
class AccountAccess extends ChangeNotifier {
  AccountAccess._(this._api, this.scope);

  static final _perScope = Expando<AccountAccess>();

  static AccountAccess of(AppApi api, AccountScope scope) =>
      _perScope[scope] ??= AccountAccess._(api, scope);

  final AppApi _api;
  final AccountScope scope;
  bool get _current => identical(scope, _api.sessions.active);
  PrivacyAccount? _account;
  DateTime? _frozenUntil;
  Object? _error;
  Future<PrivacyAccount>? _pending;

  PrivacyAccount? get account => _current ? _account : null;
  DateTime? get frozenUntil => _current ? _frozenUntil : null;
  Object? get error => _current ? _error : null;
  bool get isOrdinary => account?.isFrozen == false;

  Future<PrivacyAccount> ensure() async {
    _api.sessions.require(scope);
    if (_pending case final pending?) return pending;
    if (_account case final confirmed?) return confirmed;
    if (_error case final failure?) throw failure;
    return refresh();
  }

  Future<PrivacyAccount> refresh() {
    _api.sessions.require(scope);
    if (_pending case final pending?) return pending;
    _account = null;
    _error = null;
    final pending = Future<PrivacyAccount>.microtask(_read);
    _pending = pending;
    notifyListeners();
    return pending;
  }

  Future<PrivacyAccount> _read() async {
    try {
      _api.sessions.require(scope);
      final received = PrivacyAccount.fromJson(
        await _api.json(AppOp.getMe, scope: scope),
      );
      _api.sessions.require(scope);
      if (received.userId != scope.account) {
        throw const FormatException('账号信息与当前登录不一致');
      }
      _account = received;
      _frozenUntil = received.frozenUntil;
      return received;
    } catch (error) {
      if (_current) _error = error;
      rethrow;
    } finally {
      _pending = null;
      notifyListeners();
    }
  }

  PrivacyAccount requireOrdinary([PrivacyAccount? expected]) {
    _api.sessions.require(scope);
    final current = _account;
    if (current == null ||
        current.isFrozen ||
        (expected != null && !identical(current, expected))) {
      throw const AccountAdmissionRequired();
    }
    return current;
  }

  Future<Json> ordinaryJson(
    AppOp op,
    PrivacyAccount expected, {
    Map<String, String> path = const {},
    Map<String, String> query = const {},
    Json? body,
    VoidCallback? onDispatch,
  }) => _api.jsonGuarded(
    op,
    scope: scope,
    path: path,
    query: query,
    body: body,
    beforeSend: () async {},
    checkBeforeSend: () {
      requireOrdinary(expected);
      onDispatch?.call();
    },
  );
}
