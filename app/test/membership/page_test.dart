import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/membership/page.dart';
import 'package:high_eq/features/membership/store.dart';
import '../isolation_test.dart' show MemorySecret, tokens;

class _Rights extends MemberStore {
  final bool advertised;
  _Rights(super.api, super.scope, this.advertised);
  @override
  Future<Json> rights() async => {
    'tier': 'free',
    'expires_at': null,
    'max_active_contacts': 1,
    'auto_watch_alert_available': advertised,
    'allowances': [
      {
        'feature': 'review',
        'remaining': 0,
        'resets_at': '2026-11-22T00:00:00+08:00',
      },
    ],
  };
  @override
  Future<bool> apple({String? plan}) async =>
      throw const ApiFailure(409, 'conflict', '不属于当前账号', false);
}

class _DeferredRights extends MemberStore {
  _DeferredRights(super.api, super.scope);
  final requests = <Completer<Json>>[];

  @override
  Future<Json> rights() {
    final request = Completer<Json>();
    requests.add(request);
    return request.future;
  }
}

Json _quota(int? remaining) => {
  'tier': remaining == null ? 'member' : 'free',
  'expires_at': remaining == null
      ? DateTime.now().add(const Duration(hours: 1)).toIso8601String()
      : null,
  'allowances': [
    {'feature': 'practice', 'remaining': remaining},
  ],
};

void main() {
  late Sessions session;
  late AccountScope a;
  setUp(() async {
    final dir = await Directory.systemTemp.createTemp();
    addTearDown(() => dir.delete(recursive: true));
    session = Sessions(MemorySecret(), dir);
    a = await session.activate(tokens('A'));
  });
  testWidgets('resume rechecks quota while an older response is pending', (
    t,
  ) async {
    final store = _DeferredRights(
      AppApi(Uri.https('example.invalid'), ExampleTransport(), session),
      a,
    );
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpWidget(MaterialApp(home: MemberPage(store)));
    final olderRead = store.requests.single;
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await t.pump();
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump();
    expect(store.requests, hasLength(2));
    store.requests.last.complete(_quota(3));
    await t.pumpAndSettle();
    expect(find.text('对练 · 剩余 3 次'), findsOneWidget);

    olderRead.complete(_quota(null));
    await t.pumpAndSettle();
    expect(find.text('对练 · 剩余 3 次'), findsOneWidget);
    expect(find.text('对练 · 不限次'), findsNothing);
  });

  testWidgets('a new account lease cannot adopt a late member snapshot', (
    t,
  ) async {
    final api = AppApi(
      Uri.https('example.invalid'),
      ExampleTransport(),
      session,
    );
    final oldStore = _DeferredRights(api, a);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpWidget(MaterialApp(home: MemberPage(oldStore)));
    final olderRead = oldStore.requests.single;

    final b = (await t.runAsync(() => session.activate(tokens('B'))))!;
    final newStore = _DeferredRights(api, b);
    await t.pumpWidget(MaterialApp(home: MemberPage(newStore)));
    expect(newStore.requests, hasLength(1));
    newStore.requests.single.complete(_quota(3));
    await t.pumpAndSettle();
    olderRead.complete(_quota(null));
    await t.pumpAndSettle();
    expect(find.text('对练 · 剩余 3 次'), findsOneWidget);
    expect(find.text('对练 · 不限次'), findsNothing);
  });

  // Release has no matching approval. Neither review outcome nor a stale true
  // from the server can advertise the feature in this binary.
  for (final advertised in [false, true]) {
    testWidgets('未放行的会员页不宣传自动提醒 (服务端开关 $advertised)，限次与账号冲突均可见', (t) async {
      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.iOS),
          home: MemberPage(
            _Rights(
              AppApi(Uri.https('example.invalid'), ExampleTransport(), session),
              a,
              advertised,
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.textContaining('今日限次已用尽'), findsOneWidget);
      for (final s in ['自动提醒', '自动轻震', '自动震动', '实时提醒']) {
        expect(find.textContaining(s), findsNothing);
      }
      final restore = find.text('恢复购买');
      await t.ensureVisible(restore);
      await t.pumpAndSettle();
      await t.tap(restore);
      await t.pumpAndSettle();
      expect(find.textContaining('权益不会转移'), findsOneWidget);
      expect(find.text('退出并验证原账号'), findsOneWidget);
      expect(session.active, a);
    });
  }
}
