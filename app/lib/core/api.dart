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
  const ApiFailure(
    this.status,
    this.code,
    this.message,
    this.retryable, [
    this.retryAt,
  ]);
}

class AppApi {
  final Uri origin;
  final Transport transport;
  final Sessions sessions;
  final _refreshing = <AccountScope, Future<void>>{};
  AppApi(this.origin, this.transport, this.sessions);
  static const _timeout = Duration(seconds: 20);

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
      );
    }
    if (response.headers['content-type']?.split(';').first.trim() !=
        op.accept) {
      await response.stream.listen(null).cancel();
      throw const FormatException('服务响应类型异常');
    }
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

  /// Authenticated calls deliberately have no "use current account" fallback.
  Stream<List<int>> bytes(
    AppOp op, {
    AccountScope? scope,
    Map<String, String> path = const {},
    Map<String, String> query = const {},
    Json? body,
    void Function(int)? onStatus,
  }) async* {
    String? access;
    if (op.secured) {
      if (scope == null) throw SessionChanged();
      if (!sessions.require(scope).expires.isAfter(DateTime.now())) {
        await _refresh(scope);
      }
      access = sessions.require(scope).access;
    }
    var response = await _send(op, path, query, body, access);
    if (op.secured && response.statusCode == 401) {
      await response.stream.listen(null).cancel();
      if (sessions.require(scope!).access == access) await _refresh(scope);
      response = await _send(
        op,
        path,
        query,
        body,
        sessions.require(scope).access,
      );
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
  }) async {
    if (op.accept != 'application/json') throw ArgumentError('请使用流式接口');
    final result =
        jsonDecode(
              await bytes(
                op,
                scope: scope,
                path: path,
                query: query,
                body: body,
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

  Future<void> logout(AccountScope scope) async {
    final tokens = sessions.require(scope);
    final cleared = sessions.clear(); // Invalidate synchronously, even offline.
    await cleared;
    final response = await _send(AppOp.logout, {}, {}, {
      'refresh_token': tokens.refresh,
    }, tokens.access);
    await _success(response, AppOp.logout);
    await response.stream.drain<void>().timeout(_timeout);
  }
}
