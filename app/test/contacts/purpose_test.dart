import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/features/contacts/inference.dart';
import 'package:high_eq/features/contacts/purpose.dart';
import 'flows_test.dart' show Fixture, open, tap;

class _Grants extends Fixture {
  final grants = <ContactPurpose>{};
  final writes = <ContactPurpose>[];
  int sends = 0;
  @override
  Future<ContactConsentSnapshot> currentConsents() async =>
      ContactConsentSnapshot('fixture', {
        for (final purpose in grants) purpose: 'fixture-${purpose.wire}',
      });
  @override
  Future<void> grant(ContactPurpose p) async {
    writes.add(p);
    grants.add(p);
  }

  @override
  Future<ProfileInferenceResult> infer(
    String id,
    String requestId,
    String text, {
    required ContactInferenceGrant authorization,
  }) async {
    sends++;
    return super.infer(id, requestId, text, authorization: authorization);
  }
}

void main() {
  testWidgets('新增前单独取得关系人用途授权；拒绝不进入问答、不写入', (t) async {
    final f = Fixture();
    for (final c in (await f.load()).people) {
      await f.remove(c.id);
    }
    await open(t, f);
    await tap(t, '添加关系人');
    expect(find.text('允许建立关系人手记？'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await tap(t, '暂不同意');
    expect(f.saved, isNull);
    await tap(t, '添加关系人');
    await tap(t, '同意并继续');
    expect(find.text('怎么称呼对方？'), findsOneWidget);
  });
  testWidgets('聊天授权不能替代关系人授权；提交前关系人撤回不发送或自动补授', (t) async {
    final f = _Grants()..grants.add(ContactPurpose.chatImport);
    await open(t, f);
    await tap(t, '同事 A');
    await tap(t, '导入聊天片段');
    expect(find.text('允许建立关系人手记？'), findsOneWidget);
    await tap(t, '同意并继续');
    expect(f.writes, [ContactPurpose.contacts]);
    await tap(t, '我已了解，并有权分享这段内容');
    await t.enterText(find.byType(TextField), '合成片段');
    f.grants.remove(ContactPurpose.contacts);
    await tap(t, '提交片段');
    expect(find.text('允许建立关系人手记？'), findsOneWidget);
    expect(f.sends, 0);
    expect(f.writes, [ContactPurpose.contacts]);
    await tap(t, '暂不同意');
    expect(f.sends, 0);
    expect(f.grants, {ContactPurpose.chatImport});
  });
}
