import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'app_op.g.dart';
import 'session.dart';
import 'sse.dart';
import 'transport.dart';

class ApiFailure implements Exception {
  final String code, message;
  final bool? retryable;
  final int status;
  final DateTime? retryAt;
  final AppOp? operation;
  const ApiFailure(
    this.status,
    this.code,
    this.message,
    this.retryable, [
    this.retryAt,
    this.operation,
  ]);
}

enum LogoutStatus { confirmed, unconfirmed }

enum LogoutHealthStatus {
  /// There was no local evidence requiring a remote withdrawal.
  notRequired,

  /// The original account must decide; unknown evidence was not sent.
  needsDecision,

  /// The server confirmed there is no current health grant.
  confirmed,

  /// Evidence or a remote response was unavailable. This is not confirmation.
  unconfirmed,
}

/// Independent outcomes for one exit. Check [Sessions.isCurrentLogout] with
/// [round] immediately before presenting feedback, even if no one is logged in.
final class LogoutResult {
  const LogoutResult({
    required this.round,
    required this.localCleanup,
    required this.healthWithdrawal,
    required this.serverLogout,
  });

  final LogoutRound round;

  /// Confirmed only when both credential removal and cache wiping completed.
  final LogoutStatus localCleanup;
  final LogoutHealthStatus healthWithdrawal;
  final LogoutStatus serverLogout;
}

enum _UnauthorizedPolicy { standard, preserveOnRefreshFailure, healthGate }

class AppApi {
  final Uri origin;
  final Transport transport;
  final Sessions sessions;
  final _refreshing = <AccountScope, Future<void>>{};
  AppApi(this.origin, this.transport, this.sessions);
  static const _timeout = Duration(seconds: 20);
  static const healthQueueKey = Sessions.healthQueueKey;

  Future<http.StreamedResponse> _send(
    AppOp op,
    Map<String, String> path,
    Map<String, String> query,
    Json? body,
    String? access,
  ) {
    var route = op.path;
    final keys = RegExp(
      r'\{(\w+)\}',
    ).allMatches(route).map((m) => m[1]!).toSet();
    if (keys.length != path.length ||
        !keys.containsAll(path.keys) ||
        !op.queryKeys.toSet().containsAll(query.keys) ||
        !query.keys.toSet().containsAll(op.requiredQuery) ||
        op.hasBody != (body != null)) {
      throw ArgumentError('接口参数不匹配: ${op.name}');
    }
    for (final entry in path.entries) {
      if (entry.value.isEmpty || entry.value == '.' || entry.value == '..') {
        throw ArgumentError('无效路径参数');
      }
      route = route.replaceFirst(
        '{${entry.key}}',
        Uri.encodeComponent(entry.value),
      );
    }
    final request = http.Request(
      op.method,
      origin
          .resolve(route)
          .replace(queryParameters: query.isEmpty ? null : query),
    )..followRedirects = false;
    request.headers['Accept'] = op.accept;
    if (access != null) request.headers['Authorization'] = 'Bearer $access';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json; charset=utf-8';
      request.bodyBytes = utf8.encode(jsonEncode(body));
    }
    return transport.send(op, request).timeout(_timeout);
  }

  Future<void> _success(http.StreamedResponse response, AppOp op) async {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final raw = await response.stream.bytesToString(utf8).timeout(_timeout);
      Json error = {};
      try {
        final value = jsonDecode(raw);
        if (value is Json) error = value;
      } on FormatException {
        /* never expose raw response */
      }
      throw ApiFailure(
        response.statusCode,
        error['code'] is String ? error['code'] : 'unavailable',
        error['message'] is String ? error['message'] : '暂时无法连接，请重试',
        error['retryable'] is bool ? error['retryable'] : null,
        DateTime.tryParse(error['retry_at'] is String ? error['retry_at'] : ''),
        op,
      );
    }
    if (response.headers['content-type']?.split(';').first.trim() !=
        op.accept) {
      await response.stream.listen(null).cancel();
      throw const FormatException('服务响应类型异常');
    }
  }

  Future<Json> _jsonWithAccess(
    AppOp op,
    String access, {
    Map<String, String> path = const {},
    Map<String, String> query = const {},
    Json? body,
  }) async {
    final response = await _send(op, path, query, body, access);
    await _success(response, op);
    final value = jsonDecode(
      await response.stream.bytesToString(utf8).timeout(_timeout),
    );
    if (value is! Json) throw const FormatException('服务响应格式异常');
    return value;
  }

  Future<void> _withdrawHealth(Tokens tokens, LogoutRound round) async {
    void requireCurrent() {
      if (!sessions.isCurrentLogout(round)) throw SessionChanged();
    }

    String? cursor;
    final seen = <String>{};
    do {
      requireCurrent();
      final page = await _jsonWithAccess(
        AppOp.listConsents,
        tokens.access,
        query: {'cursor': ?cursor},
      );
      final items = page['items'];
      if (items is! List) throw const FormatException('服务响应格式异常');
      for (final row in items) {
        if (row is! Map || row['purpose'] != 'health') continue;
        if (row['granted'] == true) {
          final version = row['version'];
          if (version is! String) throw const FormatException('健康授权版本缺失');
          requireCurrent();
          final record = await _jsonWithAccess(
            AppOp.setConsent,
            tokens.access,
            path: {'purpose': 'health'},
            body: {'granted': false, 'version': version},
          );
          if (record['purpose'] != 'health' || record['granted'] != false) {
            throw const FormatException('健康授权撤回未确认');
          }
          return;
        }
        if (row['granted'] != false) {
          throw const FormatException('健康授权状态异常');
        }
      }
      final next = page['next_cursor'];
      if (next != null && next is! String) {
        throw const FormatException('服务响应格式异常');
      }
      cursor = next as String?;
      if (cursor != null && !seen.add(cursor)) {
        throw const FormatException('服务响应游标重复');
      }
    } while (cursor != null);
  }

  Future<void> _refresh(AccountScope scope) =>
      _refreshing.putIfAbsent(scope, () async {
        try {
          final response = await _send(AppOp.refreshTokens, {}, {}, {
            'refresh_token': sessions.require(scope).refresh,
          }, null);
          await _success(response, AppOp.refreshTokens);
          final tokens = Tokens.fromJson(
            jsonDecode(
              await response.stream.bytesToString(utf8).timeout(_timeout),
            ),
          );
          if (tokens.account != scope.account) {
            throw const ApiFailure(401, 'unauthenticated', '请重新登录', false);
          }
          await sessions.rotate(scope, tokens);
        } on ApiFailure catch (e) {
          if (e.status == 401 && identical(sessions.active, scope)) {
            await sessions.clear();
          }
          rethrow;
        } finally {
          _refreshing.remove(scope);
        }
      });

  Future<Never> _rejectUnauthorized(AccountScope scope) async {
    final active = sessions.active;
    if (active != null && !identical(active, scope)) throw SessionChanged();
    if (identical(active, scope)) await sessions.clear();
    throw const ApiFailure(401, 'unauthenticated', '请重新登录', false);
  }

  /// Authenticated calls deliberately have no "use current account" fallback.
  Stream<List<int>> bytes(
    AppOp op, {
    AccountScope? scope,
    Map<String, String> path = const {},
    Map<String, String> query = const {},
    Json? body,
    void Function(int)? onStatus,
  }) => _bytes(
    op,
    scope: scope,
    path: path,
    query: query,
    body: body,
    onStatus: onStatus,
  );

  /// Variant for callers that must re-check a privacy condition immediately
  /// before every network send, including the 401 replay.
  ///
  /// Kept separate from [bytes] so existing subclasses that only model the
  /// original route signature remain valid. [checkBeforeSend] can close a
  /// local race after the async guard; it runs synchronously with dispatch.
  /// [preserveSessionOnUnconfirmedRefresh] surfaces failures without a replay
  /// or local logout. A refresh or replay that returns 401 still ends the session.
  Stream<List<int>> bytesGuarded(
    AppOp op, {
    required Future<void> Function() beforeSend,
    void Function()? checkBeforeSend,
    bool preserveSessionOnUnconfirmedRefresh = false,
    AccountScope? scope,
    Map<String, String> path = const {},
    Map<String, String> query = const {},
    Json? body,
    void Function(int)? onStatus,
  }) => _bytes(
    op,
    scope: scope,
    path: path,
    query: query,
    body: body,
    onStatus: onStatus,
    beforeSend: beforeSend,
    checkBeforeSend: checkBeforeSend,
    unauthorizedPolicy: preserveSessionOnUnconfirmedRefresh
        ? _UnauthorizedPolicy.preserveOnRefreshFailure
        : _UnauthorizedPolicy.standard,
  );

  Stream<List<int>> _bytes(
    AppOp op, {
    AccountScope? scope,
    Map<String, String> path = const {},
    Map<String, String> query = const {},
    Json? body,
    void Function(int)? onStatus,
    Future<void> Function()? beforeSend,
    void Function()? checkBeforeSend,
    _UnauthorizedPolicy unauthorizedPolicy = _UnauthorizedPolicy.standard,
  }) async* {
    String? access;
    if (op.secured) {
      if (scope == null) throw SessionChanged();
      if (!sessions.require(scope).expires.isAfter(DateTime.now())) {
        await _refresh(scope);
      }
      access = sessions.require(scope).access;
    }
    await beforeSend?.call();
    if (op.secured) {
      // The guard can await networking. Revalidate the exact account and use
      // the token that is current after that suspension, not the pre-guard one.
      access = sessions.require(scope!).access;
    }
    checkBeforeSend?.call();
    var response = await _send(op, path, query, body, access);
    if (op.secured && response.statusCode == 401) {
      await response.stream.listen(null).cancel();
      try {
        if (sessions.require(scope!).access == access) await _refresh(scope);
      } on SessionChanged {
        rethrow;
      } catch (_) {
        // _refresh already clears on confirmed credential rejection. Callers
        // with retry bounds to preserve can surface unconfirmed failures.
        if (op == AppOp.getMe ||
            unauthorizedPolicy != _UnauthorizedPolicy.standard) {
          rethrow;
        }
        await _rejectUnauthorized(scope!);
      }
      // Token refresh can take long enough for consent or membership to change.
      // Recheck the caller's fail-closed condition before replaying any body.
      await beforeSend?.call();
      final replayAccess = sessions.require(scope).access;
      checkBeforeSend?.call();
      response = await _send(op, path, query, body, replayAccess);
      if (response.statusCode == 401 &&
          unauthorizedPolicy != _UnauthorizedPolicy.healthGate) {
        await response.stream.listen(null).cancel();
        await _rejectUnauthorized(scope);
      }
    }
    await _success(response, op);
    onStatus?.call(response.statusCode);
    if (scope != null) sessions.require(scope);
    await for (final chunk in response.stream.timeout(_timeout)) {
      if (scope != null) sessions.require(scope);
      yield chunk;
    }
    if (scope != null) sessions.require(scope);
  }

  Future<Json> json(
    AppOp op, {
    AccountScope? scope,
    Map<String, String> path = const {},
    Map<String, String> query = const {},
    Json? body,
  }) => _json(op, scope: scope, path: path, query: query, body: body);

  /// Read-only probes for the T28 collection/upload gate. A failed probe
  /// blocks collection without discarding retry bounds. Only a definitive
  /// refresh rejection (handled by [_refresh]) ends the local session.
  Future<Json> jsonForHealthUploadGate(
    AppOp op, {
    required AccountScope scope,
    Map<String, String> query = const {},
  }) {
    if (op != AppOp.listConsents && op != AppOp.getEntitlements) {
      throw ArgumentError.value(op, 'op', 'Not a health upload gate query');
    }
    return _json(
      op,
      scope: scope,
      query: query,
      unauthorizedPolicy: _UnauthorizedPolicy.healthGate,
    );
  }

  Future<Json> jsonGuarded(
    AppOp op, {
    required Future<void> Function() beforeSend,
    AccountScope? scope,
    Map<String, String> path = const {},
    Map<String, String> query = const {},
    Json? body,
  }) => _json(
    op,
    scope: scope,
    path: path,
    query: query,
    body: body,
    beforeSend: beforeSend,
  );

  Future<Json> _json(
    AppOp op, {
    AccountScope? scope,
    Map<String, String> path = const {},
    Map<String, String> query = const {},
    Json? body,
    Future<void> Function()? beforeSend,
    _UnauthorizedPolicy unauthorizedPolicy = _UnauthorizedPolicy.standard,
  }) async {
    if (op.accept != 'application/json') throw ArgumentError('请使用流式接口');
    final result =
        jsonDecode(
              await _bytes(
                op,
                scope: scope,
                path: path,
                query: query,
                body: body,
                beforeSend: beforeSend,
                unauthorizedPolicy: unauthorizedPolicy,
              ).transform(utf8.decoder).join(),
            )
            as Json;
    if (scope != null) sessions.require(scope);
    return result;
  }

  Stream<ReplyEvent> messages(
    AccountScope scope,
    String sessionId,
    String clientMessageId,
    String text,
  ) async* {
    final stream = bytes(
      AppOp.sendMessage,
      scope: scope,
      path: {'session_id': sessionId},
      body: {'client_message_id': clientMessageId, 'text': text},
    );
    await for (final event in decodeReply(stream, clientMessageId)) {
      sessions.require(scope);
      yield event;
    }
  }

  /// The captured tokens are used only for this foreground attempt. Durable
  /// retries carry the account-bound intent, never these credentials.
  Future<LogoutResult> logoutWithResult(AccountScope scope) async =>
      (await _logout(scope)).result;

  /// Adapter for the existing UI until it consumes [logoutWithResult]. Do not
  /// publish a legacy notice from an exit that has since been superseded.
  Future<void> logout(AccountScope scope) async {
    final outcome = await _logout(scope);
    if (!sessions.isCurrentLogout(outcome.result.round)) return;
    final legacyError =
        outcome.localError ?? outcome.withdrawalError ?? outcome.serverError;
    if (legacyError != null) throw legacyError;
  }

  Future<
    ({
      LogoutResult result,
      Object? localError,
      Object? withdrawalError,
      Object? serverError,
    })
  >
  _logout(AccountScope scope) async {
    final tokens = sessions.require(scope);
    final (:round, :cleanup) = sessions.beginLogout(scope);
    final local = await cleanup;
    var health = switch (local.withdrawal) {
      LogoutWithdrawalEvidence.none => LogoutHealthStatus.notRequired,
      LogoutWithdrawalEvidence.unknown => LogoutHealthStatus.needsDecision,
      _ => LogoutHealthStatus.unconfirmed,
    };
    Object? withdrawalError;
    if (local.withdrawal == LogoutWithdrawalEvidence.explicit) {
      try {
        await _withdrawHealth(tokens, round);
        health = LogoutHealthStatus.confirmed;
      } on Object catch (error) {
        withdrawalError = error;
      }
      if (health == LogoutHealthStatus.confirmed && local.error == null) {
        try {
          await sessions.acknowledgeLogoutWithdrawal(round);
        } on Object {
          // A failed acknowledgment leaves the outbox available for an
          // idempotent retry. It does not undo the server's confirmation.
        }
      }
    }
    Object? serverError;
    var serverLogout = LogoutStatus.unconfirmed;
    if (local.error is! CleanupEvidenceUnavailable) {
      try {
        final response = await _send(AppOp.logout, {}, {}, {
          'refresh_token': tokens.refresh,
        }, tokens.access);
        await _success(response, AppOp.logout);
        await response.stream.drain<void>().timeout(_timeout);
        serverLogout = LogoutStatus.confirmed;
      } on Object catch (error) {
        serverError = error;
      }
    }
    return (
      result: LogoutResult(
        round: round,
        localCleanup: local.error == null
            ? LogoutStatus.confirmed
            : LogoutStatus.unconfirmed,
        healthWithdrawal: health,
        serverLogout: serverLogout,
      ),
      localError: local.error,
      withdrawalError: withdrawalError,
      serverError: serverError,
    );
  }
}
