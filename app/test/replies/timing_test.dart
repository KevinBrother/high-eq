import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/contacts/models.dart';
import 'package:high_eq/features/replies/page.dart';
import 'package:high_eq/features/replies/repository.dart';
import 'package:high_eq/features/replies/result.dart';

const _draft = '合成一\n合成二\n合成三\n合成四\n合成五\n合成六\n合成七';
const _oldName = '合成甲';
const _newName = '合成乙';
const _retryRosterText = '关系人未载入 · 重试（也可不选）';

Contact _person(String id, String name) => Contact.fromJson({
  'id': id,
  'nickname': name,
  'scene': 'work',
  'editable': true,
  'profile': <String, Object?>{},
});

final _oldPerson = _person('old', _oldName);
final _newPerson = _person('new', _newName);

class _TimingRepo implements ReplyRepository {
  var consent = true;
  var available = <Contact>[_oldPerson, _newPerson];
  Object? contactsFailure;
  Completer<List<Contact>>? heldContacts;
  Future<ReplyResult> Function(Json)? analyzeWith;
  final calls = <Json>[];
  late Completer<ReplyResult> response;

  @override
  Future<bool> allowed() async => consent;

  @override
  Future<String?> replyConsentId() async =>
      await allowed() ? 'fixture-reply' : null;

  @override
  Future<ReplyContactAccess> contactAccess() async => (
    consentId: 'fixture-contact',
    people: await contacts(verifyConsent: true),
  );

  @override
  Future<void> grant() async {
    consent = true;
  }

  @override
  Future<List<Contact>> contacts({bool verifyConsent = false}) async {
    final failure = contactsFailure;
    if (failure != null) throw failure;
    final held = heldContacts;
    if (held != null) {
      heldContacts = null;
      return held.future;
    }
    return List.of(available);
  }

  @override
  Future<ReplyQuota?> quota() async => null;

  @override
  Future<ReplyResult> analyze(
    Json input, {
    ReplyAuthorization? authorization,
    void Function()? checkBeforeSend,
  }) {
    checkBeforeSend?.call();
    calls.add(input);
    final delegate = analyzeWith;
    if (delegate != null) return delegate(input);
    response = Completer<ReplyResult>();
    return response.future;
  }

  @override
  Future<void> feedback(
    String id,
    int index,
    String outcome, [
    String? selfReport,
  ]) async {}
}

Future<void> _mount(WidgetTester tester, _TimingRepo repo) async {
  await tester.pumpWidget(
    MaterialApp(home: ReplyPage(repo, sharedText: _draft)),
  );
  await tester.pumpAndSettle();
}

Future<void> _choose(WidgetTester tester, String name) async {
  final dropdown = find.byType(DropdownButtonFormField<String>);
  await tester.ensureVisible(dropdown);
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(find.text(name).last);
  await tester.pumpAndSettle();
}

Future<void> _tapAnalyze(WidgetTester tester, {bool settle = true}) async {
  final button = find.byKey(const ValueKey('reply-analyze'));
  await tester.ensureVisible(button);
  await tester.tap(button);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

void _expectChoiceGate(WidgetTester tester, _TimingRepo repo) {
  expect(repo.calls, hasLength(1));
  expect(find.text('请改选或取消关联'), findsOneWidget);
  final button = tester.widget<FilledButton>(
    find.byKey(const ValueKey('reply-analyze')),
  );
  expect(button.onPressed, isNull);
  expect(
    tester.widget<TextField>(find.byType(TextField).first).controller!.text,
    _draft,
  );
}

void main() {
  testWidgets('06 名册迟到发现关系人失效后必须显式选择才能继续', (tester) async {
    final repo = _TimingRepo();
    await _mount(tester, repo);
    await _choose(tester, _oldName);

    repo.analyzeWith = (_) async {
      repo.available = [_newPerson];
      repo.contactsFailure = StateError('synthetic roster failure');
      throw const ApiFailure(403, 'forbidden', '合成权限响应', false);
    };
    await _tapAnalyze(tester);
    expect(repo.calls, hasLength(1));
    expect(find.text(_retryRosterText), findsOneWidget);

    repo.contactsFailure = null;
    await tester.tap(find.text(_retryRosterText));
    await tester.pumpAndSettle();

    _expectChoiceGate(tester, repo);
    await _tapAnalyze(tester);
    expect(repo.calls, hasLength(1));
  });

  testWidgets('07 授权撤回后重新同意不能解除关系人选择门禁', (tester) async {
    final repo = _TimingRepo();
    await _mount(tester, repo);
    await _choose(tester, _oldName);

    repo.analyzeWith = (_) async {
      repo.available = [];
      repo.consent = false;
      throw const ApiFailure(403, 'forbidden', '合成权限响应', false);
    };
    await _tapAnalyze(tester);

    _expectChoiceGate(tester, repo);
    await tester.tap(find.byKey(const ValueKey('reply-accept-import')));
    await tester.pumpAndSettle();

    _expectChoiceGate(tester, repo);
    await _tapAnalyze(tester);
    expect(repo.calls, hasLength(1));
  });

  testWidgets('08 迟到的旧名册不得覆盖用户明确选择的新关系人', (tester) async {
    final repo = _TimingRepo();
    await _mount(tester, repo);
    await _choose(tester, _oldName);

    repo.analyzeWith = (_) async {
      repo.contactsFailure = StateError('synthetic roster failure');
      throw const ApiFailure(403, 'forbidden', '合成权限响应', false);
    };
    await _tapAnalyze(tester);
    expect(find.text(_retryRosterText), findsOneWidget);

    repo.contactsFailure = null;
    final held = Completer<List<Contact>>();
    repo.heldContacts = held;
    await tester.tap(find.text(_retryRosterText));
    await tester.pump();
    await _choose(tester, _newName);

    held.complete([_oldPerson]);
    await tester.pumpAndSettle();

    final dropdown = tester.widget<DropdownButtonFormField<String>>(
      find.byType(DropdownButtonFormField<String>),
    );
    expect(dropdown.initialValue, 'new');
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      _draft,
    );

    repo.analyzeWith = null;
    await _tapAnalyze(tester, settle: false);
    expect(repo.calls, hasLength(2));
    expect(repo.calls.last['contact_id'], 'new');
    repo.response.complete(Processing());
    await tester.pumpAndSettle();
  });
  testWidgets('旧请求迟到的终止错误不能覆盖已经失效的关系人选择', (tester) async {
    final repo = _TimingRepo();
    await _mount(tester, repo);
    await _choose(tester, _oldName);

    repo.analyzeWith = (_) async {
      repo.contactsFailure = StateError('synthetic roster failure');
      throw const ApiFailure(403, 'forbidden', '合成权限响应', false);
    };
    await _tapAnalyze(tester);
    expect(repo.calls, hasLength(1));
    repo.contactsFailure = null;
    final held = repo.heldContacts = Completer<List<Contact>>();
    await tester.tap(find.text(_retryRosterText));
    await tester.pump();
    expect(repo.heldContacts, isNull);

    repo.analyzeWith = null;
    await _tapAnalyze(tester, settle: false);
    expect(repo.calls, hasLength(2));
    expect(repo.calls.last, repo.calls.first);

    repo.available = [_newPerson];
    held.complete(repo.available);
    await tester.pump();
    expect(find.text('请改选或取消关联'), findsOneWidget);
    repo.response.completeError(
      const ApiFailure(500, 'internal_error', '合成旧请求已终止', false),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('本次分析已结束'), findsNothing);
    expect(find.text('请改选或取消关联'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      _draft,
    );
    await _choose(tester, _newName);
    expect(repo.calls, hasLength(2));
    await _tapAnalyze(tester, settle: false);
    expect(repo.calls, hasLength(3));
    expect(repo.calls.last['contact_id'], 'new');
    expect(
      repo.calls.last['request_id'],
      isNot(repo.calls.first['request_id']),
    );
    repo.response.complete(Processing());
    await tester.pumpAndSettle();
  });
}
