import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/features/contacts/scene.dart';
import 'package:high_eq/features/reviews/model.dart';
import 'package:high_eq/features/reviews/repository.dart';

import '../client_test.dart' show Handler, response;
import '../isolation_test.dart' show MemorySecret, tokens;

ReviewDraft _draft(String id) => ReviewDraft(
  requestId: id,
  happened: '合成情境',
  myFeeling: '有点着急',
  theirFeeling: '可能也在赶时间',
  myAction: '我提高了声音',
  nextAction: '先确认对方想补充什么',
  contactId: '00000000-0000-4000-8000-000000000001',
  markId: '00000000-0000-4000-8000-000000000002',
  scene: Scene.work,
  occurredAt: DateTime.parse('2026-11-21T10:00:00+08:00'),
);

Map<String, dynamic> _reviewJson(String id) => {
  'id': id,
  'submitted': _draft('85b72033-9f07-4bbc-8567-fc31f26508ab').toWire(),
  'score': {
    'score_id': '00000000-0000-4000-8000-000000000003',
    'mode': 'express',
    'nvc': {
      'observation': {'score': 25, 'reason': '具体'},
      'feeling': {'score': 20, 'reason': '可更直接'},
      'need': {'score': 20, 'reason': '可更清楚'},
      'request': {'score': 20, 'reason': '有邀请'},
      'total': 85,
    },
    'emotion': {
      'read_others': {'level': 4, 'reason': '看到停顿'},
      'self_management': {'level': 3, 'reason': '语气缓和'},
      'relationship': {'level': 4, 'reason': '留出空间'},
    },
    'better_version': '我能先说一句再听你补充吗？',
    'why_better': '行动具体，也给了对方选择。',
    'target_turn': 1,
  },
  'repair_phrase': '刚才我打断了你，你愿意把话说完吗？',
};

void main() {
  late Directory dir;
  late Sessions sessions;
  late AccountScope account;
  late Handler handler;
  late AppApi api;
  late ApiReviews repo;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp();
    sessions = Sessions(MemorySecret(), dir);
    handler = Handler();
    api = AppApi(Uri.https('offline.invalid'), handler, sessions);
    account = await sessions.activate(tokens('A'));
    repo = ApiReviews(api, account);
  });

  tearDown(() => dir.delete(recursive: true));

  test('创建只发送契约字段，202 保留处理中，重试使用相同请求体', () async {
    final bodies = <Map<String, dynamic>>[];
    handler.handle = (op, request) async {
      expect(op, AppOp.createReview);
      expect(request.method, 'POST');
      expect(request.url.path, '/v1/reviews');
      expect(request.headers['Authorization'], 'Bearer access');
      final body =
          jsonDecode(utf8.decode(request.bodyBytes)) as Map<String, dynamic>;
      bodies.add(body);
      return response({
        'request_id': body['request_id'],
        'status': 'in_progress',
      }, 202);
    };
    final draft = _draft('85b72033-9f07-4bbc-8567-fc31f26508ab');
    expect(await repo.submit(draft), isA<ReviewProcessing>());
    expect(await repo.submit(draft), isA<ReviewProcessing>());
    expect(bodies, hasLength(2));
    expect(bodies.first, bodies.last);
    expect(bodies.first.keys.toSet(), {
      'request_id',
      'happened',
      'my_feeling',
      'their_possible_feeling',
      'my_action',
      'next_action',
      'contact_id',
      'mark_id',
      'scene',
      'occurred_at',
    });
    expect(bodies.first.keys.where((key) => key.contains('audio')), isEmpty);
    expect(
      bodies.first.keys.where((key) => key.contains('recording')),
      isEmpty,
    );
  });

  test('200 严格区分评分与危机，并完整保留 NVC 结果', () async {
    handler.handle = (op, request) async {
      expect(op, AppOp.createReview);
      return response(_reviewJson('00000000-0000-4000-8000-000000000004'));
    };
    final ready = await repo.submit(
      _draft('85b72033-9f07-4bbc-8567-fc31f26508ab'),
    );
    expect(ready, isA<ReviewReady>());
    final record = (ready as ReviewReady).record;
    expect(record.score.total, 85);
    expect(record.score.observation.reason, '具体');
    expect(record.score.betterVersion, '我能先说一句再听你补充吗？');
    expect(record.repairPhrase, contains('把话说完'));

    handler.handle = (_, _) async =>
        response({'safety': true, 'message': '全国心理援助热线 12356'});
    final safety = await repo.submit(
      _draft('85b72033-9f07-4bbc-8567-fc31f26508ab'),
    );
    expect(safety, isA<ReviewSafety>());
    expect((safety as ReviewSafety).message, contains('12356'));
  });

  test('复盘授权分页查询，并以契约字段提交授权', () async {
    var consentPage = 0;
    handler.handle = (op, request) async {
      if (op == AppOp.listConsents) {
        expect(request.method, 'GET');
        expect(request.url.path, '/v1/me/consents');
        consentPage++;
        return response({
          'items': [
            if (consentPage == 2)
              {
                'purpose': 'review',
                'version': 'v1',
                'granted': true,
                'updated_at': '2026-11-21T10:00:00+08:00',
              },
          ],
          'next_cursor': consentPage == 1 ? 'page-2' : null,
        });
      }
      expect(op, AppOp.setConsent);
      expect(request.method, 'PUT');
      expect(request.url.path, '/v1/me/consents/review');
      expect(jsonDecode(utf8.decode(request.bodyBytes)), {
        'granted': true,
        'version': 'v1',
      });
      return response({
        'purpose': 'review',
        'version': 'v1',
        'granted': true,
        'updated_at': '2026-11-21T10:00:00+08:00',
      });
    };
    expect(await repo.allowed(), isTrue);
    expect(consentPage, 2);
    await repo.grant();
  });

  test('列表发送场景、关系人与游标筛选，并解码下一页', () async {
    final queries = <Map<String, String>>[];
    handler.handle = (op, request) async {
      expect(op, AppOp.listReviews);
      expect(request.method, 'GET');
      expect(request.url.path, '/v1/reviews');
      queries.add(request.url.queryParameters);
      return response({
        'items': [_reviewJson('00000000-0000-4000-8000-000000000004')],
        'next_cursor': queries.length == 1 ? 'page-2' : null,
      });
    };
    final first = await repo.history(
      limit: 12,
      scene: Scene.family,
      contactId: '00000000-0000-4000-8000-000000000001',
    );
    expect(first.items.single.score.total, 85);
    expect(first.next, 'page-2');
    final second = await repo.history(
      cursor: first.next,
      limit: 12,
      scene: Scene.family,
      contactId: '00000000-0000-4000-8000-000000000001',
    );
    expect(second.next, isNull);
    expect(queries, [
      {
        'limit': '12',
        'scene': 'family',
        'contact_id': '00000000-0000-4000-8000-000000000001',
      },
      {
        'cursor': 'page-2',
        'limit': '12',
        'scene': 'family',
        'contact_id': '00000000-0000-4000-8000-000000000001',
      },
    ]);
  });

  test('草稿 AES-GCM 落盘，A 的草稿在 B 登录后不可见', () async {
    final draft = _draft('85b72033-9f07-4bbc-8567-fc31f26508ab');
    await repo.saveDraft(draft);
    final files = dir.listSync().whereType<File>().toList();
    expect(files, isNotEmpty);
    for (final file in files) {
      final raw = latin1.decode(await file.readAsBytes());
      expect(raw, isNot(contains('合成情境')));
      expect(raw, isNot(contains(draft.requestId)));
    }
    expect((await repo.loadDraft())!.happened, '合成情境');

    final b = await sessions.activate(tokens('B'));
    final asB = ApiReviews(api, b);
    expect(await asB.loadDraft(), isNull);
    await expectLater(repo.loadDraft(), throwsA(isA<SessionChanged>()));
  });

  test('旧缓存当前键与冻结键不同时，保守恢复两个可能已发请求', () {
    final a = _draft('85b72033-9f07-4bbc-8567-fc31f26508ab');
    final b = {
      ...a.toWire(),
      'request_id': 'b24e1e23-1af9-4fdf-831c-9e79eb1c9b59',
      'next_action': '另一项行动',
    };
    final restored = ReviewDraft.fromCacheJson({
      ...b,
      'attempted': true,
      'frozen_attempt': {...a.toWire(), 'attempted': true},
    });
    expect(restored.toWire(), b);
    expect(restored.possibleAttempts.map((entry) => entry.toWire()), [
      a.toWire(),
      b,
    ]);
  });

  test('当前草稿与两个可能已发的请求键随账号加密缓存往返，不进入 wire', () async {
    final a = _draft('85b72033-9f07-4bbc-8567-fc31f26508ab');
    final b = ReviewDraft.fromJson({
      ...a.toWire(),
      'request_id': 'b24e1e23-1af9-4fdf-831c-9e79eb1c9b59',
      'next_action': '另一项行动',
    });
    final edited = ReviewDraft.fromJson({
      ...b.toWire(),
      'happened': '临时修改后的经过',
    }).copyWith(possibleAttempts: [a, b]);
    await repo.saveDraft(edited);

    final restored = (await repo.loadDraft())!;
    expect(restored.toWire(), edited.toWire());
    expect(restored.happened, '临时修改后的经过');
    expect(restored.toWire().containsKey('possible_attempts'), isFalse);
    expect(restored.possibleAttempts.map((entry) => entry.toWire()), [
      a.toWire(),
      b.toWire(),
    ]);
    expect(restored.toCacheJson()['possible_attempts'], [
      a.toWire(),
      b.toWire(),
    ]);

    final other = await sessions.activate(tokens('B'));
    expect(await ApiReviews(api, other).loadDraft(), isNull);
    await expectLater(repo.loadDraft(), throwsA(isA<SessionChanged>()));
  });

  test('旧请求清理只删除 ID 与规范化内容都匹配的草稿', () async {
    final oldDraft = _draft('85b72033-9f07-4bbc-8567-fc31f26508ab');
    final edited = ReviewDraft(
      requestId: oldDraft.requestId,
      happened: '后来改过的合成情境',
      myFeeling: oldDraft.myFeeling,
      theirFeeling: oldDraft.theirFeeling,
      myAction: oldDraft.myAction,
      nextAction: oldDraft.nextAction,
      possibleAttempts: [oldDraft],
      contactId: oldDraft.contactId,
      markId: oldDraft.markId,
      scene: oldDraft.scene,
      occurredAt: oldDraft.occurredAt,
    );
    final freshDraft = _draft('b24e1e23-1af9-4fdf-831c-9e79eb1c9b59');

    await repo.saveDraft(edited);
    await repo.discardDraft(oldDraft);
    final retained = await repo.loadDraft();
    expect(retained?.requestId, oldDraft.requestId);
    expect(retained?.happened, edited.happened);
    expect(retained?.possibleAttempts.single.toWire(), oldDraft.toWire());

    await repo.saveDraft(freshDraft);
    await repo.discardDraft(oldDraft);
    expect((await repo.loadDraft())?.requestId, freshDraft.requestId);

    await repo.discardDraft(freshDraft);
    expect(await repo.loadDraft(), isNull);
  });

  test('同一账号的跨页面清理与新保存共享串行队列', () async {
    final oldDraft = _draft('85b72033-9f07-4bbc-8567-fc31f26508ab');
    final freshDraft = _draft('b24e1e23-1af9-4fdf-831c-9e79eb1c9b59');
    final reopened = ApiReviews(api, account);

    await repo.saveDraft(oldDraft);
    await Future.wait([
      repo.discardDraft(oldDraft),
      reopened.saveDraft(freshDraft),
    ]);

    expect((await repo.loadDraft())?.requestId, freshDraft.requestId);
  });

  test('自动保存中的部分草稿可以恢复，完成态仍要求五段齐全', () async {
    final partial = ReviewDraft(
      requestId: '85b72033-9f07-4bbc-8567-fc31f26508ab',
      happened: '只写完了第一段',
      myFeeling: '',
      theirFeeling: '',
      myAction: '',
      nextAction: '',
    );
    await repo.saveDraft(partial);

    final restored = await repo.loadDraft();
    expect(restored, isNotNull);
    expect(restored!.requestId, partial.requestId);
    expect(restored.happened, '只写完了第一段');
    expect(restored.myFeeling, isEmpty);
    expect(restored.toWire(), partial.toWire());

    expect(
      () => ReviewDraft.fromJson(partial.toCacheJson()),
      throwsFormatException,
    );
  });
}
