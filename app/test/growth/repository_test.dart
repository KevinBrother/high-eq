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
