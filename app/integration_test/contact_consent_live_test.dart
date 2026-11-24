import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:http/http.dart' as http;
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/endpoints.g.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/contacts/purpose.dart';
import 'package:high_eq/features/contacts/repository.dart';
import 'package:high_eq/features/contacts/scene.dart';
import 'package:high_eq/features/contacts/workspace.dart';

class _Volatile implements SecretStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> replace(String? v) async {
    value = v;
  }
}

// Count real HTTP operations/status only, never store request bodies or headers.
class _Wire extends HttpTransport {
  _Wire() : super(http.Client());
  final sent = <AppOp>[];
  int? inferStatus;
  @override
  Future<http.StreamedResponse> send(AppOp op, http.Request request) async {
    sent.add(op);
    final response = await super.send(op, request);
    if (op == AppOp.inferProfile) inferStatus = response.statusCode;
    return response;
  }

  int count(AppOp op) => sent.where((v) => v == op).length;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const port = int.fromEnvironment('T18_LOCAL_PORT');
  const ticket = String.fromEnvironment('T18_DEV_TICKET');
  testWidgets('真实首用：拒绝无写入、分别授权、填表后撤回不上传、再次同意不重放', (t) async {
    final wire = _Wire();
    addTearDown(wire.close);
    final dir = await Directory.systemTemp.createTemp('t18-consent');
    addTearDown(() => dir.delete(recursive: true));
    final sessions = Sessions(_Volatile(), dir);
    final api = MobileEndpoints(
      AppApi(Uri.http('127.0.0.1:$port'), wire, sessions),
    );
    final scope = await sessions.activate(
      Tokens.fromJson(
        await api.login(
          body: {
            'credential': {'provider': 'apple', 'proof': ticket},
            'age_confirmed': true,
            'terms_version': '2026-11',
            'privacy_version': '2026-11',
          },
        ),
      ),
    );
    final repo = ApiContacts(api, scope);
    Future<void> tap(String label) async {
      await t.pump();
      final f = find.text(label).last;
      await t.ensureVisible(f);
      await t.tap(f);
      await t.pumpAndSettle();
    }

    Future<void> revoke(ContactPurpose p) async {
      await api.setConsent(
        scope: scope,
        purpose: p.wire,
        body: {'version': contactNoticeVersion, 'granted': false},
      );
    }

    await t.pumpWidget(
      MaterialApp(
        home: ContactsWorkspace(repo: repo, selection: SceneMemory()),
      ),
    );
    await t.pumpAndSettle();
    expect((await repo.currentConsents()).grants, isEmpty);
    await tap('添加关系人');
    await tap('暂不同意');
    expect(wire.count(AppOp.setConsent), 0);
    expect(wire.count(AppOp.createContact), 0);
    await tap('添加关系人');
    await tap('同意并继续');
    expect((await repo.currentConsents()).grants, {ContactPurpose.contacts});
    final n = (await repo.questions()).length;
    Future<void> fillNameAndQuestions() async {
      await t.enterText(find.byType(TextField), '合成手记');
      await tap('下一步');
      for (var i = 0; i < n; i++) {
        await tap('还不确定');
        if (i < n - 1) await tap('下一步');
      }
    }

    await fillNameAndQuestions();
    await revoke(ContactPurpose.contacts);
    await tap('保存关系人');
    expect(find.text('允许建立关系人手记？'), findsOneWidget);
    expect(wire.count(AppOp.createContact), 0);
    await tap('同意并继续');
    expect(wire.count(AppOp.createContact), 0);
    await fillNameAndQuestions();
    await tap('保存关系人');
    expect((await repo.load()).people.single.name, '合成手记');
    await tap('合成手记');
    await tap('导入聊天片段');
    await tap('暂不同意');
    expect((await repo.currentConsents()).grants, {ContactPurpose.contacts});
    expect(wire.count(AppOp.inferProfile), 0);
    await tap('导入聊天片段');
    await tap('同意并继续');
    expect(
      (await repo.currentConsents()).grants,
      ContactPurpose.values.toSet(),
    );
    await tap('我已了解，并有权分享这段内容');
    await t.enterText(find.byType(TextField), '合成的未发送片段');
    await revoke(ContactPurpose.chatImport);
    await tap('提交片段');
    expect(find.text('允许使用聊天片段推断画像？'), findsOneWidget);
    expect(wire.count(AppOp.inferProfile), 0);
    expect((await repo.currentConsents()).grants, {ContactPurpose.contacts});
    await tap('同意并继续');
    expect(wire.count(AppOp.inferProfile), 0);
    await tap('我已了解，并有权分享这段内容');
    expect(
      t.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    final before = (await repo.load()).people.single.profile;
    await t.enterText(find.byType(TextField), '重新输入的合成片段');
    await tap('提交片段');
    expect(wire.count(AppOp.inferProfile), 1);
    expect(
      wire.inferStatus,
      isIn([500, 503]),
      reason:
          'no approved model/route is configured in this disposable service',
    );
    expect((await repo.load()).people.single.profile, before);
    expect(find.textContaining('画像已更新'), findsNothing);
  }, skip: port == 0 || ticket.isEmpty);
}
