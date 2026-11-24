import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/features/growth/repository.dart';

import '../client_test.dart' show Handler, response;
import '../isolation_test.dart' show MemorySecret, tokens;

void main() {
  late Directory dir;
  late Sessions sessions;
  late AppApi api;
  late Handler wire;
  late AccountScope scope;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp();
    sessions = Sessions(MemorySecret(), dir);
    scope = await sessions.activate(tokens('A'));
    wire = Handler();
    api = AppApi(Uri.https('wire.invalid'), wire, sessions);
  });

  tearDown(() => dir.delete(recursive: true));

  test('历史分页会遍历全部游标并保留后续页的评分', () async {
    final fixtures =
        jsonDecode(await File('assets/contract_examples.json').readAsString())
            as Map<String, dynamic>;
    final cursors = <String?>[];

    wire.handle = (op, request) async {
      if (op != AppOp.listSessions) return response(fixtures[op.name] as Map);
      final cursor = request.url.queryParameters['cursor'];
      cursors.add(cursor);
      expect(request.url.queryParameters['limit'], '100');
      if (cursor == null) {
        return response({
          'items': [
            for (var index = 0; index < 100; index++)
              {
                'session_id': 'pending-$index',
                'status': 'pending',
                'mode': 'full_session',
                'target_item': null,
                'messages': <Object>[],
              },
          ],
          'next_cursor': 'page-2',
        });
      }
      expect(cursor, 'page-2');
      return response({
        'items': [
          {
            'session_id': 'scored-on-page-two',
            'status': 'finished',
            'mode': 'full_session',
            'target_item': null,
            'messages': <Object>[],
            'result': {
              'mode': 'full_session',
              'score': {
                'nvc': {'total': 82},
              },
            },
          },
        ],
        'next_cursor': null,
      });
    };

    final snapshot = await ApiGrowthRepository(api, scope).load();

    expect(cursors, [null, 'page-2']);
    expect(snapshot.scoredSessions, hasLength(1));
    expect(snapshot.scoredSessions.single.sessionId, 'scored-on-page-two');
    expect(snapshot.scoredSessions.single.total, 82);
  });

  test('跨页历史按完成时间在列表与缓存中保持一致', () async {
    final fixtures =
        jsonDecode(await File('assets/contract_examples.json').readAsString())
            as Map<String, dynamic>;

    Map<String, dynamic> scored(String id, String completedAt, int total) => {
      'session_id': id,
      'status': 'complete',
      'mode': 'full_session',
      'target_item': null,
      'messages': <Object>[],
      'completed_at': completedAt,
      'settlement': {
        'status': 'charged',
        'net_charge': 1,
        'charged_day': '2026-11-22',
      },
      'result': {
        'mode': 'full_session',
        'score': {
          'nvc': {'total': total},
        },
        'settlement': {
          'status': 'charged',
          'net_charge': 1,
          'charged_day': '2026-11-22',
        },
      },
    };

    wire.handle = (op, request) async {
      if (op != AppOp.listSessions) return response(fixtures[op.name] as Map);
      final cursor = request.url.queryParameters['cursor'];
      if (cursor == null) {
        return response({
          'items': [scored('created-second', '2026-11-10T09:00:00Z', 61)],
          'next_cursor': 'page-2',
        });
      }
      expect(cursor, 'page-2');
      return response({
        'items': [scored('created-first', '2026-11-20T09:00:00Z', 84)],
        'next_cursor': null,
      });
    };

    final repository = ApiGrowthRepository(api, scope);
    final snapshot = await repository.load();
    final cached = await repository.cached();

    expect(snapshot.scoredSessions.map((score) => score.sessionId), [
      'created-first',
      'created-second',
    ]);
    expect(cached?.scoredSessions.map((score) => score.sessionId), [
      'created-first',
      'created-second',
    ]);
  });

  test('删除得分后重新加载会同步移除列表与缓存中的旧记录', () async {
    final fixtures =
        jsonDecode(await File('assets/contract_examples.json').readAsString())
            as Map<String, dynamic>;
    var deleted = false;

    Map<String, dynamic> scored(String id, String completedAt, int total) => {
      'session_id': id,
      'status': 'complete',
      'mode': 'full_session',
      'target_item': null,
      'messages': <Object>[],
      'completed_at': completedAt,
      'settlement': {
        'status': 'charged',
        'net_charge': 1,
        'charged_day': '2026-11-22',
      },
      'result': {
        'mode': 'full_session',
        'score': {
          'nvc': {'total': total},
        },
        'settlement': {
          'status': 'charged',
          'net_charge': 1,
          'charged_day': '2026-11-22',
        },
      },
    };

    wire.handle = (op, request) async {
      if (op != AppOp.listSessions) return response(fixtures[op.name] as Map);
      return response({
        'items': [
          scored('kept', '2026-11-10T09:00:00Z', 61),
          if (!deleted) scored('deleted', '2026-11-20T09:00:00Z', 84),
        ],
        'next_cursor': null,
      });
    };

    final repository = ApiGrowthRepository(api, scope);
    final before = await repository.load();
    expect(before.scoredSessions.map((score) => score.sessionId), [
      'deleted',
      'kept',
    ]);

    deleted = true;
    final after = await repository.load();
    final cached = await repository.cached();

    expect(after.scoredSessions.map((score) => score.sessionId), ['kept']);
    expect(cached?.scoredSessions.map((score) => score.sessionId), ['kept']);
  });

  test('清理缓存后，在途旧读取不能重新写回成长快照', () async {
    final fixtures =
        jsonDecode(await File('assets/contract_examples.json').readAsString())
            as Map<String, dynamic>;
    final growthStarted = Completer<void>();
    final releaseGrowth = Completer<void>();

    wire.handle = (op, request) async {
      if (op == AppOp.getGrowth) {
        if (!growthStarted.isCompleted) growthStarted.complete();
        await releaseGrowth.future;
      }
      return response(fixtures[op.name] as Map);
    };

    final repository = ApiGrowthRepository(api, scope);
    final loading = repository.load();
    await growthStarted.future;
    await repository.clearCache();
    releaseGrowth.complete();
    await loading;

    expect(await repository.cached(), isNull);
  });

  test('旧账号清理成长缓存不会移除新账号的快照', () async {
    final fixtures =
        jsonDecode(await File('assets/contract_examples.json').readAsString())
            as Map<String, dynamic>;
    wire.handle = (op, request) async => response(fixtures[op.name] as Map);

    final oldRepository = ApiGrowthRepository(api, scope);
    final nextScope = await sessions.activate(tokens('B', 'access-b'));
    final nextRepository = ApiGrowthRepository(api, nextScope);
    await nextRepository.load();

    await expectLater(
      oldRepository.clearCache(),
      throwsA(isA<SessionChanged>()),
    );

    expect(await nextRepository.cached(), isNotNull);
  });

  for (final authStatus in [401, 403]) {
    test('并行读取优先保留 $authStatus 授权拒绝而不是普通失败', () async {
      final fixtures =
          jsonDecode(await File('assets/contract_examples.json').readAsString())
              as Map<String, dynamic>;
      var growthCalls = 0;

      wire.handle = (op, request) async {
        if (op == AppOp.getTodayPlan) {
          return response({'code': 'unavailable'}, 500);
        }
        if (op == AppOp.refreshTokens) {
          return response(tokens('A', 'new').toJson());
        }
        if (op == AppOp.getGrowth) {
          growthCalls++;
          if (authStatus == 401 && growthCalls == 1) return response({}, 401);
          return response({'code': 'auth-rejected'}, authStatus);
        }
        return response(fixtures[op.name] as Map);
      };

      await expectLater(
        ApiGrowthRepository(api, scope).load(),
        throwsA(
          isA<ApiFailure>().having(
            (failure) => failure.status,
            'status',
            authStatus,
          ),
        ),
      );
    });
  }

  test('并行读取优先保留账号切换而不是普通失败', () async {
    wire.handle = (op, request) async {
      if (op == AppOp.getTodayPlan) {
        return response({'code': 'unavailable'}, 500);
      }
      throw SessionChanged();
    };

    await expectLater(
      ApiGrowthRepository(api, scope).load(),
      throwsA(isA<SessionChanged>()),
    );
  });
}
