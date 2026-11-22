import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/providers.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/features/contacts/scene.dart';
import 'package:high_eq/features/practice/providers.dart';
import 'package:high_eq/features/practice/repository.dart';

import '../client_test.dart' show Handler, response;
import '../isolation_test.dart' show MemorySecret, tokens;

void main() {
  late Directory directory;
  late Sessions sessions;
  late Handler wire;
  late AppApi api;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('t27-practice-provider-');
    sessions = Sessions(MemorySecret(), directory);
    wire = Handler();
    api = AppApi(Uri.https('wire.invalid'), wire, sessions);
  });

  tearDown(() => directory.delete(recursive: true));

  test('真实仓库在 A→B 后使用 B 作用域，A 的在途写入不能落到 B', () async {
    final a = await sessions.activate(tokens('A', 'access-a'));
    final container = ProviderContainer(
      overrides: [apiProvider.overrideWith((_) async => api)],
    );
    addTearDown(container.dispose);
    await container.read(apiProvider.future);

    final oldRepo = container.read(practiceRepositoryProvider) as ApiPractice;
    expect(oldRepo.scope, same(a));
    final lateWrite = oldRepo.remember('draft', {'text': 'A draft'});

    await sessions.clear();
    final b = await sessions.activate(tokens('B', 'access-b'));
    final newRepo = container.read(practiceRepositoryProvider) as ApiPractice;
    expect(newRepo, isNot(same(oldRepo)));
    expect(newRepo.scope, same(b));

    wire.handle = (op, req) async {
      expect(op, AppOp.listLevels);
      expect(req.headers['Authorization'], 'Bearer access-b');
      return response({'items': [], 'next_cursor': null});
    };
    await newRepo.levels(Scene.work, null);

    await expectLater(lateWrite, throwsA(isA<SessionChanged>()));
    expect(await newRepo.read('draft'), isNull);
  });

  test('同一账号重新认证后真实仓库使用新作用域，旧在途写入不能落到新会话', () async {
    final first = await sessions.activate(tokens('A', 'access-old'));
    final container = ProviderContainer(
      overrides: [apiProvider.overrideWith((_) async => api)],
    );
    addTearDown(container.dispose);
    await container.read(apiProvider.future);

    final oldRepo = container.read(practiceRepositoryProvider) as ApiPractice;
    expect(oldRepo.scope, same(first));
    final lateWrite = oldRepo.remember('draft', {'text': 'old session'});

    await sessions.clear();
    final next = await sessions.activate(tokens('A', 'access-new'));
    final newRepo = container.read(practiceRepositoryProvider) as ApiPractice;
    expect(newRepo, isNot(same(oldRepo)));
    expect(newRepo.scope, same(next));
    expect(newRepo.scope, isNot(same(first)));

    wire.handle = (op, req) async {
      expect(op, AppOp.listLevels);
      expect(req.headers['Authorization'], 'Bearer access-new');
      return response({'items': [], 'next_cursor': null});
    };
    await newRepo.levels(Scene.work, null);

    await expectLater(lateWrite, throwsA(isA<SessionChanged>()));
    expect(await newRepo.read('draft'), isNull);
  });
}
