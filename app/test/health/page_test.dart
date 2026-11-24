import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/providers.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/health/binding.dart';
import 'package:high_eq/features/health/page.dart';
import 'package:high_eq/features/health/platform.dart';
import 'package:high_eq/features/health/sync.dart';
import 'package:high_eq/main.dart';
import 'package:http/http.dart' as http;
import '../client_test.dart' show Handler, response;
import '../isolation_test.dart' show MemorySecret, tokens;
import 'sync_test.dart' show Synthetic;

class _FailingSecret implements SecretStore {
  _FailingSecret({
    this.failure = const FileSystemException('injected secret cleanup failure'),
  });

  final Object failure;
  String? value;
  int failReplaceCount = 0;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> replace(String? next) async {
    if (failReplaceCount > 0) {
      failReplaceCount--;
      throw failure;
    }
    value = next;
  }
}

Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 60; attempt++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(finder, findsOneWidget);
}

Future<void> _pumpUntilTrue(
  WidgetTester tester,
  bool Function() predicate,
) async {
  for (var attempt = 0; attempt < 60; attempt++) {
    if (predicate()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(predicate(), isTrue);
}

class _LogoutTransport extends Handler {
  _LogoutTransport(this.sessions);

  final Sessions sessions;

  @override
  Future<http.StreamedResponse> send(AppOp op, http.Request request) async {
    if (op == AppOp.getMe) {
      return response({
        'user_id': sessions.active!.account,
        'timezone': 'UTC',
        'bindings': ['phone'],
        'frozen_until': null,
      });
    }
    return super.send(op, request);
  }
}

Future<(Sessions, AccountScope, Handler)> _logoutFixture(
  WidgetTester tester, {
  SecretStore? secret,
  bool explicitWithdrawal = false,
}) async {
  final temp = (await tester.runAsync(
    () => Directory.systemTemp.createTemp(),
  ))!;
  addTearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });
  final sessions = Sessions(secret ?? MemorySecret(), temp);
  final scope = (await tester.runAsync(() => sessions.activate(tokens('A'))))!;
  if (explicitWithdrawal) {
    await tester.runAsync(
      () => sessions.put(
        scope,
        CacheKind.queue,
        AppApi.healthQueueKey,
        utf8.encode(jsonEncode({'mode': 'withdraw', 'withdrawal': 'explicit'})),
      ),
    );
  }
  final handler = _LogoutTransport(sessions)
    ..handle = (op, _) async =>
        response({'items': <Json>[], 'next_cursor': null});
  return (sessions, scope, handler);
}

Future<void> _openLogoutDialog(WidgetTester tester) async {
  final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
  navigator.pushNamed('/me');
  await _pumpUntil(tester, find.text('个人空间'));
  await tester.drag(find.byType(ListView).last, const Offset(0, -500));
  await tester.pump();
  await _pumpUntil(tester, find.text('退出账号'));
  await tester.tap(find.text('退出账号'));
  await _pumpUntil(tester, find.text('退出当前账号？'));
  await tester.tap(find.text('确认退出'));
  await tester.pump();
}

class _Settings extends Fake implements HealthSync {
  bool paid = false;
  int enables = 0;
  int resolves = 0;
  bool? lastResolveWithdraw;
  @override
  final mode = ValueNotifier<String?>('off');
  @override
  final HealthPort port = Synthetic();
  @override
  Future<bool> member() async => paid;
  @override
  Future<Map<String, dynamic>> state() async => {'mode': mode.value};
  @override
  Future<void> enable() async {
    enables++;
    mode.value = 'on';
  }

  @override
  Future<void> resolveUnknown({required bool withdraw}) async {
    resolves++;
    lastResolveWithdraw = withdraw;
    mode.value = withdraw ? 'withdraw' : 'off';
  }
}

void main() {
  late Directory dir;
  late AccountScope a;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp();
    a = await Sessions(MemorySecret(), dir).activate(tokens('fixture'));
  });
  tearDown(() => dir.delete(recursive: true));
  testWidgets(
    'no prompt on visit, non-member or cancel; positive consent is explicit',
    (tester) async {
      final model = _Settings();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [healthProvider(a).overrideWith((_) async => model)],
          child: MaterialApp(home: HealthPage(a)),
        ),
      );
      await tester.pumpAndSettle();
      expect(model.enables, 0);
      await tester.tap(find.text('开启健康数据'));
      await tester.pumpAndSettle();
      expect(find.textContaining('需要有效会员'), findsOneWidget);
      expect(model.enables, 0);
      model.paid = true;
      await tester.tap(find.text('开启健康数据'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('暂不开启'));
      await tester.pumpAndSettle();
      expect(model.enables, 0);
      await tester.tap(find.text('开启健康数据'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('单独同意并继续'));
      await tester.pumpAndSettle();
      expect(model.enables, 1);
      expect(find.textContaining('已开启 ·'), findsOneWidget);
    },
  );
  test('lifecycle mapping keeps inactive separate from true background', () {
    expect(
      healthLifecycleAction(AppLifecycleState.resumed),
      HealthLifecycleAction.resumed,
    );
    expect(
      healthLifecycleAction(AppLifecycleState.inactive),
      HealthLifecycleAction.inactive,
    );
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.detached,
    ]) {
      expect(healthLifecycleAction(state), HealthLifecycleAction.suspended);
    }
  });
  testWidgets('unconfirmed server withdrawal is not presented as completed', (
    tester,
  ) async {
    final model = _Settings()..mode.value = 'withdraw';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [healthProvider(a).overrideWith((_) async => model)],
        child: MaterialApp(home: HealthPage(a)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('本机已停止 · 待确认服务端撤回'), findsOneWidget);
    expect(find.text('重试同步撤回'), findsOneWidget);
    expect(find.textContaining('已撤回'), findsNothing);
  });
  testWidgets('unknown consent is presented for explicit confirmation', (
    tester,
  ) async {
    final model = _Settings()..mode.value = 'unknown';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [healthProvider(a).overrideWith((_) async => model)],
        child: MaterialApp(home: HealthPage(a)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('本机已停止 · 上次退出时无法确认健康授权状态，请由本人确认。'), findsOneWidget);
    expect(find.text('确认撤回健康授权'), findsOneWidget);
    expect(find.text('维持停止，暂不撤回'), findsOneWidget);
    expect(find.text('稍后处理'), findsOneWidget);
    expect(find.textContaining('待确认服务端撤回'), findsNothing);
    expect(model.resolves, 0);
  });
  testWidgets('unknown consent only resolves after the explicit choice', (
    tester,
  ) async {
    final model = _Settings()..mode.value = 'unknown';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [healthProvider(a).overrideWith((_) async => model)],
        child: MaterialApp(home: HealthPage(a)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('确认撤回健康授权'));
    await tester.pumpAndSettle();
    expect(find.text('确认撤回健康授权？'), findsOneWidget);
    expect(model.resolves, 0);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(model.resolves, 0);
    expect(model.mode.value, 'unknown');

    await tester.tap(find.text('维持停止，暂不撤回'));
    await tester.pumpAndSettle();
    expect(model.resolves, 1);
    expect(model.lastResolveWithdraw, false);
    expect(model.mode.value, 'off');
    expect(find.text('尚未开启'), findsOneWidget);
  });
  testWidgets('unknown withdrawal requires a second confirmation', (
    tester,
  ) async {
    final model = _Settings()..mode.value = 'unknown';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [healthProvider(a).overrideWith((_) async => model)],
        child: MaterialApp(home: HealthPage(a)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('确认撤回健康授权'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认撤回'));
    await tester.pumpAndSettle();

    expect(model.resolves, 1);
    expect(model.lastResolveWithdraw, true);
    expect(find.text('本机已停止 · 待确认服务端撤回'), findsOneWidget);
  });
  testWidgets('unknown consent can be left untouched for later', (
    tester,
  ) async {
    final model = _Settings()..mode.value = 'unknown';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [healthProvider(a).overrideWith((_) async => model)],
        child: MaterialApp(home: HealthPage(a)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('稍后处理'));
    await tester.pumpAndSettle();

    expect(model.resolves, 0);
    expect(model.mode.value, 'unknown');
  });
  testWidgets('pending authorization is explained and can be withdrawn', (
    tester,
  ) async {
    final model = _Settings()..mode.value = 'pending';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [healthProvider(a).overrideWith((_) async => model)],
        child: MaterialApp(home: HealthPage(a)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('已获系统许可'), findsOneWidget);
    expect(find.text('撤回同意并清除未发窗口'), findsOneWidget);
    expect(find.text('正在读取设置…'), findsNothing);
  });

  testWidgets('离线登出不假报成功并明确服务端待确认', (tester) async {
    final (sessions, scope, handler) = await _logoutFixture(
      tester,
      explicitWithdrawal: true,
    );
    var offline = false;
    handler.handle = (op, _) async {
      if (offline &&
          (op == AppOp.listConsents ||
              op == AppOp.setConsent ||
              op == AppOp.logout)) {
        throw const SocketException('offline');
      }
      return response({'items': <Json>[], 'next_cursor': null});
    };
    final api = AppApi(Uri.https('example.invalid'), handler, sessions);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiProvider.overrideWith((_) async => api)],
        child: const HighEqApp(),
      ),
    );
    await tester.pump();
    await _pumpUntil(tester, find.text('是否同意开始本次自评？'));
    expect(scope.account, 'A');
    offline = true;

    await _openLogoutDialog(tester);
    await _pumpUntil(tester, find.text('退出结果'));

    final semantics = tester.ensureSemantics();
    await tester.pump();
    expect(find.text('关闭'), findsOneWidget);
    expect(find.bySemanticsLabel('关闭退出结果'), findsOneWidget);
    semantics.dispose();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('logout-local')),
        matching: find.textContaining('已完成'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('logout-health')),
        matching: find.textContaining('撤回未确认'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('logout-server')),
        matching: find.textContaining('未确认'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('健康撤回尚未确认'), findsOneWidget);
    expect(find.textContaining('服务端登出尚未确认'), findsOneWidget);
  });

  testWidgets('健康撤回失败但服务端登出成功时分别呈现结果', (tester) async {
    final (sessions, scope, handler) = await _logoutFixture(
      tester,
      explicitWithdrawal: true,
    );
    handler.handle = (op, _) async {
      switch (op) {
        case AppOp.listConsents:
          return response({
            'items': [
              {'purpose': 'health', 'granted': true, 'version': 'v1'},
            ],
          });
        case AppOp.setConsent:
          throw const SocketException('health withdrawal unavailable');
        case AppOp.logout:
          return response({});
        default:
          throw StateError('unexpected $op');
      }
    };
    final api = AppApi(Uri.https('example.invalid'), handler, sessions);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiProvider.overrideWith((_) async => api)],
        child: const HighEqApp(),
      ),
    );
    await tester.pump();
    await _pumpUntil(tester, find.text('是否同意开始本次自评？'));
    expect(scope.account, 'A');

    await _openLogoutDialog(tester);
    await _pumpUntil(tester, find.text('退出结果'));

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('logout-local')),
        matching: find.textContaining('已完成'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('logout-health')),
        matching: find.textContaining('撤回未确认'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('logout-server')),
        matching: find.textContaining('已确认'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('服务端登出未确认'), findsNothing);
  });

  testWidgets('A 迟到的登出结果不进入 B 页面或 B 的后续登出', (tester) async {
    final (sessions, scope, handler) = await _logoutFixture(
      tester,
      explicitWithdrawal: true,
    );
    final aConsentStarted = Completer<void>();
    final releaseA = Completer<void>();
    final aLogoutFinished = Completer<void>();
    handler.handle = (op, request) async {
      final bearer = request.headers['Authorization'];
      if (bearer == 'Bearer B-new') {
        if (op == AppOp.logout) return response({});
        return response({'items': <Json>[], 'next_cursor': null});
      }
      switch (op) {
        case AppOp.listConsents:
          return response({
            'items': [
              {'purpose': 'health', 'granted': true, 'version': 'v1'},
            ],
          });
        case AppOp.setConsent:
          if (!aConsentStarted.isCompleted) aConsentStarted.complete();
          await releaseA.future;
          throw const SocketException('A withdrawal response is late');
        case AppOp.logout:
          if (!aLogoutFinished.isCompleted) aLogoutFinished.complete();
          throw const SocketException('A server logout is late');
        default:
          throw StateError('unexpected $op');
      }
    };
    final api = AppApi(Uri.https('example.invalid'), handler, sessions);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiProvider.overrideWith((_) async => api)],
        child: const HighEqApp(),
      ),
    );
    await tester.pump();
    await _pumpUntil(tester, find.text('是否同意开始本次自评？'));
    expect(scope.account, 'A');

    await _openLogoutDialog(tester);
    await _pumpUntilTrue(tester, () => aConsentStarted.isCompleted);
    await _pumpUntil(tester, find.text('隐私政策与用户协议'));
    expect(sessions.active, isNull);

    await tester.runAsync(() => sessions.activate(tokens('B', 'B-new')));
    await tester.pump();
    await _pumpUntil(tester, find.text('是否同意开始本次自评？'));
    expect(sessions.active?.account, 'B');

    releaseA.complete();
    await _pumpUntilTrue(tester, () => aLogoutFinished.isCompleted);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    expect(find.text('退出结果'), findsNothing);
    expect(sessions.active?.account, 'B');

    await _openLogoutDialog(tester);
    await _pumpUntil(tester, find.text('退出结果'));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('logout-server')),
        matching: find.textContaining('已确认'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('logout-server')),
        matching: find.textContaining('未确认'),
      ),
      findsNothing,
    );
  });

  testWidgets('本机安全清理失败不宣称已清理', (tester) async {
    final secret = _FailingSecret();
    final (sessions, scope, handler) = await _logoutFixture(
      tester,
      secret: secret,
    );
    secret.failReplaceCount = 99;
    final api = AppApi(Uri.https('example.invalid'), handler, sessions);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiProvider.overrideWith((_) async => api)],
        child: const HighEqApp(),
      ),
    );
    await tester.pump();
    await _pumpUntil(tester, find.text('是否同意开始本次自评？'));
    expect(scope.account, 'A');

    await _openLogoutDialog(tester);
    await _pumpUntil(tester, find.text('退出结果'));

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('logout-local')),
        matching: find.textContaining('未完成'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('logout-server')),
        matching: find.textContaining('已确认'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('本机清理未完成'), findsOneWidget);
    expect(find.textContaining('服务端登出尚未确认'), findsNothing);
  });

  testWidgets('平台安全存储清理失败同样不宣称已清理', (tester) async {
    final secret = _FailingSecret(
      failure: PlatformException(code: 'secure_storage_unavailable'),
    );
    final (sessions, scope, handler) = await _logoutFixture(
      tester,
      secret: secret,
    );
    secret.failReplaceCount = 99;
    final api = AppApi(Uri.https('example.invalid'), handler, sessions);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiProvider.overrideWith((_) async => api)],
        child: const HighEqApp(),
      ),
    );
    await tester.pump();
    await _pumpUntil(tester, find.text('是否同意开始本次自评？'));
    expect(scope.account, 'A');

    await _openLogoutDialog(tester);
    await _pumpUntil(tester, find.text('退出结果'));

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('logout-local')),
        matching: find.textContaining('未完成'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('logout-server')),
        matching: find.textContaining('已确认'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('本机清理未完成'), findsOneWidget);
    expect(find.textContaining('服务端登出尚未确认'), findsNothing);
  });
}
