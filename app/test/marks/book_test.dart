import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/marks/book.dart';

class Secret implements SecretStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> replace(String? next) async => value = next;
}

class Gone implements Transport {
  int calls = 0;
  @override
  Future<http.StreamedResponse> send(AppOp op, http.Request request) async {
    calls++;
    expect(op, AppOp.deleteMark);
    return http.StreamedResponse(
      Stream.value(
        utf8.encode(
          jsonEncode({
            'code': 'not_found',
            'message': '这条标记已不存在',
            'retryable': false,
          }),
        ),
      ),
      404,
      headers: {'content-type': 'application/json'},
    );
  }

  @override
  void close() {}
}

class UnavailableRefresh implements Transport {
  int calls = 0;
  @override
  Future<http.StreamedResponse> send(AppOp op, http.Request request) async {
    calls++;
    if (op == AppOp.getMe) {
      return http.StreamedResponse(
        Stream.value(
          utf8.encode(
            jsonEncode({
              'code': 'unauthenticated',
              'message': '登录已过期',
              'retryable': false,
            }),
          ),
        ),
        401,
        headers: {'content-type': 'application/json'},
      );
    }
    expect(op, AppOp.refreshTokens);
    return http.StreamedResponse(
      Stream.value(
        utf8.encode(
          jsonEncode({
            'code': 'service_unavailable',
            'message': '数据暂时不可用，请稍后重试',
            'retryable': true,
          }),
        ),
      ),
      503,
      headers: {'content-type': 'application/json'},
    );
  }

  @override
  void close() {}
}

void main() {
  test('刷新遇到可重试 503 时保留会话和本机草稿', () async {
    final dir = await Directory.systemTemp.createTemp('marks-refresh-');
    addTearDown(() => dir.delete(recursive: true));
    final sessions = Sessions(Secret(), dir);
    final scope = await sessions.activate(
      Tokens(
        'account',
        'access',
        'refresh',
        DateTime.now().add(const Duration(hours: 1)),
      ),
    );
    await sessions.put(scope, CacheKind.draft, 'mark:m', utf8.encode('draft'));
    final transport = UnavailableRefresh();
    final api = AppApi(
      Uri.parse('https://fixture.invalid'),
      transport,
      sessions,
    );
    await expectLater(
      api.json(AppOp.getMe, scope: scope),
      throwsA(
        isA<ApiFailure>()
            .having((e) => e.status, 'status', 503)
            .having((e) => e.retryable, 'retryable', isTrue),
      ),
    );
    expect(transport.calls, 2);
    expect(sessions.active, same(scope));
    expect(
      utf8.decode((await sessions.get(scope, CacheKind.draft, 'mark:m'))!),
      'draft',
    );
  });
  test('删除已提交但响应 404 时同步移除本地草稿指针', () async {
    final dir = await Directory.systemTemp.createTemp('marks-book-');
    addTearDown(() => dir.delete(recursive: true));
    final sessions = Sessions(Secret(), dir);
    final scope = await sessions.activate(
      Tokens(
        'account',
        'access',
        'refresh',
        DateTime.now().add(const Duration(hours: 1)),
      ),
    );
    await sessions.put(scope, CacheKind.draft, 'mark:m', utf8.encode('m'));
    final transport = Gone();
    final api = AppApi(
      Uri.parse('https://fixture.invalid'),
      transport,
      sessions,
    );
    await MarkBook(api, scope).remove('m');
    expect(transport.calls, 1);
    expect(await sessions.get(scope, CacheKind.draft, 'mark:m'), isNull);
  });
}
