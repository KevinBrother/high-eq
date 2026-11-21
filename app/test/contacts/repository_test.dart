import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/providers.dart';
import 'package:high_eq/core/endpoints.g.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/features/contacts/models.dart';
import 'package:high_eq/features/contacts/purpose.dart';
import 'package:high_eq/features/contacts/repository.dart';
import 'package:high_eq/features/contacts/routes.dart';
import 'package:high_eq/features/contacts/scene.dart';
import '../client_test.dart' show Handler, response;
import '../isolation_test.dart' show MemorySecret, tokens;

void main() {
  late Directory dir;
  late Sessions sessions;
  late AppApi api;
  late Handler wire;
  late AccountScope a;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp();
    sessions = Sessions(MemorySecret(), dir);
    a = await sessions.activate(tokens('A'));
    wire = Handler();
    api = AppApi(Uri.https('wire.invalid'), wire, sessions);
  });
  tearDown(() => dir.delete(recursive: true));
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
