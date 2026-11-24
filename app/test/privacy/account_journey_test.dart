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
import 'package:high_eq/features/home/shell.dart';
import 'package:high_eq/features/onboarding/account_entry.dart';
import 'package:high_eq/features/onboarding/assessment.dart';
import 'package:high_eq/features/onboarding/login.dart';
import 'package:high_eq/features/privacy/account_access.dart';
import 'package:high_eq/features/privacy/page.dart';
import 'package:high_eq/main.dart';

import '../client_test.dart' show Handler, response;
import '../isolation_test.dart' show MemorySecret, tokens;

const deadline = '2030-01-01T00:00:00Z';

Map<String, Object?> account({
  String userId = 'synthetic-A',
  String? frozen,
  String timezone = 'Asia/Shanghai',
  List<String> bindings = const ['phone'],
}) => {
  'user_id': userId,
  'timezone': timezone,
  'bindings': bindings,
  'frozen_until': frozen,
};

Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 120; i++) {
    await tester.pump(const Duration(milliseconds: 25));
    if (finder.evaluate().length == 1) return;
    // Session cache reads and retirement use real file I/O.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(finder, findsOneWidget);
}

Future<void> pumpUntilCondition(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
}) async {
  for (var i = 0; i < 120; i++) {
    await tester.pump(const Duration(milliseconds: 25));
    if (condition()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  fail(reason);
}

Finder currentPage<T extends Widget>([String? name]) =>
    find.byElementPredicate((element) {
      if (element.widget is! T) return false;
      final route = ModalRoute.of(element);
      return route != null &&
          route.isCurrent &&
          route.animation?.status == AnimationStatus.completed &&
          (name == null ? route is PopupRoute : route.settings.name == name);
    }, description: 'current ${name ?? T} route with $T');

Finder within(Finder page, Finder finder) =>
    find.descendant(of: page, matching: finder);

Finder verticalScroll(Finder page) => within(
  page,
  find.byWidgetPredicate(
    (widget) =>
        widget is Scrollable && widget.axisDirection == AxisDirection.down,
  ),
);

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  final target = finder.hitTestable();
  await pumpUntil(tester, target);
  await tester.tap(target);
  await tester.pump();
}

Future<void> reveal(WidgetTester tester, Finder page, Finder finder) async {
  await pumpUntil(tester, page);
  if (finder.evaluate().isEmpty) {
    final scrollable = verticalScroll(page);
    expect(scrollable, findsOneWidget);
    await tester.scrollUntilVisible(finder, 180, scrollable: scrollable);
  } else if (finder.hitTestable().evaluate().isEmpty) {
    await tester.ensureVisible(finder);
  }
  await tester.pump();
}

void main() {
  late Directory cache;
  late Sessions sessions;
  late AccountScope scope;
  late AppApi api;
  late Handler transport;
  late List<AppOp> calls;

  Future<void> start(WidgetTester tester) async {
    await tester.runAsync(() async {
      cache = await Directory.systemTemp.createTemp('t35-privacy-test.');
      sessions = Sessions(MemorySecret(), cache);
      scope = await sessions.activate(tokens('synthetic-A'));
    });
    addTearDown(() => cache.delete(recursive: true));
    calls = [];
    transport = Handler();
    api = AppApi(Uri.https('example.invalid'), transport, sessions);
  }

  Future<void> mount(WidgetTester tester) => tester.pumpWidget(
    ProviderScope(
      overrides: [apiProvider.overrideWith((_) => api)],
      child: const HighEqApp(),
    ),
  );

  Future<void> navigate(WidgetTester tester, String route) async {
    final nav = find.byType(Navigator);
    await pumpUntil(tester, nav);
    unawaited(tester.state<NavigatorState>(nav).pushNamed<void>(route));
    await tester.pump();
  }

  Future<void> confirmAppleClosure(
    WidgetTester tester, {
    bool cancelAuthorization = false,
  }) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(vendorChannel, (call) async {
      expect(call.method, 'authorize');
      expect(call.arguments, {'provider': 'apple'});
      if (cancelAuthorization) throw PlatformException(code: 'cancelled');
      return 'synthetic-apple-proof';
    });
    addTearDown(() => messenger.setMockMethodCallHandler(vendorChannel, null));

    final page = currentPage<PrivacyPage>('/privacy');
    await mount(tester);
    await navigate(tester, '/privacy');
    final provider = within(
      page,
      find.byKey(const Key('privacy-closure-provider')),
    );
    await reveal(tester, page, provider);
    await tapVisible(tester, provider);
    await tapVisible(
      tester,
      within(currentPage<DropdownMenuItem<String>>(), find.text('Apple')),
    );
    final submit = within(page, find.byKey(const Key('privacy-freeze')));
    await reveal(tester, page, submit);
    await tapVisible(tester, submit);
    await tapVisible(
      tester,
      within(currentPage<AlertDialog>(), find.text('申请注销')),
    );
  }

  testWidgets(
    'named privacy route reads account and verifies persisted correction',
    (tester) async {
      await start(tester);
      var zone = 'Asia/Shanghai';
      var reads = 0;
      transport.handle = (op, req) async {
        calls.add(op);
        switch (op) {
          case AppOp.getMe:
            reads++;
            return response(account(timezone: zone));
          case AppOp.updateMe:
            expect(req.method, 'PATCH');
            expect(req.url.path, '/v1/me');
            expect(jsonDecode(req.body), {'timezone': 'UTC'});
            zone = 'UTC';
            return response(account(timezone: zone));
          case AppOp.listAssessments:
          case AppOp.listConsents:
            return response({'items': [], 'next_cursor': null});
          default:
            throw StateError(op.name);
        }
      };
      await mount(tester);
      await navigate(tester, '/privacy');
      final page = currentPage<PrivacyPage>('/privacy');
      final field = within(page, find.byKey(const Key('privacy-timezone')));
      await pumpUntil(tester, field);
      expect(tester.widget<TextField>(field).controller!.text, 'Asia/Shanghai');
      expect(find.text('账号 synthetic-A'), findsOneWidget);
      await tester.enterText(field, 'UTC');
      await tapVisible(tester, within(page, find.text('保存时区更正')));
      await pumpUntil(tester, find.text('时区已更正'));
      expect(tester.widget<TextField>(field).controller!.text, 'UTC');
      expect(calls.where((op) => op == AppOp.updateMe), hasLength(1));
      expect(reads, greaterThanOrEqualTo(2));
    },
  );

  testWidgets(
    'frozen relogin gates business routes until explicit cancellation and readback',
    (tester) async {
      await start(tester);
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const health = MethodChannel('cn.higheq/health-history');
      final messenger = tester.binding.defaultBinaryMessenger;
      final nativeCalls = <String>[];
      messenger.setMockMethodCallHandler(health, (call) async {
        nativeCalls.add(call.method);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(health, null));
      var cancelled = false;
      var allowThaw = false;
      var returnWrongAccount = false;
      transport.handle = (op, req) async {
        calls.add(op);
        switch (op) {
          case AppOp.getMe:
            if (cancelled && returnWrongAccount) {
              return response(account(userId: 'synthetic-B'));
            }
            if (cancelled && !allowThaw) {
              return response({'code': 'service_unavailable'}, 503);
            }
            return response(
              account(frozen: cancelled ? null : '2020-01-01T00:00:00Z'),
            );
          case AppOp.cancelClosure:
            expect(req.method, 'DELETE');
            expect(req.url.path, '/v1/me/closure');
            cancelled = true;
            return response({'ok': true});
          case AppOp.listConsents:
          case AppOp.listAssessments:
            if (!allowThaw) {
              throw StateError('business before thaw: ${op.name}');
            }
            return response({'items': [], 'next_cursor': null});
          default:
            throw StateError(op.name);
        }
      };
      await mount(tester);
      final cancel = find.byKey(const Key('privacy-cancel-closure'));
      await pumpUntil(
        tester,
        within(currentPage<PrivacyPage>('/'), cancel).hitTestable(),
      );
      await navigate(tester, '/growth');
      final gate = currentPage<PrivacyPage>('/growth');
      final visibleCancel = within(gate, cancel);
      await pumpUntil(tester, visibleCancel.hitTestable());
      expect(find.byType(NavigationBar), findsNothing);
      expect(calls, [AppOp.getMe]);
      await tapVisible(tester, visibleCancel);
      final retry = within(gate, find.byKey(const Key('privacy-retry')));
      await pumpUntil(tester, retry);
      expect(calls, [AppOp.getMe, AppOp.cancelClosure, AppOp.getMe]);
      expect(nativeCalls, isEmpty);
      expect(find.byType(NavigationBar), findsNothing);

      returnWrongAccount = true;
      await reveal(tester, gate, retry);
      await tapVisible(tester, retry);
      await pumpUntil(tester, retry);
      expect(calls, [
        AppOp.getMe,
        AppOp.cancelClosure,
        AppOp.getMe,
        AppOp.getMe,
      ]);
      expect(nativeCalls, isEmpty);
      expect(find.byType(NavigationBar), findsNothing);
      expect(sessions.active, same(scope));

      returnWrongAccount = false;
      allowThaw = true;
      await reveal(tester, gate, retry);
      await tapVisible(tester, retry);
      final assessment = currentPage<AssessmentPage>('/assessment');
      await pumpUntil(tester, within(assessment, find.text('是否同意开始本次自评？')));
      expect(calls.where((op) => op == AppOp.cancelClosure), hasLength(1));
      expect(sessions.active, same(scope));
    },
  );

  testWidgets('unknown account never starts assessment or growth', (
    tester,
  ) async {
    await start(tester);
    transport.handle = (op, _) async {
      calls.add(op);
      if (op == AppOp.getMe) {
        return response({'code': 'service_unavailable'}, 503);
      }
      throw StateError(op.name);
    };
    await mount(tester);
    await pumpUntil(tester, find.byKey(const Key('account-entry-retry')));
    await navigate(tester, '/growth');
    await pumpUntil(
      tester,
      within(
        currentPage<AccountEntryPage>('/growth'),
        find.byKey(const Key('account-entry-retry')),
      ).hitTestable(),
    );
    expect(find.byType(NavigationBar), findsNothing);
    expect(calls, [AppOp.getMe]);
  });

  testWidgets(
    'phone closure submits one fresh proof and retires the local lease',
    (tester) async {
      await start(tester);
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final saved = [1, 2, 3];
      await tester.runAsync(
        () => sessions.put(scope, CacheKind.continuation, 'synthetic', saved),
      );
      var attempts = 0;
      transport.handle = (op, req) async {
        calls.add(op);
        switch (op) {
          case AppOp.getMe:
            return response(account());
          case AppOp.listConsents:
            return response({'items': [], 'next_cursor': null});
          case AppOp.requestCode:
            expect(req.url.path, '/v1/auth/sms');
            expect(jsonDecode(req.body), {'phone': '+99900000001'});
            return response({'ok': true});
          case AppOp.freezeAccount:
            expect(req.method, 'POST');
            expect(req.url.path, '/v1/me/closure');
            expect(jsonDecode(req.body), {
              'proof': {
                'provider': 'phone',
                'phone': '+99900000001',
                'proof': attempts == 0 ? '000000' : '000001',
              },
            });
            if (++attempts == 1) {
              return response({'code': 'unauthenticated'}, 401);
            }
            return response({'frozen_until': deadline});
          default:
            throw StateError(op.name);
        }
      };

      final form = currentPage<PrivacyPage>('/privacy');
      final confirmation = currentPage<AlertDialog>();
      Finder control(String key) => within(form, find.byKey(Key(key)));

      Future<void> tapControl(String key) async {
        final target = control(key);
        await reveal(tester, form, target);
        await tapVisible(tester, target);
      }

      Future<void> prepareProof(String code) async {
        await tapControl('privacy-phone-code-request');
        await pumpUntil(tester, within(form, find.textContaining('验证码已发送')));
        final field = control('privacy-phone-code');
        await reveal(tester, form, field);
        expect(field.hitTestable(), findsOneWidget);
        await tester.enterText(field, code);
        await tester.pump();
      }

      Future<void> openConfirmation() async {
        await tapControl('privacy-freeze');
        await pumpUntil(tester, confirmation);
        expect(
          within(
            confirmation,
            find.text(
              '请先在苹果设置取消订阅。申请后账号进入 15 天冷静期，所有设备会退出。在期限内可重新登录后撤销。期满后不可恢复。',
            ),
          ),
          findsOneWidget,
        );
      }

      await mount(tester);
      await navigate(tester, '/privacy');
      await pumpUntil(tester, control('privacy-timezone'));
      await tapControl('privacy-closure-provider');
      await tapVisible(
        tester,
        within(currentPage<DropdownMenuItem<String>>(), find.text('手机号')),
      );
      final phone = control('privacy-phone');
      await pumpUntil(tester, phone);
      await reveal(tester, form, phone);
      expect(phone.hitTestable(), findsOneWidget);
      await tester.enterText(phone, '+99900000001');
      await tester.pump();

      await prepareProof('000000');
      await openConfirmation();
      await tapVisible(tester, within(confirmation, find.text('暂不注销')));
      await pumpUntil(tester, control('privacy-freeze').hitTestable());
      expect(calls, isNot(contains(AppOp.freezeAccount)));
      expect(sessions.active, same(scope));
      expect(find.textContaining('未收到注销确认'), findsNothing);

      await openConfirmation();
      await tapVisible(tester, within(confirmation, find.text('申请注销')));
      await pumpUntil(tester, within(form, find.text('登录凭证无效或已过期，请重新验证。')));
      expect(attempts, 1);
      expect(sessions.active, same(scope));
      expect(calls, isNot(contains(AppOp.refreshTokens)));
      expect(find.textContaining('未收到注销确认'), findsNothing);
      expect(
        tester.widget<OutlinedButton>(control('privacy-freeze')).onPressed,
        isNull,
      );

      await prepareProof('000001');
      await openConfirmation();
      await tapVisible(tester, within(confirmation, find.text('申请注销')));
      final receipt = find.textContaining('注销申请已提交');
      final login = currentPage<LoginPage>('/');
      await pumpUntil(tester, login);
      await pumpUntil(tester, receipt);
      final deadlineDate = MaterialLocalizations.of(
        tester.element(login),
      ).formatMediumDate(DateTime.parse(deadline).toLocal());
      expect(tester.widget<Text>(receipt).data, contains(deadlineDate));
      expect(find.textContaining('本机清理待确认'), findsNothing);
      expect(sessions.active, isNull);
      final files = await tester.runAsync(
        () async =>
            await cache.exists() ? cache.list().toList() : <FileSystemEntity>[],
      );
      expect(files, isEmpty);
      expect(calls.where((op) => op == AppOp.requestCode), hasLength(2));
      expect(calls.where((op) => op == AppOp.freezeAccount), hasLength(2));
      expect(calls, isNot(contains(AppOp.logout)));
      expect(calls, isNot(contains(AppOp.refreshTokens)));

      final semantics = tester.ensureSemantics();
      try {
        final dismiss = find.bySemanticsLabel('关闭注销提示');
        await tapVisible(tester, dismiss);
        expect(receipt, findsNothing);
        expect(dismiss, findsNothing);
        expect(login, findsOneWidget);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'lost closure receipt remains visible on login after unauthorized readback',
    (tester) async {
      await start(tester);
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final relevant = <AppOp>[];
      var submitted = false;
      transport.handle = (op, req) async {
        switch (op) {
          case AppOp.getMe:
            if (!submitted) return response(account(bindings: ['apple']));
            relevant.add(op);
            expect(req.headers['Authorization'], 'Bearer access');
            return response({'code': 'unauthenticated'}, 401);
          case AppOp.freezeAccount:
            relevant.add(op);
            expect(req.method, 'POST');
            expect(req.url.path, '/v1/me/closure');
            expect(req.headers['Authorization'], 'Bearer access');
            expect(jsonDecode(req.body), {
              'proof': {'provider': 'apple', 'proof': 'synthetic-apple-proof'},
            });
            submitted = true;
            throw const SocketException('synthetic lost response');
          case AppOp.refreshTokens:
            relevant.add(op);
            expect(jsonDecode(req.body), {'refresh_token': 'refresh'});
            return response({'code': 'unauthenticated'}, 401);
          case AppOp.listAssessments:
          case AppOp.listConsents:
            return response({'items': [], 'next_cursor': null});
          default:
            throw StateError(op.name);
        }
      };

      await confirmAppleClosure(tester);
      final login = currentPage<LoginPage>('/');
      await pumpUntil(tester, login);
      expect(sessions.active, isNull);
      expect(relevant, [AppOp.freezeAccount, AppOp.getMe, AppOp.refreshTokens]);
      expect(find.byType(PrivacyPage), findsNothing);

      final notice = find.textContaining('未收到注销确认');
      await pumpUntil(tester, notice);
      expect(tester.widget<Text>(notice).data, contains('请重新登录核对'));
      expect(find.textContaining('注销申请已提交'), findsNothing);
      expect(find.textContaining('注销失败'), findsNothing);
      expect(tester.takeException(), isNull);

      final semantics = tester.ensureSemantics();
      try {
        await tapVisible(tester, find.bySemanticsLabel('关闭注销提示'));
        expect(notice, findsNothing);
        expect(login, findsOneWidget);
      } finally {
        semantics.dispose();
      }
      expect(relevant, [AppOp.freezeAccount, AppOp.getMe, AppOp.refreshTokens]);
    },
  );

  testWidgets('unconfirmed closure can retry a 503 read without resubmitting', (
    tester,
  ) async {
    await start(tester);
    var submitted = false;
    var reads = 0;
    final readback = <AppOp>[];
    transport.handle = (op, _) async {
      switch (op) {
        case AppOp.getMe:
          if (!submitted) return response(account(bindings: ['apple']));
          readback.add(op);
          return ++reads == 1
              ? response({'code': 'service_unavailable'}, 503)
              : response({'code': 'unauthenticated'}, 401);
        case AppOp.freezeAccount:
          readback.add(op);
          submitted = true;
          return response({'code': 'service_unavailable'}, 503);
        case AppOp.refreshTokens:
          readback.add(op);
          return response({'code': 'unauthenticated'}, 401);
        case AppOp.listAssessments:
        case AppOp.listConsents:
          return response({'items': [], 'next_cursor': null});
        default:
          throw StateError(op.name);
      }
    };

    await confirmAppleClosure(tester);
    final privacy = currentPage<PrivacyPage>('/privacy');
    final notice = find.textContaining('未收到注销确认');
    await pumpUntil(tester, within(privacy, notice));
    expect(sessions.active, same(scope));
    expect(readback, [AppOp.freezeAccount, AppOp.getMe]);
    await tapVisible(
      tester,
      within(privacy, find.byKey(const Key('privacy-retry'))),
    );
    await pumpUntil(tester, currentPage<LoginPage>('/'));
    await pumpUntil(tester, notice);
    expect(tester.widget<Text>(notice).data, contains('请重新登录核对'));
    expect(readback, [
      AppOp.freezeAccount,
      AppOp.getMe,
      AppOp.getMe,
      AppOp.refreshTokens,
    ]);
  });

  for (final replacementId in ['synthetic-B', 'synthetic-A']) {
    testWidgets(
      'late closure readback leaves replacement $replacementId alone',
      (tester) async {
        await start(tester);
        final releaseRefresh = Completer<void>();
        var refreshStarted = false;
        var submitted = false;
        transport.handle = (op, req) async {
          calls.add(op);
          switch (op) {
            case AppOp.getMe:
              if (req.headers['Authorization'] == 'Bearer replacement') {
                return response(account(userId: replacementId));
              }
              expect(req.headers['Authorization'], 'Bearer access');
              return submitted
                  ? response({'code': 'unauthenticated'}, 401)
                  : response(account(bindings: ['apple']));
            case AppOp.freezeAccount:
              expect(req.headers['Authorization'], 'Bearer access');
              submitted = true;
              throw const SocketException('synthetic lost response');
            case AppOp.refreshTokens:
              expect(jsonDecode(req.body), {'refresh_token': 'refresh'});
              refreshStarted = true;
              await releaseRefresh.future;
              return response({'code': 'unauthenticated'}, 401);
            case AppOp.listAssessments:
            case AppOp.listConsents:
              return response({'items': [], 'next_cursor': null});
            default:
              throw StateError(op.name);
          }
        };

        await confirmAppleClosure(tester);
        await pumpUntilCondition(
          tester,
          () => refreshStarted,
          reason: 'The old closure readback did not dispatch its token refresh',
        );
        expect(calls.where((op) => op == AppOp.refreshTokens), hasLength(1));
        expect(sessions.active, same(scope));

        // The old admission has already started its read. Its next
        // notification comes when that read has processed the refresh result.
        final oldAdmission = AccountAccess.of(api, scope);
        var oldReadbackFinished = false;
        void onOldReadback() => oldReadbackFinished = true;
        oldAdmission.addListener(onOldReadback);
        addTearDown(() => oldAdmission.removeListener(onOldReadback));

        final nextTokens = Tokens(
          replacementId,
          'replacement',
          'replacement-refresh',
          DateTime.now().toUtc().add(const Duration(hours: 1)),
        );
        final replacement = (await tester.runAsync(
          () => sessions.activate(nextTokens),
        ))!;
        expect(replacement, isNot(same(scope)));
        await navigate(tester, '/privacy');
        final replacementAccount = within(
          currentPage<PrivacyPage>('/privacy'),
          find.text('账号 $replacementId'),
        );
        await pumpUntil(tester, replacementAccount);
        expect(oldReadbackFinished, isFalse);
        releaseRefresh.complete();
        await pumpUntilCondition(
          tester,
          () => oldReadbackFinished,
          reason: 'The old readback did not finish after the refresh 401',
        );
        expect(sessions.active, same(replacement));
        expect(sessions.require(replacement).access, 'replacement');
        expect(sessions.require(replacement).refresh, 'replacement-refresh');
        expect(sessions.isCurrentUnauthorizedRetirement(scope), isFalse);
        expect(replacementAccount, findsOneWidget);
        expect(find.textContaining('未收到注销确认'), findsNothing);
        expect(calls.where((op) => op == AppOp.freezeAccount), hasLength(1));
        expect(calls.where((op) => op == AppOp.refreshTokens), hasLength(1));
        await tester.runAsync(sessions.clear);
        await pumpUntil(tester, currentPage<LoginPage>('/'));
        expect(find.textContaining('未收到注销确认'), findsNothing);
      },
    );
  }

  testWidgets('cancelled Apple reauthentication leaves closure unsubmitted', (
    tester,
  ) async {
    await start(tester);
    transport.handle = (op, _) async {
      calls.add(op);
      switch (op) {
        case AppOp.getMe:
          return response(account(bindings: ['apple']));
        case AppOp.listAssessments:
        case AppOp.listConsents:
          return response({'items': [], 'next_cursor': null});
        default:
          throw StateError(op.name);
      }
    };

    await confirmAppleClosure(tester, cancelAuthorization: true);
    await pumpUntil(tester, find.text('已取消，未更改账号或权益。'));
    expect(sessions.active, same(scope));
    expect(calls, isNot(contains(AppOp.freezeAccount)));
    expect(find.textContaining('未收到注销确认'), findsNothing);
  });

  testWidgets('my tab opens the formal privacy page', (tester) async {
    await start(tester);
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    transport.handle = (op, _) async {
      switch (op) {
        case AppOp.getMe:
          return response(account());
        case AppOp.listAssessments:
          return response({
            'items': [
              {'next_eligible_at': deadline},
            ],
            'next_cursor': null,
          });
        case AppOp.listConsents:
          return response({
            'items': [
              {'purpose': 'assessment', 'version': '2026-11', 'granted': true},
            ],
            'next_cursor': null,
          });
        case AppOp.getTodayPlan:
          return response({'code': 'not_found'}, 404);
        case AppOp.getEntitlements:
          return response({'tier': 'free'});
        default:
          throw StateError(op.name);
      }
    };
    await mount(tester);
    final navigation = within(
      currentPage<HomeShell>('/practice'),
      find.byType(NavigationBar),
    );
    await tapVisible(
      tester,
      within(
        navigation,
        find.byWidgetPredicate(
          (widget) => widget is NavigationDestination && widget.label == '我的',
        ),
      ),
    );
    final me = currentPage<HomeShell>('/me');
    final tile = within(me, find.byKey(const Key('me-privacy')));
    await pumpUntil(tester, me);
    final list = verticalScroll(me);
    expect(list, findsOneWidget);
    await tester.scrollUntilVisible(tile.hitTestable(), 180, scrollable: list);
    await tester.pump();
    expect(tile, findsOneWidget);
    await tapVisible(tester, tile);
    final privacy = currentPage<PrivacyPage>('/privacy');
    await pumpUntil(tester, within(privacy, find.text('隐私与个人数据')));
    await pumpUntil(tester, within(privacy, find.text('账号 synthetic-A')));
  });
}
