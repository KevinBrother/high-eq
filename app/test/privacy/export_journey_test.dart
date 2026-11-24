import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart' hide within;
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/providers.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/features/growth/practice_home.dart';
import 'package:high_eq/features/growth/repository.dart';
import 'package:high_eq/features/home/shell.dart';
import 'package:high_eq/features/onboarding/login.dart';
import 'package:high_eq/features/privacy/export_delivery.dart';
import 'package:high_eq/features/privacy/export_namespace.dart';
import 'package:high_eq/features/privacy/page.dart';
import 'package:high_eq/main.dart';
import 'package:http/http.dart' as http;

import '../client_test.dart' show Handler, response;
import '../isolation_test.dart' show MemorySecret, tokens;
import 'account_journey_test.dart'
    show
        account,
        currentPage,
        deadline,
        pumpUntil,
        reveal,
        tapVisible,
        verticalScroll,
        within;
import 'export_fixture.dart';
import 'export_test_support.dart' show reportPrivacyExportPresented;

void main() {
  late Directory cache;
  late _GatedSecret secret;
  late Sessions sessions;
  late AppApi api;
  late Handler transport;
  late List<AppOp> calls;

  Future<void> start(WidgetTester tester) async {
    await tester.runAsync(() async {
      cache = await Directory.systemTemp.createTemp('t35-privacy-test.');
      secret = _GatedSecret();
      sessions = Sessions(secret, cache);
      await sessions.activate(tokens('synthetic-A'));
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

  Future<http.StreamedResponse> ordinaryPrivacyRoute(
    AppOp op,
    http.Request request,
  ) async {
    switch (op) {
      case AppOp.getMe:
        return response(
          account(
            userId: request.headers['authorization'] == 'Bearer access-B'
                ? 'synthetic-B'
                : 'synthetic-A',
          ),
        );
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
  }

  Future<Finder> openFromMe(WidgetTester tester, String userId) async {
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
    await pumpUntil(tester, within(privacy, find.text('账号 $userId')));
    return privacy;
  }

  const exportKey = Key('privacy-export');
  const native = MethodChannel('cn.higheq/mobile-commerce');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const nativeReady = {'state': 'ok', 'removed': 0, 'failed': 0};

  Future<Directory> stagingRoot(WidgetTester tester) async {
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('t35-ui-export.'),
    ))!;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, (
      call,
    ) async {
      expect(call.method, 'getTemporaryDirectory');
      return root.path;
    });
    addTearDown(() async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        paths,
        null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        native,
        null,
      );
      await root.delete(recursive: true);
    });
    return root;
  }

  Future<void> tapExport(WidgetTester tester, Finder privacy) async {
    final button = within(privacy, find.byKey(exportKey));
    await reveal(tester, privacy, button);
    await tapVisible(tester, button);
  }

  List<FileSystemEntity> stagedEntries(Directory root) =>
      root.listSync(recursive: true, followLinks: false);

  http.StreamedResponse archive(Stream<List<int>> stream, {int status = 200}) =>
      http.StreamedResponse(
        stream,
        status,
        headers: {'content-type': 'application/zip'},
      );

  Future<void> waitFor(WidgetTester tester, bool Function() condition) async {
    for (var i = 0; i < 120 && !condition(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(condition(), isTrue);
  }

  testWidgets(
    'my privacy export streams the signed-in ZIP and waits for iOS receipt',
    (tester) async {
      await start(tester);
      final root = await stagingRoot(tester);
      final bytes = accountExportFixture('synthetic-A');
      final chunks = StreamController<List<int>>();
      final finishSheet = Completer<void>();
      final operations = <String>[];
      const presenting = '请在系统面板中完成保存或分享。';
      File? exported;
      int? requestId;
      final messenger = tester.binding.defaultBinaryMessenger;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
        call,
      ) async {
        operations.add(call.method);
        if (call.method == 'cleanupStatus') return nativeReady;
        expect(call.method, 'shareExport');
        expect(call.arguments['mimeType'], 'application/zip');
        exported = File(call.arguments['path'] as String);
        expect(exported!.readAsBytesSync(), bytes);
        expect(File('${exported!.path}.owner').existsSync(), isTrue);
        requestId = call.arguments['requestId'] as int?;
        await finishSheet.future;
        return null;
      });
      transport.handle = (op, request) async {
        if (op != AppOp.exportData) return ordinaryPrivacyRoute(op, request);
        calls.add(op);
        expect(request.method, 'GET');
        expect(request.url.path, '/v1/me/export');
        expect(request.headers['authorization'], 'Bearer access');
        expect(request.headers['accept'], 'application/zip');
        return archive(chunks.stream);
      };
      await mount(tester);
      final privacy = await openFromMe(tester, 'synthetic-A');
      await tapExport(tester, privacy);
      await waitFor(tester, () => calls.length == 1);
      chunks.add(bytes.sublist(0, 80));
      await waitFor(
        tester,
        () => stagedEntries(root).whereType<File>().any(
          (file) => file.path.endsWith('.part') && file.lengthSync() == 80,
        ),
      );
      expect(
        stagedEntries(
          root,
        ).whereType<File>().where((file) => file.path.endsWith('.zip')),
        isEmpty,
      );
      expect(operations, ['cleanupStatus']);
      chunks.add(bytes.sublist(80));
      unawaited(chunks.close());
      try {
        await waitFor(tester, () => exported != null);
        await tester.pump();
        expect(within(privacy, find.text(presenting)), findsNothing);
        expect(within(privacy, find.text('正在打开系统面板…')), findsOneWidget);
        expect(requestId, isPositive);
        await reportPrivacyExportPresented(messenger, requestId! + 1);
        await tester.pump();
        expect(within(privacy, find.text(presenting)), findsNothing);
        await reportPrivacyExportPresented(messenger, requestId!);
        await pumpUntil(tester, within(privacy, find.text(presenting)));
        final directory = (await tester.runAsync(
          () => privacyExportAccountDirectory(root, 'synthetic-A'),
        ))!;
        expect(exported!.parent.path, directory.path);
        expect(exported!.readAsBytesSync(), bytes);
        expect(File('${exported!.path}.owner').existsSync(), isTrue);
        expect(find.text('系统已完成保存或分享。'), findsNothing);
        expect(operations, ['cleanupStatus', 'cleanupStatus', 'shareExport']);
      } finally {
        finishSheet.complete();
      }
      await pumpUntil(tester, find.text('系统已完成保存或分享。'));
      expect(within(privacy, find.text(presenting)), findsNothing);
      expect(stagedEntries(root), isEmpty);
      expect(calls, [AppOp.exportData]);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'my privacy rejects incomplete, inconsistent and corrupt ZIPs before sharing',
    (tester) async {
      await start(tester);
      final root = await stagingRoot(tester);
      final healthy = accountExportFixture('synthetic-A');
      final corrupt = accountExportFixture('synthetic-A');
      corrupt[43] ^= 0x40;
      final payloads = [
        healthy.sublist(0, healthy.length - 10),
        accountExportFixture('synthetic-A', omit: 'training'),
        accountExportFixture('synthetic-A', wrongManifest: true),
        corrupt,
      ];
      final operations = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
        call,
      ) async {
        operations.add(call.method);
        expect(call.method, 'cleanupStatus');
        return nativeReady;
      });
      var attempt = 0;
      transport.handle = (op, request) async {
        if (op != AppOp.exportData) return ordinaryPrivacyRoute(op, request);
        return archive(Stream.value(payloads[attempt++]));
      };
      await mount(tester);
      final privacy = await openFromMe(tester, 'synthetic-A');
      for (var i = 0; i < payloads.length; i++) {
        await tapExport(tester, privacy);
        await pumpUntil(tester, find.text(privacyExportIntegrityFailedMessage));
        expect(attempt, i + 1);
        expect(stagedEntries(root), isEmpty);
        expect(find.text('系统已完成保存或分享。'), findsNothing);
      }
      expect(operations, List.filled(payloads.length, 'cleanupStatus'));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'accepted route exit during delivery cleanup blocks sharing',
    (tester) async {
      await start(tester);
      final root = await stagingRoot(tester);
      final waiting = Completer<void>();
      final release = Completer<void>();
      final operations = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
        call,
      ) async {
        operations.add(call.method);
        expect(call.method, 'cleanupStatus');
        if (operations.length == 2) {
          waiting.complete();
          await release.future;
        }
        return nativeReady;
      });
      transport.handle = (op, request) async {
        if (op != AppOp.exportData) return ordinaryPrivacyRoute(op, request);
        return archive(Stream.value(accountExportFixture('synthetic-A')));
      };
      await mount(tester);
      final privacy = await openFromMe(tester, 'synthetic-A');
      await tapExport(tester, privacy);
      await waitFor(tester, () => waiting.isCompleted);
      final files = stagedEntries(
        root,
      ).whereType<File>().map((entry) => entry.path).toList();
      expect(files, hasLength(2));
      final zip = files.singleWhere((path) => path.endsWith('.zip'));
      expect(files, contains('$zip.owner'));
      final route = ModalRoute.of(tester.element(privacy))!;
      final back = within(privacy, find.byType(BackButton)).hitTestable();
      expect(back, findsOneWidget);
      await tester.tap(back);
      await tester.pump();
      // Release during the exit animation so disposal alone would be too late.
      expect(route.isCurrent, isFalse);
      expect(route.animation!.status, AnimationStatus.reverse);
      release.complete();
      await waitFor(tester, () => stagedEntries(root).isEmpty);
      await pumpUntil(tester, currentPage<HomeShell>('/me'));
      expect(operations, ['cleanupStatus', 'cleanupStatus']);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  for (final switchAccount in [false, true]) {
    testWidgets(
      switchAccount
          ? 'switching accounts aborts the old partial download and delivers B only'
          : 'cancelling the download aborts the HTTP request and clears the partial ZIP',
      (tester) async {
        await start(tester);
        final root = await stagingRoot(tester);
        final shares = <String>[];
        final aborted = Completer<void>();
        final neverFinished = StreamController<List<int>>();
        final bytesA = accountExportFixture('synthetic-A');
        final bytesB = accountExportFixture('synthetic-B');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
          call,
        ) async {
          if (call.method == 'cleanupStatus') return nativeReady;
          expect(call.method, 'shareExport');
          final file = File(call.arguments['path'] as String);
          shares.add(file.parent.path);
          expect(file.readAsBytesSync(), bytesB);
          return null;
        });
        transport.handle = (op, request) async {
          if (op != AppOp.exportData) return ordinaryPrivacyRoute(op, request);
          calls.add(op);
          if (request.headers['authorization'] == 'Bearer access-B') {
            return archive(Stream.value(bytesB));
          }
          expect(request.headers['authorization'], 'Bearer access');
          expect(request, isA<http.AbortableRequest>());
          unawaited(
            (request as http.AbortableRequest).abortTrigger!.then((_) {
              aborted.complete();
              neverFinished.addError(StateError('synthetic request aborted'));
              unawaited(neverFinished.close());
            }),
          );
          return archive(neverFinished.stream);
        };
        await mount(tester);
        final practice = currentPage<PracticeHomePage>('/practice');
        final accountA = sessions.active;
        await pumpUntil(tester, practice);
        final repositoryA =
            tester.widget<PracticeHomePage>(practice).repository
                as ApiGrowthRepository;
        expect(repositoryA.scope, same(accountA));
        final privacy = await openFromMe(tester, 'synthetic-A');
        await tapExport(tester, privacy);
        await waitFor(tester, () => calls.length == 1);
        neverFinished.add(bytesA.sublist(0, 80));
        await waitFor(
          tester,
          () => stagedEntries(root).whereType<File>().any(
            (file) => file.path.endsWith('.part') && file.lengthSync() == 80,
          ),
        );
        final allowActivation = switchAccount ? Completer<void>() : null;
        Future<AccountScope>? activation;
        if (allowActivation != null) {
          // Let the account navigator render revocation while the new login
          // is still waiting to commit to the vault.
          secret.beforeSave = allowActivation.future;
          activation = sessions.activate(tokens('synthetic-B', 'access-B'));
        } else {
          final cancel = within(
            privacy,
            find.byKey(const Key('privacy-export-cancel')),
          );
          await reveal(tester, privacy, cancel);
          await tapVisible(tester, cancel);
        }
        try {
          if (activation != null) {
            // Observe the HTTP abort before pumping the frame that unmounts A.
            await tester.idle();
            expect(aborted.isCompleted, isTrue);
            await pumpUntil(tester, currentPage<LoginPage>('/'));
            expect(sessions.active, isNull);
            expect(find.byType(PrivacyPage, skipOffstage: false), findsNothing);
          }
          await waitFor(
            tester,
            () => aborted.isCompleted && stagedEntries(root).isEmpty,
          );
          expect(shares, isEmpty);
          expect(find.text('系统已完成保存或分享。'), findsNothing);
        } finally {
          allowActivation?.complete();
        }
        if (activation != null) {
          await pumpUntil(tester, practice);
          final accountB = await activation;
          expect(sessions.active, same(accountB));
          final repositoryB =
              tester.widget<PracticeHomePage>(practice).repository
                  as ApiGrowthRepository;
          expect(repositoryB.scope, same(accountB));
          expect(repositoryB.cache, isNot(same(repositoryA.cache)));
          final privacyB = await openFromMe(tester, 'synthetic-B');
          await tapExport(tester, privacyB);
          await pumpUntil(tester, within(privacyB, find.text('系统已完成保存或分享。')));
          final directoryB = await tester.runAsync(
            () => privacyExportAccountDirectory(root, 'synthetic-B'),
          );
          expect(shares, [directoryB!.path]);
          expect(calls, [AppOp.exportData, AppOp.exportData]);
          expect(stagedEntries(root), isEmpty);
        } else {
          await pumpUntil(tester, find.text(privacyExportCancelledMessage));
          expect(calls, [AppOp.exportData]);
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }

  testWidgets(
    'late iOS export receipt from A does not report success to B',
    (tester) async {
      await start(tester);
      final root = await stagingRoot(tester);
      final finishSheet = Completer<void>();
      final bytes = accountExportFixture('synthetic-A');
      final presented = <File>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      int? requestId;
      messenger.setMockMethodCallHandler(native, (call) async {
        if (call.method == 'cleanupStatus') return nativeReady;
        expect(call.method, 'shareExport');
        final file = File(call.arguments['path'] as String);
        expect(file.readAsBytesSync(), bytes);
        presented.add(file);
        requestId = call.arguments['requestId'] as int;
        await finishSheet.future;
        return null;
      });
      transport.handle = (op, request) async {
        if (op != AppOp.exportData) return ordinaryPrivacyRoute(op, request);
        expect(request.headers['authorization'], 'Bearer access');
        calls.add(op);
        return archive(Stream.value(bytes));
      };
      await mount(tester);
      final privacyA = await openFromMe(tester, 'synthetic-A');
      await tapExport(tester, privacyA);
      try {
        await waitFor(tester, () => presented.length == 1);
        await tester.runAsync(
          () => sessions.activate(tokens('synthetic-B', 'access-B')),
        );
        final privacyB = await openFromMe(tester, 'synthetic-B');
        await reportPrivacyExportPresented(messenger, requestId!);
        await tester.pump();
        expect(presented.single.existsSync(), isTrue);
        expect(within(privacyB, find.text('请在系统面板中完成保存或分享。')), findsNothing);
        expect(within(privacyB, find.text('系统已完成保存或分享。')), findsNothing);
      } finally {
        finishSheet.complete();
      }
      await waitFor(tester, () => stagedEntries(root).isEmpty);
      expect(find.text('账号 synthetic-B'), findsOneWidget);
      expect(find.text('系统已完成保存或分享。'), findsNothing);
      expect(calls, [AppOp.exportData]);
      expect(presented, hasLength(1));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'unsupported platform reports unavailable without GET or success',
    (tester) async {
      await start(tester);
      await stagingRoot(tester);
      transport.handle = (op, request) {
        calls.add(op);
        return ordinaryPrivacyRoute(op, request);
      };
      await mount(tester);
      final privacy = await openFromMe(tester, 'synthetic-A');
      await tapExport(tester, privacy);
      await pumpUntil(tester, find.text(privacyExportUnavailableMessage));
      expect(calls, isNot(contains(AppOp.exportData)));
      expect(find.text('系统已完成保存或分享。'), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}

class _GatedSecret extends MemorySecret {
  Future<void>? beforeSave;

  @override
  Future<void> replace(String? next) async {
    final pending = beforeSave;
    if (next != null && pending != null) await pending;
    await super.replace(next);
  }
}
