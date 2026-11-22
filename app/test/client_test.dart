import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/consent.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/sse.dart';
import 'package:high_eq/core/transport.dart';
import 'isolation_test.dart' show MemorySecret, tokens;

class Handler implements Transport {
  late Future<http.StreamedResponse> Function(AppOp, http.Request) handle;
  @override
  Future<http.StreamedResponse> send(AppOp op, http.Request request) =>
      handle(op, request);
  @override
  void close() {}
}

http.StreamedResponse response(Map data, [int code = 200]) =>
    http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(data))),
      code,
      headers: {'content-type': 'application/json'},
    );
void main() {
  late Directory dir;
  late Sessions sessions;
  late AppApi api;
  late Handler handler;
  late AccountScope a;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp();
    sessions = Sessions(MemorySecret(), dir);
    handler = Handler();
    api = AppApi(Uri.https('test.invalid'), handler, sessions);
    a = await sessions.activate(tokens('A'));
  });
  tearDown(() => dir.delete(recursive: true));
  test(
    'concurrent 401s rotate once and replay original URL and body',
    () async {
      final pending = Completer<void>();
      var rotations = 0, calls = 0;
      handler.handle = (op, req) async {
        if (op == AppOp.refreshTokens) {
          rotations++;
          await pending.future;
          expect(req.headers['Authorization'], isNull);
          return response(tokens('A', 'new').toJson());
        }
        calls++;
        expect(req.method, 'PATCH');
        expect(req.url.path, '/v1/marks/42');
        expect(jsonDecode(req.body), {'scene': '练习'});
        return req.headers['Authorization'] == 'Bearer new'
            ? response({'ok': true})
            : response({}, 401);
      };
      final work = [
        for (var i = 0; i < 2; i++)
          api.json(
            AppOp.editMark,
            scope: a,
            path: {'id': '42'},
            body: {'scene': '练习'},
          ),
      ];
      await Future<void>.delayed(Duration.zero);
      expect(rotations, 1);
      pending.complete();
      await Future.wait(work);
      expect(calls, 4);
      expect(sessions.require(a).access, 'new');
    },
  );
  test('refresh rejection clears session and never loops', () async {
    var calls = 0;
    handler.handle = (_, _) async {
      calls++;
      return response({'code': 'unauthenticated'}, 401);
    };
    await expectLater(
      api.json(AppOp.getMe, scope: a),
      throwsA(isA<ApiFailure>()),
    );
    expect(calls, 2);
    expect(sessions.active, isNull);
  });
  test('business 401 with refresh 5xx clears account', () async {
    var calls = 0;
    handler.handle = (op, _) async {
      calls++;
      if (op == AppOp.refreshTokens) {
        return response({
          'code': 'unavailable',
          'message': 'refresh unavailable',
        }, 500);
      }
      return response({
        'code': 'unauthenticated',
        'message': 'account frozen',
      }, 401);
    };

    await expectLater(
      api.json(AppOp.getGrowth, scope: a),
      throwsA(
        isA<ApiFailure>()
            .having((e) => e.status, 'status', 401)
            .having((e) => e.code, 'code', 'unauthenticated')
            .having((e) => e.message, 'message', '请重新登录'),
      ),
    );
    expect(calls, 2);
    expect(sessions.active, isNull);
  });

  test('getMe business 401 with refresh 5xx preserves account', () async {
    var calls = 0;
    handler.handle = (op, _) async {
      calls++;
      if (op == AppOp.refreshTokens) {
        return response({
          'code': 'unavailable',
          'message': 'refresh unavailable',
          'retryable': true,
        }, 503);
      }
      return response({
        'code': 'unauthenticated',
        'message': 'probe unauthorized',
      }, 401);
    };

    await expectLater(
      api.json(AppOp.getMe, scope: a),
      throwsA(
        isA<ApiFailure>()
            .having((e) => e.status, 'status', 503)
            .having((e) => e.retryable, 'retryable', isTrue),
      ),
    );
    expect(calls, 2);
    expect(sessions.active, same(a));
  });

  test('business 401 with refresh timeout clears account', () async {
    var calls = 0;
    handler.handle = (op, _) async {
      calls++;
      if (op == AppOp.refreshTokens) {
        throw TimeoutException('refresh timed out');
      }
      return response({
        'code': 'unauthenticated',
        'message': 'account frozen',
      }, 401);
    };

    await expectLater(
      api.json(AppOp.getGrowth, scope: a),
      throwsA(
        isA<ApiFailure>()
            .having((e) => e.status, 'status', 401)
            .having((e) => e.code, 'code', 'unauthenticated')
            .having((e) => e.message, 'message', '请重新登录'),
      ),
    );
    expect(calls, 2);
    expect(sessions.active, isNull);
  });

  test('business 401 replay still unauthorized clears account', () async {
    var calls = 0;
    handler.handle = (op, _) async {
      calls++;
      if (op == AppOp.refreshTokens) {
        return response(tokens('A', 'new').toJson());
      }
      return response({
        'code': 'unauthenticated',
        'message': 'still frozen',
      }, 401);
    };

    await expectLater(
      api.json(AppOp.getGrowth, scope: a),
      throwsA(
        isA<ApiFailure>()
            .having((e) => e.status, 'status', 401)
            .having((e) => e.code, 'code', 'unauthenticated')
            .having((e) => e.message, 'message', '请重新登录'),
      ),
    );
    expect(calls, 3);
    expect(sessions.active, isNull);
  });

  test('expired access refresh 5xx preserves account', () async {
    await sessions.rotate(
      a,
      Tokens(
        'A',
        'expired',
        'refresh',
        DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
      ),
    );
    var calls = 0;
    handler.handle = (op, _) async {
      calls++;
      expect(op, AppOp.refreshTokens);
      return response({
        'code': 'unavailable',
        'message': 'refresh unavailable',
      }, 500);
    };

    await expectLater(
      api.json(AppOp.getGrowth, scope: a),
      throwsA(
        isA<ApiFailure>()
            .having((e) => e.status, 'status', 500)
            .having((e) => e.code, 'code', 'unavailable'),
      ),
    );
    expect(calls, 1);
    expect(sessions.require(a).access, 'expired');
  });

  test('ordinary service 5xx preserves account', () async {
    handler.handle = (_, _) async => response({
      'code': 'unavailable',
      'message': 'temporarily unavailable',
    }, 503);

    await expectLater(
      api.json(AppOp.getGrowth, scope: a),
      throwsA(
        isA<ApiFailure>()
            .having((e) => e.status, 'status', 503)
            .having((e) => e.code, 'code', 'unavailable'),
      ),
    );
    expect(sessions.require(a).access, 'access');
  });

  test('late refresh or scheduled A queue cannot send as B', () async {
    final pending = Completer<http.StreamedResponse>(),
        started = Completer<void>();
    final auth = <String?>[];
    handler.handle = (op, req) async {
      auth.add(req.headers['Authorization']);
      if (op == AppOp.refreshTokens) {
        started.complete();
        return pending.future;
      }
      return response({}, 401);
    };
    final wait = expectLater(
      api.json(AppOp.getMe, scope: a),
      throwsA(isA<SessionChanged>()),
    );
    await started.future;
    await sessions.clear();
    final b = await sessions.activate(tokens('B', 'B-key'));
    pending.complete(response(tokens('A', 'new').toJson()));
    await wait;
    await expectLater(
      api.json(AppOp.getMe, scope: a),
      throwsA(isA<SessionChanged>()),
    );
    expect(auth, ['Bearer access', null]);
    expect(sessions.require(b).access, 'B-key');
  });
  test(
    'fresh paged consent + OS + active member checked on every collection',
    () async {
      var paid = true, granted = true, os = true, reads = 0, offline = false;
      var expiry = DateTime.now().add(const Duration(days: 1));
      handler.handle = (op, req) async {
        if (offline) throw const SocketException('offline');
        if (op == AppOp.getEntitlements) {
          return response({
            'tier': paid ? 'member' : 'free',
            'expires_at': expiry.toIso8601String(),
          });
        }
        if (req.url.queryParameters.isEmpty) {
          return response({
            'items': [
              {'purpose': 'voice', 'granted': true},
            ],
            'next_cursor': 'page2',
          });
        }
        return response({
          'items': [
            {'purpose': 'audio_retention', 'granted': granted},
          ],
          'next_cursor': null,
        });
      };
      final gate = ConsentGate(api);
      Future<bool> check() => gate.readIfAllowed(
        a,
        CollectionPurpose.audioRetention,
        systemGranted: () async => os,
        beginRead: () => reads++,
      );
      expect(await check(), true);
      granted = false;
      expect(await check(), false);
      granted = true;
      paid = false;
      expect(await check(), false);
      paid = true;
      os = false;
      expect(await check(), false);
      os = true;
      expiry = DateTime(2000);
      expect(await check(), false);
      offline = true;
      expect(await check(), false);
      await sessions.clear();
      expect(await check(), false);
      expect(reads, 1);
    },
  );
  test(
    'SSE fragmented UTF-8, CRLF, multiline and distinct terminal events',
    () async {
      const fragment =
          ': pulse\r\nevent: fragment\r\ndata: {"client_message_id":"id",\r\ndata: "text":"一句"}\r\n\r\n';
      final cases = {
        ReplyEventKind.safety: 'safety\ndata: {"safety":true,"message":"停止"}',
        ReplyEventKind.replySaved:
            'reply_saved\ndata: {"client_message_id":"id","message_id":"m","settlement":{}}',
        ReplyEventKind.moderationUnavailable:
            'moderation_unavailable\ndata: {"code":"moderation_unavailable","retryable":true,"message":"稍后"}',
        ReplyEventKind.inProgress:
            'in_progress\ndata: {"client_message_id":"id"}',
      };
      for (final c in cases.entries) {
        final wire = utf8.encode('${fragment}event: ${c.value}\n\n$fragment');
        final events = await decodeReply(
          Stream.fromIterable(wire.map((b) => [b])),
          'id',
        ).toList();
        expect(events.map((e) => e.kind), [ReplyEventKind.fragment, c.key]);
        expect(events.first.data['text'], '一句');
      }
      await expectLater(
        decodeReply(Stream.value(utf8.encode(fragment)), 'id').drain<void>(),
        throwsFormatException,
      );
      await expectLater(
        decodeReply(Stream.value(utf8.encode(fragment)), 'wrong').drain<void>(),
        throwsFormatException,
      );
    },
  );
}
