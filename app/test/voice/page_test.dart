import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/consent.dart';
import 'package:high_eq/core/providers.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/replies/share_host.dart';
import 'package:high_eq/features/voice/controller.dart';
import 'package:high_eq/features/voice/page.dart';
import 'package:high_eq/features/voice/retention_janitor.dart';
import 'package:high_eq/main.dart';

import 'fakes.dart';

class _RouteTransport implements Transport {
  @override
  Future<http.StreamedResponse> send(AppOp op, http.Request request) =>
      throw StateError('route test must use the fixture API');

  @override
  void close() {}
}

class _RouteApi extends AppApi {
  _RouteApi(super.origin, super.transport, super.sessions);

  @override
  Future<Json> json(
    AppOp op, {
    AccountScope? scope,
    Map<String, String> path = const {},
    Map<String, String> query = const {},
    Json? body,
    Future<void> Function()? beforeSend,
  }) async => switch (op) {
    AppOp.listConsents => {'items': <Json>[], 'next_cursor': null},
    AppOp.getEntitlements => {
      'tier': 'member',
      'expires_at': DateTime.now()
          .toUtc()
          .add(const Duration(hours: 1))
          .toIso8601String(),
    },
    _ => <String, dynamic>{},
  };
}

class _RouteSessions extends Sessions {
  final AccountScope known;
  final Map<String, List<int>> cache = {};

  _RouteSessions(this.known) : super(MemorySecret(), Directory.systemTemp);

  void seedIdentity() {
    (identity as ValueNotifier<AccountScope?>).value = known;
  }

  @override
  Tokens require(AccountScope scope) {
    if (!identical(scope, known)) throw SessionChanged();
    return testTokens(scope.account);
  }

  @override
  Future<List<int>?> get(AccountScope scope, CacheKind kind, String id) async {
    if (!identical(scope, known)) throw SessionChanged();
    return cache[id];
  }

  @override
  Future<void> put(
    AccountScope scope,
    CacheKind kind,
    String id,
    List<int> bytes,
  ) async {
    if (!identical(scope, known)) throw SessionChanged();
    cache[id] = bytes;
  }

  @override
  Future<void> remove(AccountScope scope, CacheKind kind, String id) async {
    if (!identical(scope, known)) throw SessionChanged();
    cache.remove(id);
  }
}

Future<void> waitUntil(Future<bool> Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!await predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition was not reached before timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  testWidgets(
    'voice route waits on the shared consent provider and fails closed',
    (tester) async {
      final scope = await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('t29-route');
        try {
          return await Sessions(
            MemorySecret(),
            dir,
          ).activate(testTokens('route'));
        } finally {
          await dir.delete(recursive: true);
        }
      });
      final sessions = _RouteSessions(scope!)..seedIdentity();
      final api = _RouteApi(
        Uri.https('example.invalid'),
        _RouteTransport(),
        sessions,
      );
      final gate = Completer<ConsentGate>();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiProvider.overrideWith((_) async => api),
            consentProvider.overrideWith((_) => gate.future),
          ],
          child: const HighEqApp(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ShareHost), findsOneWidget);
      expect(find.byType(VoiceRetentionJanitorHost), findsOneWidget);

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(navigator.pushNamed('/voice'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(VoicePage), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      gate.completeError(StateError('consent unavailable'));
      await tester.pump();

      expect(find.byType(VoicePage), findsNothing);
      expect(find.text('无法确认语音授权，请稍后重试。'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'capture banner stays visible and lifecycle pause stops capture',
    (tester) async {
      late VoiceHarness harness;
      await tester.runAsync(() async {
        harness = await VoiceHarness.create(clock: DateTime.now());
        await harness.controller.initialize();
        expect(await harness.controller.start(), isTrue);
      });
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        MaterialApp(home: VoicePage(controller: harness.controller)),
      );
      await tester.pump();

      expect(find.text('正在本地分析语音（不保存录音）'), findsOneWidget);
      expect(find.text('0:00'), findsOneWidget);
      expect(find.text('转写不可用'), findsOneWidget);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();

      expect(harness.controller.isCapturing, isFalse);
      expect(harness.platform.stopCalls, greaterThan(0));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('lifecycle pause cancels a start still awaiting consent', (
    tester,
  ) async {
    late VoiceHarness harness;
    late Future<bool> starting;
    final gate = Completer<void>();
    await tester.runAsync(() async {
      harness = await VoiceHarness.create(clock: DateTime.now());
      await harness.controller.initialize();
      harness.access.readGate = gate;
      starting = harness.controller.start();
      await waitUntil(() async => harness.access.readCalls == 1);
    });
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      MaterialApp(home: VoicePage(controller: harness.controller)),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    expect(harness.controller.status, VoiceStatus.idle);
    gate.complete();
    await tester.runAsync(() => starting);

    expect(harness.controller.isCapturing, isFalse);
    expect(harness.platform.startCalls, 0);
    expect(harness.platform.stopCalls, greaterThan(0));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('320 wide with large text has no render overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late VoiceHarness harness;
    await tester.runAsync(() async {
      harness = await VoiceHarness.create(
        clock: DateTime.now(),
        retentionGranted: true,
      );
      await harness.controller.initialize();
      expect(await harness.controller.start(), isTrue);
    });
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: VoicePage(controller: harness.controller),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('正在录音并本地分析'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
