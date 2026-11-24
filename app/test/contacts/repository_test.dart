import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/providers.dart';
import 'package:high_eq/core/endpoints.g.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/features/contacts/deletion.dart';
import 'package:high_eq/features/contacts/models.dart';
import 'package:high_eq/features/contacts/purpose.dart';
import 'package:high_eq/features/contacts/repository.dart';
import 'package:high_eq/features/contacts/routes.dart';
import 'package:high_eq/features/contacts/scene.dart';
import 'package:high_eq/features/growth/cache.dart';
import 'package:high_eq/features/growth/repository.dart';
import '../client_test.dart' show Handler, response;
import '../growth/support/fakes.dart' show sampleSnapshot;
import '../isolation_test.dart' show MemorySecret, tokens;
import '../support/real_async.dart';

void main() {
  late Directory dir;
  late Directory fenceDir;
  late MemorySecret secret;
  late Sessions sessions;
  late AppApi api;
  late Handler wire;
  late AccountScope a;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp();
    fenceDir = await Directory.systemTemp.createTemp();
    secret = MemorySecret();
    sessions = Sessions(secret, dir, growthDeletionDirectory: fenceDir);
    a = await sessions.activate(tokens('A'));
    wire = Handler();
    api = AppApi(Uri.https('wire.invalid'), wire, sessions);
  });
  tearDown(() async {
    await dir.delete(recursive: true);
    await fenceDir.delete(recursive: true);
  });
  test('分页、携带令牌的真实客户端映射、删除 Ack 与过期 scope', () async {
    final fixtures = jsonDecode(
      await File('assets/contract_examples.json').readAsString(),
    );
    final calls = <AppOp>[];
    final repo = ApiContacts(MobileEndpoints(api), a);
    wire.handle = (op, req) async {
      calls.add(op);
      expect(req.headers['Authorization'], 'Bearer access');
      if (op == AppOp.listContacts) {
        final after = req.url.queryParameters['cursor'];
        return response(
          after == null
              ? {...fixtures[op.name] as Map, 'next_cursor': 'page2'}
              : {'items': [], 'next_cursor': null},
        );
      }
      if (op == AppOp.inferProfile) {
        expect(req.method, 'POST');
        expect(jsonDecode(req.body)['chat_text'], '合成片段');
        expect(req.url.path, endsWith('/infer'));
      }
      if (op == AppOp.deleteContact) {
        expect(req.method, 'DELETE');
        return response({'ok': false});
      }
      return response(fixtures[op.name]);
    };
    final b = await repo.load();
    final c = b.people.single;
    expect(b.usable(c), true);
    expect(b.canAdd, false);
    final q = await repo.questions();
    expect(q.length, 5);
    await repo.save({
      'nickname': '同事',
      'scene': 'work',
      'answers': [
        {'question_id': q.first.id, 'answer': '还不确定'},
      ],
    });
    await repo.save({'nickname': '同事', 'scene': 'work'}, id: c.id);
    await repo.choose(c.id);
    await repo.infer(c.id, newRequestId(), '合成片段');
    await expectLater(repo.remove(c.id), throwsFormatException);
    expect(calls, [
      AppOp.listContacts,
      AppOp.listContacts,
      AppOp.getEntitlements,
      AppOp.getContactQuestions,
      AppOp.createContact,
      AppOp.editContact,
      AppOp.chooseContact,
      AppOp.inferProfile,
      AppOp.deleteContact,
    ]);
    await sessions.activate(tokens('B'));
    await expectLater(repo.questions(), throwsA(isA<SessionChanged>()));
    expect(calls.length, 9);
  });
  test('用途按分页和版本读取；拒绝错误回执，不把另一用途当成同意', () async {
    final repo = ApiContacts(MobileEndpoints(api), a);
    wire.handle = (op, req) async {
      if (op == AppOp.setConsent) {
        expect(req.url.path, endsWith('/consents/chat_import'));
        expect(jsonDecode(req.body), {
          'version': contactNoticeVersion,
          'granted': true,
        });
        return response({
          'purpose': 'contacts',
          'version': contactNoticeVersion,
          'granted': true,
        });
      }
      expect(op, AppOp.listConsents);
      if (req.url.queryParameters['cursor'] == null) {
        return response({
          'items': [
            {'purpose': 'contacts', 'version': 'old', 'granted': true},
          ],
          'next_cursor': 'p2',
        });
      }
      return response({
        'items': [
          {
            'purpose': 'chat_import',
            'version': contactNoticeVersion,
            'granted': true,
          },
        ],
        'next_cursor': null,
      });
    };
    expect(await repo.currentGrants(), {ContactPurpose.chatImport});
    await expectLater(
      repo.grant(ContactPurpose.chatImport),
      throwsA(isA<ConsentUnconfirmed>()),
    );
  });
  test('退出/换号丢弃全局场景和关系人仓库', () async {
    final box = ProviderContainer(
      overrides: [apiProvider.overrideWith((_) async => api)],
    );
    addTearDown(box.dispose);
    await box.read(apiProvider.future);
    final first = box.read(contactSpaceProvider);
    first.scene.value = Scene.partner;
    await sessions.clear();
    expect(box.read(contactSpaceProvider).repo, isNull);
    await sessions.activate(tokens('B'));
    final next = box.read(contactSpaceProvider);
    expect(next.scene.value, Scene.work);
    expect(identical(first.repo, next.repo), false);
  });
  testWidgets('关系人路由确认删除后清理同一账号的成长缓存', (tester) async {
    final fixtures =
        jsonDecode(
              await runRealAsync(
                tester,
                () => File('assets/contract_examples.json').readAsString(),
              ),
            )
            as Map<String, dynamic>;
    var deleted = false;
    wire.handle = (op, request) async {
      if (op == AppOp.deleteContact) {
        deleted = true;
        return response({'ok': true});
      }
      if (op == AppOp.listContacts && deleted) {
        return response({'items': <Object>[], 'next_cursor': null});
      }
      return response(fixtures[op.name] as Map);
    };
    final container = ProviderContainer(
      overrides: [apiProvider.overrideWith((_) async => api)],
    );
    addTearDown(container.dispose);
    await container.read(apiProvider.future);
    final growth = container.read(growthRepositoryProvider)!;
    await runRealAsync(tester, () => growth.saveCache(sampleSnapshot()));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ContactRoute(sceneOnly: false)),
      ),
    );
    await _pumpUntil(tester, find.text('同事 A'));
    await tester.tap(find.text('同事 A'));
    await tester.pumpAndSettle();
    final remove = find.text('删除关系人');
    await tester.ensureVisible(remove);
    await tester.tap(remove);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认删除'));
    await tester.pump();
    await _pumpUntil(tester, find.text('关系人已删除。'));

    expect(find.text('同事 A'), findsNothing);
    expect(find.text('关系人已删除。'), findsOneWidget);
    expect(await runRealAsync(tester, growth.cached), isNull);
  });

  testWidgets('提交后丢回执，列表即使已空仍可只读核对并重建离线成长', (tester) async {
    final fixtures =
        jsonDecode(
              await runRealAsync(
                tester,
                () => File('assets/contract_examples.json').readAsString(),
              ),
            )
            as Map<String, dynamic>;
    final contactId = fixtures['listContacts']['items'][0]['id'];
    var deleted = false, growthOffline = false;
    var writes = 0, checks = 0;
    wire.handle = (op, request) async {
      switch (op) {
        case AppOp.deleteContact:
          writes++;
          deleted = true;
          throw StateError('丢失回执');
        case AppOp.listContacts when deleted:
          return response({'items': [], 'next_cursor': null});
        case AppOp.getContactSummary:
          checks++;
          expect(request.method, 'GET');
          expect(request.url.path, '/v1/contacts/$contactId/summary');
          expect(deleted, isTrue);
          return response({'code': 'contact_not_found'}, 404);
        case AppOp.getGrowth when growthOffline:
          return response({'code': 'service_unavailable'}, 503);
        case AppOp.getGrowth:
          return response({
            ...fixtures[op.name] as Map,
            'training_reference': deleted ? null : 70,
          });
        default:
          return response(fixtures[op.name] as Map);
      }
    };
    final container = ProviderContainer(
      overrides: [apiProvider.overrideWith((_) async => api)],
    );
    addTearDown(container.dispose);
    await container.read(apiProvider.future);
    final growth = container.read(growthRepositoryProvider)!;

    Future<T> readGrowth<T>(Future<T> Function() read) async {
      // ContactRoute queues deletion reads in FakeAsync on the same Sessions.
      // Drive that queue and the real file I/O until this read has settled.
      var completed = false;
      final result = read().whenComplete(() {
        completed = true;
      });
      // The offline assertion below handles the original error after pumping.
      result.ignore();
      await pumpRealAsyncUntil(tester, () => completed, reason: '成长档案读取未完成');
      return result;
    }

    await readGrowth(growth.load);
    expect((await readGrowth(growth.cached))!.growth.trainingReference, 70);

    const app = MaterialApp(home: ContactRoute(sceneOnly: false));
    Future<void> openContacts() => tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: app),
    );
    await openContacts();
    await _pumpUntil(tester, find.text('同事 A'));
    await tester.tap(find.text('同事 A'));
    await tester.pumpAndSettle();
    final remove = find.text('删除关系人');
    await tester.ensureVisible(remove);
    await tester.tap(remove);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认删除'));
    final check = find.text('核对删除结果');
    await _pumpUntil(tester, check);
    expect(find.text('同事 A'), findsNothing);
    expect(find.textContaining('暂时无法确认删除结果'), findsOneWidget);
    expect(checks, 0);
    expect((await readGrowth(growth.load)).growth.trainingReference, isNull);
    expect(await readGrowth(growth.cached), isNull);

    await tester.pumpWidget(const SizedBox());
    await openContacts();
    await _pumpUntil(tester, check);
    expect(checks, 0);
    await tester.tap(check);
    await _pumpUntil(tester, find.textContaining('已核实 1 笔删除'));
    expect(writes, 1);
    expect(checks, 1);
    expect(check, findsNothing);
    expect(find.textContaining('联网打开成长档案'), findsOneWidget);
    await readGrowth(growth.load);
    growthOffline = true;
    await expectLater(readGrowth(growth.load), throwsA(isA<ApiFailure>()));
    final offline = await readGrowth(growth.cached);
    expect(offline, isNotNull);
    expect(offline!.growth.trainingReference, isNull);
  });

  test('确认写盘失败后冷重开，用只读 404 恢复成长缓存', () async {
    final fixtures =
        jsonDecode(await File('assets/contract_examples.json').readAsString())
            as Map<String, dynamic>;
    final id = fixtures['listContacts']['items'][0]['id'] as String;
    final cache = GrowthCache(sessions, a);
    addTearDown(cache.dispose);
    final deletion = ApiContactDeletion(
      ApiContacts(MobileEndpoints(api), a),
      cache,
    );
    final growth = ApiGrowthRepository(api, a, cache: cache);
    await growth.saveCache(sampleSnapshot());
    late Directory blockedWrite;
    var writes = 0, checks = 0;
    wire.handle = (op, _) async {
      if (op == AppOp.deleteContact) {
        writes++;
        final file = await fenceDir
            .list()
            .where((entry) => entry is File)
            .single;
        blockedWrite = await Directory('${file.path}.tmp').create();
        return response({'ok': true});
      }
      if (op == AppOp.getContactSummary) {
        checks++;
        return response({'code': 'contact_not_found'}, 404);
      }
      return response(fixtures[op.name] as Map);
    };
    await expectLater(
      deletion.remove(id),
      throwsA(isA<DeletionCacheUnconfirmed>()),
    );
    final operation = (await deletion.pending()).single;
    expect(operation.contactId, id);
    final journal =
        await fenceDir.list().where((entry) => entry is File).single as File;
    expect(jsonDecode(await journal.readAsString()), {
      id: operation.operationId,
    });
    expect(await growth.cached(), isNull);
    await blockedWrite.delete();

    final restarted = Sessions(secret, dir, growthDeletionDirectory: fenceDir);
    await restarted.restore();
    final scope = restarted.active!;
    final reopenedApi = AppApi(api.origin, wire, restarted);
    final reopenedCache = GrowthCache(restarted, scope);
    addTearDown(reopenedCache.dispose);
    final reopenedGrowth = ApiGrowthRepository(
      reopenedApi,
      scope,
      cache: reopenedCache,
    );
    final reopenedDeletion = ApiContactDeletion(
      ApiContacts(MobileEndpoints(reopenedApi), scope),
      reopenedCache,
    );
    expect(await reopenedDeletion.pending(), [operation]);
    await reopenedGrowth.load();
    expect(await reopenedGrowth.cached(), isNull);
    expect(await reopenedDeletion.check(operation), DeletionCheck.absent);
    expect(await reopenedDeletion.pending(), isEmpty);
    expect(await reopenedGrowth.cached(), isNull);
    await reopenedGrowth.load();
    expect((await reopenedGrowth.cached())!.growth.trainingReference, isNull);
    expect(writes, 1);
    expect(checks, 1);
  });

  test('只读核对失败保留围栏；关系人仍在时可放弃或明确重试', () async {
    final fixtures =
        jsonDecode(await File('assets/contract_examples.json').readAsString())
            as Map<String, dynamic>;
    final cache = GrowthCache(sessions, a);
    addTearDown(cache.dispose);
    final deletion = ApiContactDeletion(
      ApiContacts(MobileEndpoints(api), a),
      cache,
    );
    final growth = ApiGrowthRepository(api, a, cache: cache);
    final id = fixtures['listContacts']['items'][0]['id'] as String;
    var status = 503, writes = 0;
    var acceptWrite = false;
    wire.handle = (op, _) async {
      if (op == AppOp.deleteContact) {
        writes++;
        if (!acceptWrite) throw StateError('请求未提交');
        return response({'ok': true});
      }
      if (op == AppOp.getContactSummary && status != 200) {
        return response({
          'code': status == 404 ? 'not_found' : 'unavailable',
        }, status);
      }
      return response(fixtures[op.name] as Map);
    };
    await growth.saveCache(sampleSnapshot());
    await expectLater(deletion.remove(id), throwsStateError);
    final original = (await deletion.pending()).single;
    for (status in [503, 403, 404]) {
      await expectLater(deletion.check(original), throwsA(isA<ApiFailure>()));
      expect(await deletion.pending(), [original]);
      expect(await growth.cached(), isNull);
    }
    status = 200;
    expect(await deletion.check(original), DeletionCheck.present);
    expect(await deletion.pending(), [original]);
    expect(writes, 1);
    expect(
      await deletion.check(original, abandon: true),
      DeletionCheck.abandoned,
    );
    expect(await deletion.pending(), isEmpty);
    expect(writes, 1);
    await growth.load();
    expect(await growth.cached(), isNotNull);

    await expectLater(deletion.remove(id), throwsStateError);
    final failed = (await deletion.pending()).single;
    expect(failed.operationId, isNot(original.operationId));
    expect(await deletion.check(failed), DeletionCheck.present);
    expect(writes, 2);
    acceptWrite = true;
    await deletion.remove(id, retry: failed);
    expect(writes, 3);
    expect(await deletion.pending(), isEmpty);
  });

  test('认证失败或刷新接口的 404 不作为指定关系人的缺失证据', () async {
    final scope = await sessions.activate(
      Tokens('A', 'expired', 'refresh', DateTime.utc(2000)),
    );
    final cache = GrowthCache(sessions, scope);
    addTearDown(cache.dispose);
    final deletion = ApiContactDeletion(
      ApiContacts(MobileEndpoints(api), scope),
      cache,
    );
    final operation = await cache.prepareDeletion(
      '85b72033-9f07-4bbc-8567-fc31f26508ab',
    );
    var status = 404;
    final calls = <AppOp>[];
    wire.handle = (op, _) async {
      calls.add(op);
      return response({
        'code': status == 404 ? 'contact_not_found' : 'unauthenticated',
      }, status);
    };
    await expectLater(deletion.check(operation), throwsA(isA<ApiFailure>()));
    expect(await deletion.pending(), [operation]);
    status = 401;
    await expectLater(deletion.check(operation), throwsA(isA<ApiFailure>()));
    expect(sessions.active, isNull);
    expect(calls, [AppOp.refreshTokens, AppOp.refreshTokens]);
    final relogged = GrowthCache(
      sessions,
      await sessions.activate(tokens('A')),
    );
    addTearDown(relogged.dispose);
    expect(await relogged.pendingDeletions(), [operation]);
  });

  test('问题数量越界或重复不进入向导，权限矛盾不开放选择或反馈', () {
    for (final size in [4, 9, 6]) {
      expect(
        () => questionsFrom({
          'items': List.generate(
            size,
            (i) => {'id': size == 6 ? 'duplicate' : '$i', 'prompt': '?'},
          ),
        }),
        throwsFormatException,
      );
    }
    final row = {
      'id': '1',
      'nickname': 'X',
      'scene': 'work',
      'editable': true,
      'profile': <String, dynamic>{},
    };
    final c = Contact.fromJson(row);
    final b = Book(
      [
        c,
        Contact.fromJson({...row, 'id': '2'}),
      ],
      {'tier': 'free', 'max_active_contacts': 1},
    );
    expect(b.canAdd, false);
    expect(b.usable(c), false);
  });
}

Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  await pumpRealAsyncUntil(
    tester,
    () =>
        finder.evaluate().isNotEmpty &&
        find.byType(LinearProgressIndicator).evaluate().isEmpty,
    reason: '关系人删除后的真实缓存清理未完成',
  );
}
