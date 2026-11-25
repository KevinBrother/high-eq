import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/consent.dart';
import 'package:high_eq/core/providers.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/features/emotion/assist/release_flags.dart';
import 'package:high_eq/features/health/platform.dart';
import 'package:high_eq/features/health/sync.dart';
import 'package:high_eq/features/home/shell.dart';
import 'package:high_eq/features/marks/page.dart';
import 'package:high_eq/features/membership/page.dart';
import 'package:high_eq/features/onboarding/account_entry.dart';
import 'package:high_eq/features/onboarding/login.dart';
import 'package:high_eq/features/reviews/page.dart';
import 'package:high_eq/features/voice/access.dart';
import 'package:high_eq/features/voice/controller.dart';
import 'package:high_eq/features/voice/page.dart';
import 'package:high_eq/features/voice/platform.dart';
import 'package:high_eq/features/voice/store.dart';
import 'package:high_eq/main.dart';
import 'package:http/http.dart' as http;

import '../client_test.dart' show Handler, response;
import '../isolation_test.dart' show MemorySecret, tokens;
import '../privacy/account_journey_test.dart'
    show
        account,
        currentPage,
        deadline,
        pumpUntil,
        pumpUntilCondition,
        reveal,
        tapVisible;

const _privateContactA = 'synthetic-contact-a';
const _privateContactB = 'synthetic-contact-b';
const _empty = {'items': [], 'next_cursor': null};
const _mark = {
  'id': 'synthetic-mark',
  'marked_at': '2026-11-25T02:00:00Z',
  'scene': 'work',
};

Map<String, Object?> _group(String? contact, int count) => {
  'contact_id': contact,
  'scene': 'work',
  'manual_count': count,
  'confirmed_self_count': 0,
};

Map<String, Object?> _baselineFixture(int heartSeconds) {
  Map<String, Object?> duration(int days, int seconds, {double? base}) => {
    'valid_days': days,
    'today_valid_seconds': seconds,
    'ready': base != null,
    'reason': base == null ? '有效日不足 7 天' : '基线已就绪',
    'baseline': base,
    'threshold': base == null ? null : base + 6,
  };
  return {
    'heart_rate': duration(2, heartSeconds),
    'speech_rate': duration(0, 0),
    'volume': duration(7, 1875, base: -30),
    'pitch': duration(1, 35),
    'hrv': {
      'readings': 9,
      'sampling_days': 3,
      'ready_for_alert': false,
      'reason': '仅供历史趋势，不参与提醒',
    },
  };
}

class _SyntheticHealthPort implements HealthPort {
  _SyntheticHealthPort({this.onPrompt});

  final void Function()? onPrompt;

  @override
  Future<String?> source() async => 'health_connect';

  @override
  Future<bool> request({void Function()? onSystemPrompt}) async {
    onSystemPrompt?.call();
    onPrompt?.call();
    return true;
  }

  @override
  Future<bool> queryable() async => true;

  @override
  Future<void> stop() async {}

  @override
  Future<List<List>> read(int from, int to) async => const [];
}

void main() {
  late Directory cache;
  late MemorySecret secret;
  late Sessions sessions;
  late AppApi api;
  late AccountScope scope;
  late http.Request summaryRequest;
  late List<AppOp> calls;
  late List<(AppOp, String?)> requests;
  late List<String> voiceCalls;
  late List<String> healthCalls;
  late Future<http.StreamedResponse> Function(AppOp, http.Request) serve;
  late String? frozen;
  late DateTime? expiresAt;
  late Completer<String?> healthSource;
  const health = MethodChannel('cn.higheq/health-history');
  final summaryPage = currentPage<Scaffold>('/emotion');
  final emotionTitle = find.text('情绪辅助');
  final count17 = find.text('手动记录 17 次');
  final reload = find.text('重新读取汇总');

  Map<String, Object?> rights() => {
    'tier': expiresAt == null ? 'free' : 'member',
    'expires_at': expiresAt?.toUtc().toIso8601String(),
    'auto_watch_alert_available': true,
    'allowances': [
      {'feature': 'practice', 'remaining': expiresAt == null ? 3 : null},
    ],
  };

  Future<http.StreamedResponse> ordinary(AppOp op, http.Request req) async {
    switch (op) {
      case AppOp.getMe:
        return response(
          account(userId: sessions.active!.account, frozen: frozen),
        );
      case AppOp.listAssessments:
      case AppOp.listContacts:
      case AppOp.listSessions:
      case AppOp.listCards:
        return response(_empty);
      case AppOp.listConsents:
        return response({
          'items': [
            {'purpose': 'manual_mark', 'granted': true},
          ],
        });
      case AppOp.getTodayPlan:
      case AppOp.getGrowth:
        return response({'code': 'unavailable'}, 503);
      case AppOp.logout:
        return response({});
      case AppOp.getEntitlements:
        return response(rights());
      case AppOp.emotionSummary:
        summaryRequest = req;
        return response({
          'groups': [
            _group(_privateContactA, 17),
            _group(_privateContactB, 29),
          ],
        });
      case AppOp.createMark:
        expect(req.body, contains('request_id'));
        return response(_mark);
      case AppOp.listMarks:
        return response({
          'items': [_mark],
          'next_cursor': null,
        });
      default:
        fail('unexpected operation: ${op.name}');
    }
  }

  Future<void> mount(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(health, (call) async {
      healthCalls.add(call.method);
      return call.method == 'source' ? await healthSource.future : null;
    });
    messenger.setMockMethodCallHandler(
      MethodChannelVoiceCapture.controlChannel,
      (call) async {
        voiceCalls.add(call.method);
        return false;
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('cn.higheq/voice-capture/pcm'),
      (call) async {
        voiceCalls.add('pcm:${call.method}');
        return null;
      },
    );
    addTearDown(() {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      messenger.setMockMethodCallHandler(health, null);
      messenger.setMockMethodCallHandler(
        MethodChannelVoiceCapture.controlChannel,
        null,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('cn.higheq/voice-capture/pcm'),
        null,
      );
    });
    await tester.runAsync(() async {
      cache = await Directory.systemTemp.createTemp('t32b-formal-entry.');
      secret = MemorySecret();
      sessions = Sessions(secret, cache);
      scope = await sessions.activate(tokens('synthetic-A'));
    });
    addTearDown(() => cache.delete(recursive: true));
    final transport = Handler()
      ..handle = (op, req) {
        calls.add(op);
        requests.add((op, req.headers['Authorization']));
        return serve(op, req);
      };
    api = AppApi(Uri.https('example.invalid'), transport, sessions);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiProvider.overrideWith((_) => api)],
        child: const HighEqApp(),
      ),
    );
  }

  Future<void> navigate(WidgetTester tester, String route) async {
    final nav = find.byType(Navigator);
    await pumpUntil(tester, nav);
    unawaited(tester.state<NavigatorState>(nav).pushNamed<void>(route));
    await tester.pump();
  }

  Future<void> tapIn(WidgetTester tester, Finder page, String label) async {
    final text = find.descendant(of: page, matching: find.text(label));
    await reveal(tester, page, text);
    await tapVisible(tester, text);
  }

  Future<void> summaryCount(WidgetTester tester, Finder count) async {
    await pumpUntil(tester, summaryPage);
    await pumpUntil(tester, find.text('按对象与场景的回看'));
    await reveal(tester, summaryPage, count);
    await pumpUntil(tester, count.hitTestable());
  }

  Future<void> drain(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
  }

  Future<void> goBack(WidgetTester tester) async {
    await tapVisible(tester, find.byType(BackButton));
    await drain(tester);
  }

  final member = currentPage<MemberPage>('/membership');
  final me = currentPage<HomeShell>('/me');
  final count29 = find.text('手动记录 29 次');

  Future<void> openMeFromPractice(WidgetTester tester) async {
    await tapVisible(tester, find.text('暂不测评'));
    await pumpUntil(tester, currentPage<HomeShell>('/practice'));
    await tapVisible(tester, find.widgetWithText(NavigationDestination, '我的'));
    await pumpUntil(tester, me);
  }

  Future<void> openMemberSummary(WidgetTester tester) async {
    await tapIn(tester, me, '会员与今日额度');
    await tapIn(tester, member, '查看本人情绪汇总');
  }

  Future<Completer<http.StreamedResponse>> holdRotation(
    WidgetTester tester,
  ) async {
    final pending = Completer<http.StreamedResponse>();
    addTearDown(() {
      if (!pending.isCompleted) {
        pending.complete(response({'code': 'unauthenticated'}, 401));
      }
    });
    var oldSessionRetired = false;
    serve = (op, req) async {
      const rejected = {'code': 'unauthenticated'};
      final bearer = req.headers['Authorization'];
      if (op == AppOp.refreshTokens) {
        expect(jsonDecode(req.body), {'refresh_token': 'refresh'});
        if (oldSessionRetired) return response(rejected, 401);
        // Like the real server, commit the rotation before releasing its 200.
        oldSessionRetired = true;
        return pending.future;
      }
      if (bearer == 'Bearer access' &&
          (op == AppOp.emotionSummary ||
              (op == AppOp.getEntitlements && oldSessionRetired))) {
        return response(rejected, 401);
      }
      if (op == AppOp.emotionSummary && bearer == 'Bearer renewed-A') {
        return response({
          'groups': [_group(_privateContactA, 29)],
        });
      }
      if (op == AppOp.emotionSummary && bearer == 'Bearer next-login') {
        return response({
          'groups': [_group(_privateContactB, 41)],
        });
      }
      return ordinary(op, req);
    };
    await tapVisible(tester, reload);
    await pumpUntilCondition(
      tester,
      () => calls.contains(AppOp.refreshTokens),
      reason: 'summary 401 must initiate credential rotation',
    );
    return pending;
  }

  Tokens newCredentials(String account, String access, String refresh) =>
      Tokens(
        account,
        access,
        refresh,
        DateTime.now().add(const Duration(hours: 1)),
      );

  Tokens renewedA() =>
      newCredentials('synthetic-A', 'renewed-A', 'renewed-refresh');
  int summaryReads() => calls.where((op) => op == AppOp.emotionSummary).length;

  void testOnPhone(String description, WidgetTesterCallback test) =>
      testWidgets(
        description,
        test,
        variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      );

  setUp(() {
    calls = [];
    requests = [];
    voiceCalls = [];
    healthCalls = [];
    frozen = null;
    expiresAt = DateTime.now().add(const Duration(hours: 1));
    healthSource = Completer<String?>();
    serve = ordinary;
  });

  tearDown(() {
    if (!healthSource.isCompleted) healthSource.complete(null);
  });

  testOnPhone('我的 opens official read-only summary while health source hangs', (
    tester,
  ) async {
    await mount(tester);
    await navigate(tester, '/me');
    await pumpUntil(tester, currentPage<HomeShell>('/me'));
    await pumpUntilCondition(
      tester,
      () =>
          calls.contains(AppOp.listConsents) && healthCalls.contains('source'),
      reason:
          'startup assessment and T28 foreground protection must be mounted',
    );
    final before = calls.length;
    await tapIn(tester, currentPage<HomeShell>('/me'), '情绪辅助与本人汇总');
    await pumpUntil(tester, summaryPage);
    await summaryCount(tester, count17);
    expect(find.text('已关联对象 1 · 职场'), findsOneWidget);
    final page = find.ancestor(
      of: emotionTitle,
      matching: find.byType(Scaffold),
    );
    await reveal(tester, page, find.text('手动记录 29 次'));
    expect(find.text('已关联对象 2 · 职场'), findsOneWidget);
    expect(find.textContaining(_privateContactA), findsNothing);
    expect(find.textContaining(_privateContactB), findsNothing);
    expect(summaryRequest.url.path, '/v1/emotion-summary');
    expect(summaryRequest.headers['Authorization'], 'Bearer access');
    expect(calls.skip(before), [
      AppOp.getEntitlements,
      AppOp.emotionSummary,
      AppOp.listConsents,
    ]);
    expect(healthCalls, ['source']);
    expect(voiceCalls, isEmpty);
  });

  testOnPhone('free account reaches real membership, returns and refreshes', (
    tester,
  ) async {
    expiresAt = null;
    await mount(tester);
    await navigate(tester, '/emotion');
    await pumpUntil(tester, summaryPage);
    final summary = find.ancestor(
      of: emotionTitle,
      matching: find.byType(Scaffold),
    );
    await tapIn(tester, summary, '查看会员方案');
    final member = currentPage<MemberPage>('/membership');
    await pumpUntil(tester, member);
    expect(calls, isNot(contains(AppOp.emotionSummary)));
    expiresAt = DateTime.now().add(const Duration(hours: 1));
    await tapIn(tester, member, '查看本人情绪汇总');
    await summaryCount(tester, count17);
    // The backlink returns to the original summary. Back continues to startup.
    await goBack(tester);
    await pumpUntilCondition(
      tester,
      () => emotionTitle.evaluate().isEmpty,
      reason: 'back must leave the original summary',
    );
    expect(find.byType(MemberPage), findsNothing);
  });

  for (final expired in [false, true]) {
    testOnPhone(
      '${expired ? 'expired' : 'free'} account saves quick mark and opens T24 prefill',
      (tester) async {
        expiresAt = expired
            ? DateTime.now().subtract(const Duration(hours: 1))
            : null;
        await mount(tester);
        await navigate(tester, '/emotion');
        await pumpUntil(tester, summaryPage);
        await tapVisible(tester, find.text('我上头了'));
        final marks = currentPage<MarksPage>('/marks');
        await pumpUntil(tester, marks);
        expect(tester.widget<MarksPage>(marks).quick, isTrue);
        await tapIn(tester, marks, '写复盘');
        final review = currentPage<ReviewPage>('/marks/review');
        await pumpUntil(tester, review);
        expect(
          tester.widget<ReviewPage>(review).prefill?.markId,
          'synthetic-mark',
        );
        expect(calls.where((op) => op == AppOp.createMark), hasLength(1));
        expect(calls, isNot(contains(AppOp.emotionSummary)));
        expect(voiceCalls, isEmpty);
      },
    );
  }

  testOnPhone('voice backlink uses real page and returns without capture', (
    tester,
  ) async {
    await mount(tester);
    await navigate(tester, '/emotion');
    await pumpUntil(tester, summaryPage);
    await tapVisible(tester, find.text('打开语音页'));
    final voice = currentPage<VoicePage>('/voice');
    await pumpUntil(tester, voice);
    await tapIn(tester, voice, '查看本人情绪汇总');
    await summaryCount(tester, count17);
    expect(voiceCalls, isNot(contains('requestPermission')));
    expect(voiceCalls, isNot(contains('start')));
    expect(calls, isNot(contains(AppOp.setConsent)));
    await goBack(tester);
    expect(find.byType(VoicePage), findsNothing);
  });

  for (final (label, destination) in [
    ('会员与今日额度', currentPage<MemberPage>('/membership')),
    ('语音特征与录音', currentPage<VoicePage>('/voice')),
  ]) {
    testOnPhone('$label opens the summary from the normal My navigation', (
      tester,
    ) async {
      await mount(tester);
      await navigate(tester, '/me');
      await tapIn(tester, currentPage<HomeShell>('/me'), label);
      await tapIn(tester, destination, '查看本人情绪汇总');
      await summaryCount(tester, count17);
      if (label == '语音特征与录音') {
        await tapVisible(tester, find.text('打开语音页'));
      } else {
        await goBack(tester);
      }
      await pumpUntil(tester, destination);
      expect(summaryPage, findsNothing);
      expect(voiceCalls, isNot(contains('requestPermission')));
      expect(calls, isNot(contains(AppOp.setConsent)));
    });
  }

  final baselineTitle = find.text('信号基线进度');
  final heart210 = find.text('今日 210 / 1800 秒');
  final heart420 = find.text('今日 420 / 1800 秒');
  const baselineRetry = '重新读取基线';

  testOnPhone('T32B baseline reads authorized history from the member route', (
    tester,
  ) async {
    serve = (op, req) async {
      if (op == AppOp.listConsents) {
        if (req.url.queryParameters['cursor'] == 'next-consent') {
          return response({
            'items': [
              {'purpose': 'voice', 'granted': true},
            ],
            'next_cursor': null,
          });
        }
        return response({
          'items': [
            {'purpose': 'health', 'granted': true},
          ],
          'next_cursor': 'next-consent',
        });
      }
      if (op == AppOp.getBaselines) {
        expect(req.method, 'GET');
        expect(req.url.path, '/v1/signal-baselines');
        expect(req.url.hasQuery, isFalse);
        expect(req.headers['Authorization'], 'Bearer access');
        expect(req.body, isEmpty);
        return response(_baselineFixture(210));
      }
      return ordinary(op, req);
    };
    await mount(tester);
    await navigate(tester, '/me');
    await tapIn(tester, me, '会员与今日额度');
    await pumpUntilCondition(
      tester,
      () => healthCalls.contains('source'),
      reason: 'wait for the pre-existing app-level health source check',
    );
    final before = calls.length;
    final previousHealth = List.of(healthCalls);
    await tapIn(tester, member, '查看本人情绪汇总');
    await summaryCount(tester, count17);
    await pumpUntilCondition(
      tester,
      () => calls.contains(AppOp.getBaselines),
      reason: 'formal membership route must read the current T30 baseline',
    );
    await reveal(tester, summaryPage, baselineTitle);
    await pumpUntil(tester, heart210);
    expect(find.text('2 / 7 个有效日'), findsOneWidget);
    expect(find.text('今日 1875 / 1800 秒'), findsOneWidget);
    expect(find.text('今日 35 / 1800 秒'), findsOneWidget);
    expect(find.text('9 次读数 · 3 个采样日'), findsOneWidget);
    expect(find.text('本手机的设备端转写来源当前不可用。'), findsOneWidget);
    expect(calls.skip(before), [
      AppOp.getEntitlements,
      AppOp.emotionSummary,
      AppOp.listConsents,
      AppOp.listConsents,
      AppOp.getBaselines,
      AppOp.listConsents,
      AppOp.listConsents,
    ]);
    expect(healthCalls, previousHealth);
    expect(voiceCalls, isEmpty);
  });

  testOnPhone('T32B baseline failure and revocation never reuse old counts', (
    tester,
  ) async {
    var status = 200;
    var heartSeconds = 210;
    var healthGranted = true;
    serve = (op, req) async => switch (op) {
      AppOp.listConsents => response({
        'items': [
          {'purpose': 'health', 'granted': healthGranted},
          {'purpose': 'voice', 'granted': false},
        ],
      }),
      AppOp.getBaselines =>
        status == 200
            ? response(_baselineFixture(heartSeconds))
            : response({'code': 'unavailable'}, status),
      _ => ordinary(op, req),
    };
    await mount(tester);
    await navigate(tester, '/me');
    await openMemberSummary(tester);
    await reveal(tester, summaryPage, baselineTitle);
    await pumpUntil(tester, heart210);
    expect(find.text('语音特征授权已关闭。'), findsNWidgets(3));
    expect(find.text('今日 1875 / 1800 秒'), findsNothing);

    status = 503;
    await tapIn(tester, summaryPage, baselineRetry);
    await pumpUntil(tester, find.text('暂时无法读取基线进度，请重试。'));
    expect(heart210, findsNothing);
    expect(find.text('今日 0 / 1800 秒'), findsNothing);

    status = 200;
    heartSeconds = 420;
    await tapIn(tester, summaryPage, baselineRetry);
    await pumpUntil(tester, heart420);
    expect(heart210, findsNothing);

    healthGranted = false;
    final reads = calls.where((op) => op == AppOp.getBaselines).length;
    await tapIn(tester, summaryPage, baselineRetry);
    await pumpUntilCondition(
      tester,
      () => find.text('健康数据授权已关闭。').evaluate().length == 2,
      reason: 'heart rate and HRV must both hide revoked data',
    );
    expect(heart420, findsNothing);
    expect(calls.where((op) => op == AppOp.getBaselines), hasLength(reads));
    expect(find.text('我上头了', skipOffstage: false), findsOneWidget);
  });

  testOnPhone('T32B withdrawal during an in-flight baseline hides health rows', (
    tester,
  ) async {
    var healthGranted = true;
    var baselineStarted = false;
    final pending = Completer<http.StreamedResponse>();
    serve = (op, req) async {
      if (op == AppOp.listConsents) {
        return response({
          'items': [
            {'purpose': 'health', 'granted': healthGranted},
            {'purpose': 'voice', 'granted': false},
          ],
        });
      }
      if (op == AppOp.getBaselines) {
        baselineStarted = true;
        return pending.future;
      }
      return ordinary(op, req);
    };
    await mount(tester);
    await navigate(tester, '/me');
    await openMemberSummary(tester);
    await pumpUntilCondition(
      tester,
      () => baselineStarted,
      reason: 'the aggregate request must already be in flight',
    );

    healthGranted = false;
    pending.complete(response(_baselineFixture(210)));
    await pumpUntilCondition(
      tester,
      () => find.text('健康数据授权已关闭。').evaluate().length == 2,
      reason: 'a withdrawal committed after the consent read must hide heart rate and HRV',
    );
    expect(heart210, findsNothing);
    expect(find.text('9 次读数 · 3 个采样日'), findsNothing);
    expect(find.text('语音特征授权已关闭。'), findsNWidgets(3));
    final baselineAt = calls.indexOf(AppOp.getBaselines);
    expect(
      calls.sublist(baselineAt + 1),
      contains(AppOp.listConsents),
      reason: 'consent has to be re-read after the aggregate response',
    );
    expect(find.text('我上头了'), findsOneWidget);
  });

  testOnPhone('T32B baseline 403 hides the summary adopted in the same round', (
    tester,
  ) async {
    var baselineStatus = 200;
    serve = (op, req) async => switch (op) {
      AppOp.listConsents => response({
        'items': [
          {'purpose': 'health', 'granted': true},
          {'purpose': 'voice', 'granted': false},
        ],
      }),
      AppOp.getBaselines => baselineStatus == 200
          ? response(_baselineFixture(210))
          : response({'code': 'forbidden'}, baselineStatus),
      _ => ordinary(op, req),
    };
    await mount(tester);
    await navigate(tester, '/me');
    await openMemberSummary(tester);
    await reveal(tester, summaryPage, baselineTitle);
    await pumpUntil(tester, heart210);
    expect(count17, findsOneWidget);

    baselineStatus = 403;
    await tapIn(tester, summaryPage, baselineRetry);
    await pumpUntil(tester, find.text('会员汇总已隐藏：没有获得所需授权。'));
    expect(count17, findsNothing);
    expect(heart210, findsNothing);
    expect(baselineTitle, findsNothing);
    expect(find.text('我上头了'), findsOneWidget);
    expect(find.text('重新读取汇总'), findsOneWidget);
  });

  testOnPhone('T32B known voice withdrawal blocks a late stale baseline', (
    tester,
  ) async {
    var baselineStarted = false;
    final pending = Completer<http.StreamedResponse>();
    serve = (op, req) async {
      if (op == AppOp.listConsents) {
        return response({
          'items': [
            {'purpose': 'health', 'granted': true},
            {'purpose': 'voice', 'granted': true},
          ],
        });
      }
      if (op == AppOp.setConsent) {
        expect(req.url.path, '/v1/me/consents/voice');
        return response({'purpose': 'voice', 'granted': false});
      }
      if (op == AppOp.getBaselines) {
        baselineStarted = true;
        return pending.future;
      }
      return ordinary(op, req);
    };
    await mount(tester);
    await navigate(tester, '/me');
    await openMemberSummary(tester);
    await pumpUntilCondition(
      tester,
      () => baselineStarted,
      reason: 'the stale aggregate must be in flight',
    );

    await tester.runAsync(
      () =>
          ApiVoiceAccess(api).setConsent(scope, CollectionPurpose.voice, false),
    );
    await tester.pump();
    pending.complete(response(_baselineFixture(210)));
    await pumpUntil(tester, heart210);
    expect(find.text('今日 1875 / 1800 秒'), findsNothing);
    expect(find.text('今日 35 / 1800 秒'), findsNothing);
    expect(find.text('语音特征授权已关闭。'), findsNWidgets(3));
    expect(find.text('9 次读数 · 3 个采样日'), findsOneWidget);
    expect(calls.where((op) => op == AppOp.getBaselines), hasLength(1));
  });

  testOnPhone('T32B known health withdrawal clears only health rows', (
    tester,
  ) async {
    serve = (op, req) async => switch (op) {
      AppOp.listConsents => response({
        'items': [
          {'purpose': 'health', 'granted': true},
          {'purpose': 'voice', 'granted': true},
        ],
      }),
      AppOp.getBaselines => response(_baselineFixture(210)),
      _ => ordinary(op, req),
    };
    await mount(tester);
    await navigate(tester, '/me');
    await openMemberSummary(tester);
    await reveal(tester, summaryPage, baselineTitle);
    await pumpUntil(tester, heart210);

    sessions.noteConsentWithdrawn(scope, 'health');
    await tester.pump();
    expect(heart210, findsNothing);
    expect(find.text('9 次读数 · 3 个采样日'), findsNothing);
    expect(find.text('健康数据授权已关闭。'), findsNWidgets(2));
    expect(find.text('今日 1875 / 1800 秒'), findsOneWidget);
    expect(find.text('今日 35 / 1800 秒'), findsOneWidget);
    expect(calls.where((op) => op == AppOp.getBaselines), hasLength(1));
  });

  testOnPhone(
    'T32B offline health withdrawal hides old health rows immediately',
    (tester) async {
      var offline = false;
      serve = (op, req) async {
        if (op == AppOp.listConsents) {
          if (offline) return response({'code': 'unavailable'}, 503);
          return response({
            'items': [
              {'purpose': 'health', 'granted': true},
              {'purpose': 'voice', 'granted': true},
            ],
          });
        }
        if (op == AppOp.getBaselines) return response(_baselineFixture(210));
        return ordinary(op, req);
      };
      await mount(tester);
      await navigate(tester, '/me');
      await openMemberSummary(tester);
      await reveal(tester, summaryPage, baselineTitle);
      await pumpUntil(tester, heart210);
      expect(find.text('9 次读数 · 3 个采样日'), findsOneWidget);

      offline = true;
      final sync = HealthSync(
        api,
        scope,
        ConsentGate(api),
        _SyntheticHealthPort(),
      );
      addTearDown(sync.close);
      await tester.runAsync(
        () => expectLater(sync.withdraw(), throwsA(isA<ApiFailure>())),
      );
      await tester.pump();

      // The consent write could not reach the server, but the durable local
      // intent is already a known withdrawal and must mask the old readings.
      expect(sessions.hasWithdrawalIntent(scope), isTrue);
      expect(heart210, findsNothing);
      expect(find.text('9 次读数 · 3 个采样日'), findsNothing);
      expect(find.text('健康数据授权已关闭。'), findsNWidgets(2));
      expect(find.text('今日 1875 / 1800 秒'), findsOneWidget);
      expect(find.text('今日 35 / 1800 秒'), findsOneWidget);
      expect(calls.where((op) => op == AppOp.getBaselines), hasLength(1));
    },
  );

  testOnPhone(
    'T32B offline voice revocation masks formal voice rows at once',
    (tester) async {
      serve = (op, req) async {
        if (op == AppOp.listConsents) {
          return response({
            'items': [
              {'purpose': 'health', 'granted': true},
              {'purpose': 'voice', 'granted': true},
            ],
          });
        }
        if (op == AppOp.setConsent) {
          return response({'code': 'unavailable'}, 503);
        }
        if (op == AppOp.getBaselines) return response(_baselineFixture(210));
        return ordinary(op, req);
      };
      await mount(tester);
      await navigate(tester, '/me');
      await openMemberSummary(tester);
      await reveal(tester, summaryPage, baselineTitle);
      await pumpUntil(tester, heart210);
      expect(find.text('今日 1875 / 1800 秒'), findsOneWidget);
      expect(find.text('今日 35 / 1800 秒'), findsOneWidget);

      // Same entry as the voice page's confirmation button, with consent
      // writes offline.
      final controller = VoiceController(
        sessions: sessions,
        scope: scope,
        access: ApiVoiceAccess(api),
        uploader: ApiVoiceUploader(api),
        platform: MethodChannelVoiceCapture(),
        store: VoiceWindowStore(sessions, scope),
      );
      addTearDown(controller.dispose);
      bool? complete;
      Object? failure;
      await tester.runAsync(() async {
        unawaited(
          controller.revokeVoice().then((value) {
            complete = value;
          }, onError: (Object error) {
            failure = error;
          }),
        );
      });
      await pumpUntilCondition(
        tester,
        () => sessions.voiceRevocation.value,
        reason: 'the durable local marker must be published at once',
      );
      await pumpUntilCondition(
        tester,
        () => complete != null || failure != null,
        reason: 'the offline revocation attempt must settle',
      );
      expect(failure, isNull);
      expect(complete, isFalse);
      await tester.pump();

      // The durable local marker is known immediately; no baseline GET is
      // needed to hide the three voice rows, and health stays visible.
      expect(sessions.voiceRevocation.value, isTrue);
      expect(controller.voiceRevocationPending, isTrue);
      expect(find.text('语音特征授权已关闭。'), findsNWidgets(3));
      expect(find.text('今日 1875 / 1800 秒'), findsNothing);
      expect(find.text('今日 35 / 1800 秒'), findsNothing);
      expect(heart210, findsOneWidget);
      expect(find.text('9 次读数 · 3 个采样日'), findsOneWidget);
      expect(calls.where((op) => op == AppOp.getBaselines), hasLength(1));
      expect(calls.where((op) => op == AppOp.setConsent), hasLength(2));

      // A manual re-read while the server still reports granted voice must not
      // restore the rows: the local marker outlives the failed sync.
      await tapIn(tester, summaryPage, baselineRetry);
      await pumpUntilCondition(
        tester,
        () =>
            calls.where((op) => op == AppOp.getBaselines).length == 2 &&
            find.text('语音特征授权已关闭。').evaluate().length == 3 &&
            heart210.evaluate().isNotEmpty,
        reason: 'the manual re-read completed but must stay masked',
      );
      await tester.pump();
      expect(find.text('语音特征授权已关闭。'), findsNWidgets(3));
      expect(find.text('今日 1875 / 1800 秒'), findsNothing);
      expect(find.text('今日 35 / 1800 秒'), findsNothing);
      expect(heart210, findsOneWidget);
      expect(find.text('9 次读数 · 3 个采样日'), findsOneWidget);
      expect(calls.where((op) => op == AppOp.setConsent), hasLength(2));
    },
  );

  testOnPhone(
    'T32B old false consent read cannot veto a later held regrant receipt',
    (tester) async {
      var holdOldConsent = false;
      Completer<http.StreamedResponse>? oldConsent;
      Completer<http.StreamedResponse>? regrant;
      addTearDown(() {
        if (!(oldConsent?.isCompleted ?? true)) {
          oldConsent!.complete(
            response({
              'items': [
                {'purpose': 'health', 'granted': true},
                {'purpose': 'voice', 'granted': false},
              ],
            }),
          );
        }
        if (!(regrant?.isCompleted ?? true)) {
          regrant!.complete(response({'purpose': 'voice', 'granted': true}));
        }
      });
      serve = (op, req) async {
        if (op == AppOp.listConsents) {
          if (holdOldConsent) {
            holdOldConsent = false;
            oldConsent = Completer();
            return oldConsent!.future;
          }
          return response({
            'items': [
              {'purpose': 'health', 'granted': true},
              {'purpose': 'voice', 'granted': true},
            ],
          });
        }
        if (op == AppOp.setConsent) {
          expect(req.url.path, '/v1/me/consents/voice');
          expect(jsonDecode(req.body)['granted'], isTrue);
          regrant = Completer();
          return regrant!.future;
        }
        if (op == AppOp.getBaselines) return response(_baselineFixture(210));
        return ordinary(op, req);
      };
      await mount(tester);
      await navigate(tester, '/me');
      await openMemberSummary(tester);
      await reveal(tester, summaryPage, baselineTitle);
      await pumpUntil(tester, heart210);
      expect(find.text('今日 1875 / 1800 秒'), findsOneWidget);

      // Start a read whose consent answer will be an old false, then send the
      // real regrant while that read is still in flight.
      holdOldConsent = true;
      await tapIn(tester, summaryPage, baselineRetry);
      await pumpUntilCondition(
        tester,
        () => oldConsent != null,
        reason: 'the stale consent read must be in flight',
      );
      var grantPending = true;
      Object? grantFailure;
      await tester.runAsync(() async {
        unawaited(
          ApiVoiceAccess(api)
              .setConsent(scope, CollectionPurpose.voice, true)
              .then<void>(
                (_) => grantPending = false,
                onError: (Object error) {
                  grantFailure = error;
                  grantPending = false;
                },
              ),
        );
      });
      await pumpUntilCondition(
        tester,
        () => regrant != null,
        reason: 'the held regrant request must reach the transport',
      );

      // Deliver the stale denial first, then the newer explicit receipt.
      oldConsent!.complete(
        response({
          'items': [
            {'purpose': 'health', 'granted': true},
            {'purpose': 'voice', 'granted': false},
          ],
        }),
      );
      await pumpUntilCondition(
        tester,
        () => sessions.consentWithdrawals.value.contains('voice'),
        reason: 'the stale denial observation must land before the receipt',
      );
      regrant!.complete(response({'purpose': 'voice', 'granted': true}));
      await pumpUntilCondition(
        tester,
        () => sessions.consentVersion('voice') == 1,
        reason: 'the newer explicit receipt must be accepted',
      );
      await pumpUntilCondition(
        tester,
        () => !grantPending,
        reason: 'the regrant request must settle',
      );
      expect(grantFailure, isNull);

      // The observation must not have advanced the purpose version, so the
      // receipt still belongs to the decision and wins.
      expect(sessions.consentVersion('voice'), 1);
      expect(sessions.consentWithdrawals.value, isNot(contains('voice')));
      expect(calls.where((op) => op == AppOp.setConsent), hasLength(1));

      // Recovery needs only a fresh aggregate, not another grant.
      await pumpUntilCondition(
        tester,
        () => find.text(baselineRetry).evaluate().isNotEmpty,
        reason: 'the reload round must settle before the recovery read',
      );
      await tapIn(tester, summaryPage, baselineRetry);
      await pumpUntilCondition(
        tester,
        () => find.text('今日 1875 / 1800 秒').evaluate().isNotEmpty,
        reason: 'a new aggregate must restore voice rows after the receipt',
      );
      expect(find.text('今日 35 / 1800 秒'), findsOneWidget);
      expect(calls.where((op) => op == AppOp.setConsent), hasLength(1));
    },
  );

  for (final receipt in <Map<String, Object?>>[
    {'purpose': 'health', 'granted': true},
    {'purpose': 'health', 'granted': false},
  ]) {
    testOnPhone(
      'T32B health regrant $receipt keeps the local withdrawal decision',
      (tester) async {
        expiresAt = DateTime.now().add(const Duration(days: 1));
        serve = (op, req) async {
          if (op == AppOp.getEntitlements) return response(rights());
          if (op == AppOp.setConsent) {
            expect(req.url.path, '/v1/me/consents/health');
            expect(jsonDecode(req.body)['granted'], isTrue);
            return response(receipt);
          }
          return ordinary(op, req);
        };
        await mount(tester);
        sessions.noteConsentWithdrawn(scope, 'health');
        expect(sessions.consentWithdrawals.value, contains('health'));

        final sync = HealthSync(
          api,
          scope,
          ConsentGate(api),
          _SyntheticHealthPort(),
        );
        addTearDown(sync.close);
        var settled = false;
        Object? failure;
        await tester.runAsync(() async {
          unawaited(
            sync.enable().then<void>(
              (_) => settled = true,
              onError: (Object error) {
                failure = error;
                settled = true;
              },
            ),
          );
        });
        await pumpUntilCondition(
          tester,
          () => settled,
          reason: 'the rejected health regrant must settle',
        );
        expect(failure, isA<FormatException>());

        // A receipt that does not prove an accepted grant must not publish a
        // new decision or clear the local withdrawal marker.
        expect(sessions.consentVersion('health'), 1);
        expect(sessions.consentWithdrawals.value, contains('health'));
      },
    );
  }

  const healthStamp = '2026-11-26T00:00:00.000Z';
  Map<String, Object?> healthRow(bool granted) => {
    'purpose': 'health',
    'version': '2026-11',
    'granted': granted,
    'updated_at': healthStamp,
  };

  Future<void> completeBusiness(
    WidgetTester tester,
    Future<void> Function() action, {
    required bool expectFailure,
  }) async {
    var settled = false;
    Object? failure;
    await tester.runAsync(() async {
      unawaited(
        action().then<void>(
          (_) => settled = true,
          onError: (Object error) {
            failure = error;
            settled = true;
          },
        ),
      );
    });
    await pumpUntilCondition(
      tester,
      () => settled,
      reason: 'the health setting operation must settle',
    );
    if (expectFailure) {
      expect(failure, isNotNull);
    } else {
      expect(failure, isNull);
    }
  }

  for (final (label, receipt, acceptsOnServer) in <
    (String, Map<String, Object?>, bool)
  >[
    (
      'missing version',
      {'purpose': 'health', 'granted': true, 'updated_at': healthStamp},
      false,
    ),
    (
      'missing updated_at',
      {'purpose': 'health', 'version': '2026-11', 'granted': true},
      false,
    ),
    ('server keeps the withdrawal', {...healthRow(true)}, false),
  ]) {
    testOnPhone(
      'T32B rejected health regrant ($label) preserves the local decision',
      (tester) async {
        var serverGranted = false;
        expiresAt = DateTime.now().add(const Duration(days: 1));
        serve = (op, req) async {
          if (op == AppOp.listConsents) {
            return response({
              'items': [healthRow(serverGranted)],
            });
          }
          if (op == AppOp.setConsent) {
            expect(req.url.path, '/v1/me/consents/health');
            final granted = jsonDecode(req.body)['granted'];
            if (granted == true) {
              serverGranted = acceptsOnServer;
              return response(receipt);
            }
            serverGranted = false;
            return response(healthRow(false));
          }
          if (op == AppOp.getEntitlements) return response(rights());
          return ordinary(op, req);
        };
        await mount(tester);
        final sync = HealthSync(
          api,
          scope,
          ConsentGate(api),
          _SyntheticHealthPort(),
        );
        addTearDown(sync.close);

        await completeBusiness(tester, sync.withdraw, expectFailure: false);
        expect(sessions.consentVersion('health'), 1);
        expect(sessions.consentWithdrawals.value, contains('health'));

        await completeBusiness(tester, sync.enable, expectFailure: true);

        // The setting, the local marker and the decision version must all
        // still describe the confirmed withdrawal.
        final state = await tester.runAsync(sync.state);
        expect(state!['mode'], 'withdraw');
        expect(sessions.consentVersion('health'), 1);
        expect(sessions.consentWithdrawals.value, contains('health'));

        await navigate(tester, '/me');
        await openMemberSummary(tester);
        await pumpUntilCondition(
          tester,
          () =>
              find.text('健康数据授权已关闭。').evaluate().length == 2 &&
              find.text('今日 210 / 1800 秒').evaluate().isEmpty,
          reason: 'rejected health regrant must not expose health rows',
        );
      },
    );
  }

  testOnPhone(
    'T32B accepted health regrant publishes one consistent decision',
    (tester) async {
      var serverGranted = false;
      expiresAt = DateTime.now().add(const Duration(days: 1));
      serve = (op, req) async {
        if (op == AppOp.listConsents) {
          return response({
            'items': [healthRow(serverGranted)],
          });
        }
        if (op == AppOp.setConsent) {
          expect(req.url.path, '/v1/me/consents/health');
          final granted = jsonDecode(req.body)['granted'];
          if (granted == true) {
            serverGranted = true;
            return response(healthRow(true));
          }
          serverGranted = false;
          return response(healthRow(false));
        }
        if (op == AppOp.getEntitlements) return response(rights());
        if (op == AppOp.getBaselines) return response(_baselineFixture(210));
        return ordinary(op, req);
      };
      await mount(tester);
      final sync = HealthSync(
        api,
        scope,
        ConsentGate(api),
        _SyntheticHealthPort(),
      );
      addTearDown(sync.close);

      await completeBusiness(tester, sync.withdraw, expectFailure: false);
      await navigate(tester, '/me');
      await openMemberSummary(tester);
      await pumpUntilCondition(
        tester,
        () => find.text('健康数据授权已关闭。').evaluate().length == 2,
        reason: 'the withdrawn account starts hidden',
      );

      await completeBusiness(tester, sync.enable, expectFailure: false);

      // Acceptance and the local publish share the same validated contract.
      final state = await tester.runAsync(sync.state);
      expect(state!['mode'], 'on');
      expect(sessions.consentVersion('health'), 2);
      expect(sessions.consentWithdrawals.value, isNot(contains('health')));

      // Data follows only a fresh snapshot, now that the local decision is a
      // confirmed grant.
      await tapIn(tester, summaryPage, baselineRetry);
      await pumpUntilCondition(
        tester,
        () => find.text('今日 210 / 1800 秒').evaluate().isNotEmpty,
        reason: 'accepted regrant must show health rows after a fresh read',
      );
      expect(find.text('9 次读数 · 3 个采样日'), findsOneWidget);
      expect(find.text('语音特征授权已关闭。'), findsNWidgets(3));
    },
  );

  testOnPhone(
    'T32B pending health setting keeps withdrawal when foreground check denies',
    (tester) async {
      var serverGranted = false;
      expiresAt = DateTime.now().add(const Duration(days: 1));
      serve = (op, req) async {
        if (op == AppOp.listConsents) {
          return response({
            'items': [healthRow(serverGranted)],
          });
        }
        if (op == AppOp.setConsent) {
          final granted = jsonDecode(req.body)['granted'];
          serverGranted = granted == true;
          return response(healthRow(serverGranted));
        }
        if (op == AppOp.getEntitlements) return response(rights());
        return ordinary(op, req);
      };
      await mount(tester);
      late HealthSync sync;
      sync = HealthSync(
        api,
        scope,
        ConsentGate(api),
        _SyntheticHealthPort(onPrompt: () => sync.inactive()),
      );
      addTearDown(sync.close);

      await completeBusiness(tester, sync.withdraw, expectFailure: false);
      await completeBusiness(tester, sync.enable, expectFailure: false);

      // The OS prompt interrupted the foreground session, so this round is
      // waiting, not accepted. The confirmed withdrawal must survive intact.
      var state = await tester.runAsync(sync.state);
      expect(state!['mode'], 'pending');
      expect(sessions.consentVersion('health'), 1);
      expect(sessions.consentWithdrawals.value, contains('health'));

      // Foreground revalidation reads the server's ordinary denial.
      serverGranted = false;
      sync.resume();
      await completeBusiness(tester, sync.tick, expectFailure: false);

      state = await tester.runAsync(sync.state);
      expect(state!['mode'], 'paused');
      expect(sessions.consentVersion('health'), 1);
      expect(sessions.consentWithdrawals.value, contains('health'));

      await navigate(tester, '/me');
      await openMemberSummary(tester);
      await pumpUntilCondition(
        tester,
        () =>
            find.text('健康数据授权已关闭。').evaluate().length == 2 &&
            find.text('今日 210 / 1800 秒').evaluate().isEmpty,
        reason: 'a denied pending round must not expose health rows',
      );
    },
  );

  testOnPhone(
    'T32B pending health setting publishes once only when foreground accepts',
    (tester) async {
      var serverGranted = false;
      expiresAt = DateTime.now().add(const Duration(days: 1));
      serve = (op, req) async {
        if (op == AppOp.listConsents) {
          return response({
            'items': [healthRow(serverGranted)],
          });
        }
        if (op == AppOp.setConsent) {
          final granted = jsonDecode(req.body)['granted'];
          serverGranted = granted == true;
          return response(healthRow(serverGranted));
        }
        if (op == AppOp.getEntitlements) return response(rights());
        if (op == AppOp.getBaselines) return response(_baselineFixture(210));
        return ordinary(op, req);
      };
      await mount(tester);
      late HealthSync sync;
      sync = HealthSync(
        api,
        scope,
        ConsentGate(api),
        _SyntheticHealthPort(onPrompt: () => sync.inactive()),
      );
      addTearDown(sync.close);

      await completeBusiness(tester, sync.withdraw, expectFailure: false);
      await navigate(tester, '/me');
      await openMemberSummary(tester);
      await pumpUntilCondition(
        tester,
        () => find.text('健康数据授权已关闭。').evaluate().length == 2,
        reason: 'the withdrawn account starts hidden',
      );

      await completeBusiness(tester, sync.enable, expectFailure: false);
      var state = await tester.runAsync(sync.state);
      expect(state!['mode'], 'pending');
      expect(sessions.consentVersion('health'), 1);
      expect(sessions.consentWithdrawals.value, contains('health'));

      sync.resume();
      await completeBusiness(tester, sync.tick, expectFailure: false);

      state = await tester.runAsync(sync.state);
      expect(state!['mode'], 'on');
      expect(sessions.consentVersion('health'), 2);
      expect(sessions.consentWithdrawals.value, isNot(contains('health')));

      // A later foreground tick must not publish the deferred grant again.
      await completeBusiness(tester, sync.tick, expectFailure: false);
      expect(sessions.consentVersion('health'), 2);

      await tapIn(tester, summaryPage, baselineRetry);
      await pumpUntilCondition(
        tester,
        () => find.text('今日 210 / 1800 秒').evaluate().isNotEmpty,
        reason: 'accepted pending regrant must show rows after a fresh read',
      );
      expect(find.text('语音特征授权已关闭。'), findsNWidgets(3));
    },
  );

  testOnPhone(
    'T32B regrant needs a fresh baseline to restore withdrawn voice rows',
    (tester) async {
      var voiceGranted = true;
      var holdBaseline = false;
      final pending = Completer<http.StreamedResponse>();
      addTearDown(() {
        if (!pending.isCompleted) {
          pending.complete(response(_baselineFixture(210)));
        }
      });
      serve = (op, req) async {
        if (op == AppOp.listConsents) {
          return response({
            'items': [
              {'purpose': 'health', 'granted': true},
              {'purpose': 'voice', 'granted': voiceGranted},
            ],
          });
        }
        if (op == AppOp.setConsent) {
          expect(req.url.path, '/v1/me/consents/voice');
          voiceGranted = jsonDecode(req.body)['granted'] as bool;
          return response({'purpose': 'voice', 'granted': voiceGranted});
        }
        if (op == AppOp.getBaselines) {
          if (holdBaseline) {
            holdBaseline = false;
            return pending.future;
          }
          return response(_baselineFixture(210));
        }
        return ordinary(op, req);
      };
      await mount(tester);
      await navigate(tester, '/me');
      await openMemberSummary(tester);
      await reveal(tester, summaryPage, baselineTitle);
      await pumpUntil(tester, heart210);
      expect(find.text('今日 1875 / 1800 秒'), findsOneWidget);

      holdBaseline = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await pumpUntilCondition(
        tester,
        () => calls.where((op) => op == AppOp.getBaselines).length == 2,
        reason: 'the refresh must put a stale aggregate in flight',
      );
      await tester.runAsync(
        () => ApiVoiceAccess(
          api,
        ).setConsent(scope, CollectionPurpose.voice, false),
      );
      await tester.pump();
      // The refresh cleared the displayed progress; no voice row may survive.
      expect(find.text('今日 1875 / 1800 秒'), findsNothing);
      expect(find.text('今日 35 / 1800 秒'), findsNothing);
      await tester.runAsync(
        () => ApiVoiceAccess(
          api,
        ).setConsent(scope, CollectionPurpose.voice, true),
      );
      await tester.pump();

      // The held aggregate was requested before the withdrawal/regrant pair.
      // A newer decision moved the purpose version, so adopting it must not
      // resurrect the old voice readings in the same run.
      pending.complete(response(_baselineFixture(210)));
      await pumpUntilCondition(
        tester,
        () => find.text('语音特征授权已关闭。').evaluate().length == 3,
        reason: 'the pre-withdrawal aggregate must stay fenced after adoption',
      );
      expect(find.text('今日 1875 / 1800 秒'), findsNothing);
      expect(find.text('今日 35 / 1800 秒'), findsNothing);
      expect(heart210, findsOneWidget);

      // Only a read started after the regrant may show the rows again.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await pumpUntilCondition(
        tester,
        () => find.text('今日 1875 / 1800 秒').evaluate().isNotEmpty,
        reason: 'a fresh authorized read must restore voice rows',
      );
      expect(find.text('今日 35 / 1800 秒'), findsOneWidget);
      expect(find.text('语音特征授权已关闭。'), findsNothing);
    },
  );

  testOnPhone(
    'T32B late A consent receipt cannot clear B health baseline',
    (tester) async {
      serve = (op, req) async {
        if (op == AppOp.listConsents) {
          return response({
            'items': [
              {'purpose': 'health', 'granted': true},
              {'purpose': 'voice', 'granted': true},
            ],
          });
        }
        if (op == AppOp.getBaselines) return response(_baselineFixture(210));
        return ordinary(op, req);
      };
      await mount(tester);
      final oldScope = scope;
      AccountScope? next;
      unawaited(
        sessions
            .activate(tokens('synthetic-B', 'access-B'))
            .then((value) => next = value),
      );
      await pumpUntilCondition(
        tester,
        () => next != null,
        reason: 'B must become authoritative before the late receipt',
      );
      expect(sessions.active, same(next));
      await pumpUntil(tester, find.text('暂不测评'));
      await openMeFromPractice(tester);
      await openMemberSummary(tester);
      await pumpUntil(tester, heart210);
      expect(find.text('9 次读数 · 3 个采样日'), findsOneWidget);

      // A withdrawal receipt captured for the retired A session arrives only
      // after B is authoritative. It must not mask B's own grant.
      sessions.noteConsentWithdrawn(oldScope, 'health');
      await tester.pump();

      expect(sessions.active, same(next));
      expect(sessions.consentWithdrawals.value, isNot(contains('health')));
      expect(sessions.consentWithdrawals.value, isNot(contains('voice')));
      expect(heart210, findsOneWidget);
      expect(find.text('9 次读数 · 3 个采样日'), findsOneWidget);
      expect(find.text('健康数据授权已关闭。'), findsNothing);
    },
  );

  for (final expired in [false, true]) {
    testOnPhone(
      'T32B baseline ${expired ? 'expired' : 'free'} entry reads no history',
      (tester) async {
        expiresAt = expired
            ? DateTime.now().subtract(const Duration(days: 1))
            : null;
        await mount(tester);
        await navigate(tester, '/me');
        await openMemberSummary(tester);
        await pumpUntil(tester, find.text('查看会员方案'));
        expect(baselineTitle, findsNothing);
        expect(calls, isNot(contains(AppOp.getBaselines)));
        expect(find.text('我上头了'), findsOneWidget);
      },
    );
  }

  testOnPhone('T32B baseline pending reply stays hidden past expiry', (
    tester,
  ) async {
    final pending = Completer<http.StreamedResponse>();
    var baselineReads = 0;
    serve = (op, req) async {
      if (op == AppOp.listConsents) {
        return response({
          'items': [
            {'purpose': 'health', 'granted': true},
          ],
        });
      }
      if (op == AppOp.getBaselines) {
        baselineReads++;
        return baselineReads == 1
            ? response(_baselineFixture(210))
            : pending.future;
      }
      return ordinary(op, req);
    };
    await mount(tester);
    await navigate(tester, '/me');
    await openMemberSummary(tester);
    await reveal(tester, summaryPage, baselineTitle);
    await pumpUntil(tester, heart210);
    expiresAt = DateTime.now().add(const Duration(seconds: 3));
    await tapIn(tester, summaryPage, baselineRetry);
    await pumpUntilCondition(
      tester,
      () => baselineReads == 2,
      reason: 'a second baseline read must be pending at expiry',
    );
    expect(heart210, findsNothing);
    await tester.runAsync(() async {
      final wait = expiresAt!.difference(DateTime.now());
      await Future<void>.delayed(wait + const Duration(milliseconds: 50));
    });
    await tester.pump(const Duration(seconds: 4));
    await pumpUntil(tester, find.text('会员已到期，会员数据已隐藏。'));
    pending.complete(response(_baselineFixture(420)));
    await drain(tester);
    expect(heart420, findsNothing);
    expect(find.text('我上头了'), findsOneWidget);
  });

  testOnPhone('T32B baseline late reply cannot cross accounts', (tester) async {
    final lateA = Completer<http.StreamedResponse>();
    serve = (op, req) async {
      if (op == AppOp.listConsents) {
        return response({
          'items': [
            {'purpose': 'health', 'granted': true},
          ],
        });
      }
      if (op != AppOp.getBaselines) return ordinary(op, req);
      final bearer = req.headers['Authorization'];
      if (bearer == 'Bearer access') return lateA.future;
      expect(bearer, 'Bearer access-B');
      return response(_baselineFixture(420));
    };
    await mount(tester);
    await openMeFromPractice(tester);
    await openMemberSummary(tester);
    await pumpUntilCondition(
      tester,
      () => calls.contains(AppOp.getBaselines),
      reason: 'A has to reach the current baseline endpoint',
    );
    await tester.runAsync(
      () => sessions.activate(tokens('synthetic-B', 'access-B')),
    );
    await pumpUntil(tester, find.text('暂不测评'));
    await openMeFromPractice(tester);
    await openMemberSummary(tester);
    await reveal(tester, summaryPage, baselineTitle);
    await pumpUntil(tester, heart420);
    lateA.complete(response(_baselineFixture(210)));
    await drain(tester);
    expect(heart210, findsNothing);
    expect(heart420, findsOneWidget);
  });

  testOnPhone('frozen T35 account blocks a direct named emotion route', (
    tester,
  ) async {
    frozen = deadline;
    await mount(tester);
    await navigate(tester, '/emotion');
    await pumpUntil(tester, currentPage<AccountEntryPage>('/emotion'));
    await drain(tester);
    expect(calls, [AppOp.getMe]);
    expect(emotionTitle, findsNothing);
    expect(voiceCalls, isEmpty);
    expect(healthCalls, isEmpty);
  });

  testOnPhone('late 401 after summary route detaches performs zero refreshes', (
    tester,
  ) async {
    final pending = Completer<http.StreamedResponse>();
    serve = (op, req) =>
        op == AppOp.emotionSummary ? pending.future : ordinary(op, req);
    await mount(tester);
    await navigate(tester, '/emotion');
    await pumpUntil(tester, summaryPage);
    await pumpUntilCondition(
      tester,
      () => calls.contains(AppOp.emotionSummary),
      reason: 'summary must be dispatched',
    );
    await goBack(tester);
    pending.complete(response({'code': 'unauthenticated'}, 401));
    await drain(tester);
    expect(calls, isNot(contains(AppOp.refreshTokens)));
    expect(sessions.active, same(scope));
  });

  testOnPhone('terminal current 401 retires the lease via T35 login gate', (
    tester,
  ) async {
    serve = (op, req) async {
      if (op == AppOp.emotionSummary) {
        return response({'code': 'unauthenticated'}, 401);
      }
      if (op == AppOp.refreshTokens) {
        return response(tokens('synthetic-A', 'rotated').toJson());
      }
      return ordinary(op, req);
    };
    await mount(tester);
    await navigate(tester, '/emotion');
    await pumpUntil(tester, find.byType(LoginPage));
    expect(calls.where((op) => op == AppOp.refreshTokens), hasLength(1));
    expect(calls.where((op) => op == AppOp.emotionSummary), hasLength(2));
    expect(sessions.active, isNull);
    expect(sessions.isCurrentUnauthorizedRetirement(scope), isTrue);
  });

  testOnPhone('summary 403 clears old groups and retains manual entry', (
    tester,
  ) async {
    await mount(tester);
    await navigate(tester, '/emotion');
    await pumpUntil(tester, summaryPage);
    await summaryCount(tester, count17);
    serve = (op, req) async => op == AppOp.emotionSummary
        ? response({'code': 'forbidden'}, 403)
        : ordinary(op, req);
    await tapVisible(tester, reload);
    await pumpUntilCondition(
      tester,
      () => calls.where((op) => op == AppOp.emotionSummary).length == 2,
      reason: 'the refresh must reach the summary endpoint',
    );
    await pumpUntil(tester, find.text('会员汇总已隐藏：没有获得所需授权。'));
    expect(count17, findsNothing);
    expect(find.text('我上头了'), findsOneWidget);
  });
  testOnPhone(
    'expired summary returns to the original member page and rechecks quota',
    (tester) async {
      await mount(tester);
      await openMeFromPractice(tester);
      await tapIn(tester, me, '会员与今日额度');
      final unlimited = find.text('对练 · 不限次');
      await pumpUntil(tester, unlimited);
      await pumpUntil(tester, member);
      final originalMember = tester.element(member);
      await tapIn(tester, member, '查看本人情绪汇总');
      await summaryCount(tester, count17);

      expiresAt = null;
      await tapIn(tester, summaryPage, '重新读取汇总');
      await pumpUntil(tester, find.text('查看会员方案'));
      final recheck = Completer<http.StreamedResponse>();
      addTearDown(() {
        if (!recheck.isCompleted) recheck.complete(response(rights()));
      });
      serve = (op, req) async =>
          op == AppOp.getEntitlements ? recheck.future : ordinary(op, req);
      final beforeReturn = calls.length;
      final beforeHealth = List.of(healthCalls);
      await tapVisible(tester, find.text('查看会员方案'));
      await pumpUntil(tester, member);
      expect(tester.element(member), same(originalMember));
      expect(unlimited, findsNothing);
      await pumpUntilCondition(
        tester,
        () => calls.length > beforeReturn,
        reason: 'the member route must request fresh entitlements on return',
      );

      recheck.complete(response({'code': 'unavailable'}, 503));
      await pumpUntil(tester, find.text('服务暂不可用，请重试。'));
      expect(unlimited, findsNothing);
      expect(find.text('对练 · 剩余 3 次'), findsNothing);
      expect(calls.skip(beforeReturn), [AppOp.getEntitlements]);
      expect(healthCalls, beforeHealth);
      expect(voiceCalls, isEmpty);

      serve = ordinary;
      await tapIn(tester, member, '刷新权益');
      await pumpUntil(tester, find.text('对练 · 剩余 3 次'));
      await goBack(tester);
      await pumpUntil(tester, me);
    },
  );

  testOnPhone('same login renews from the official membership tile', (
    tester,
  ) async {
    await mount(tester);
    await openMeFromPractice(tester);
    await openMemberSummary(tester);
    await summaryCount(tester, count17);

    // The formal entry uses the wall clock. Only its Timer is driven by pumps.
    final t1 = DateTime.now().add(const Duration(seconds: 2));
    expiresAt = t1;
    final rotation = await holdRotation(tester);
    expect(count17, findsOneWidget);
    expect(summaryReads(), 2);

    await tester.runAsync(
      () => Future<void>.delayed(
        t1.difference(DateTime.now()) + const Duration(milliseconds: 20),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    await pumpUntil(tester, find.text('会员已到期，会员数据已隐藏。'));
    expect(count17, findsNothing);
    expect(count29, findsNothing);
    expect(find.text('我上头了'), findsOneWidget);

    rotation.complete(response(renewedA().toJson()));
    await drain(tester);
    expect(summaryReads(), 2, reason: 'the expired request cannot replay');
    expect(count17, findsNothing);
    expect(count29, findsNothing);
    expect(sessions.active, same(scope));
    final rotatedBeforeReentry = sessions.require(scope).access == 'renewed-A';

    await tapVisible(tester, find.text('查看会员方案'));
    await pumpUntil(tester, member);
    expiresAt = t1.add(const Duration(hours: 1));
    final beforeReentry = requests.length;
    await tapIn(tester, member, '查看本人情绪汇总');
    await pumpUntilCondition(
      tester,
      () =>
          count29.evaluate().isNotEmpty ||
          find.byType(LoginPage).evaluate().isNotEmpty,
      reason: 'renewed summary or unexpected login gate',
    );
    final refreshes = calls.where((op) => op == AppOp.refreshTokens).length;
    debugPrint(
      'renewal rotated_before_reentry=$rotatedBeforeReentry '
      'refreshes=$refreshes old_summary_replayed=false '
      'login_gate=${find.byType(LoginPage).evaluate().isNotEmpty}',
    );
    await summaryCount(tester, count29);
    expect(sessions.active, same(scope));
    expect(find.byType(LoginPage), findsNothing);
    expect(count17, findsNothing);
    expect(refreshes, 1);
    await pumpUntilCondition(
      tester,
      () => requests
          .skip(beforeReentry)
          .any((request) => request.$1 == AppOp.listConsents),
      reason: 'the renewed round also re-checks collection consent',
    );
    expect(requests.skip(beforeReentry), [
      (AppOp.getEntitlements, 'Bearer renewed-A'),
      (AppOp.emotionSummary, 'Bearer renewed-A'),
      (AppOp.listConsents, 'Bearer renewed-A'),
    ]);
    expect(voiceCalls, isEmpty);
    expect(healthCalls, ['source']);
    expect(calls, isNot(contains(AppOp.setConsent)));

    final restored = Sessions(secret, cache);
    await tester.runAsync(restored.restore);
    expect(restored.require(restored.active!).refresh, 'renewed-refresh');
    expect(tester.takeException(), isNull);
  });

  testOnPhone('late successful rotation cannot restore a real local logout', (
    tester,
  ) async {
    await mount(tester);
    await navigate(tester, '/me');
    await openMemberSummary(tester);
    await summaryCount(tester, count17);
    final rotation = await holdRotation(tester);

    await goBack(tester);
    await goBack(tester);
    await tapIn(tester, me, '退出账号');
    await tapVisible(tester, find.text('确认退出'));
    await pumpUntil(tester, find.byType(LoginPage));
    await pumpUntil(tester, find.text('退出结果'));
    expect(calls.where((op) => op == AppOp.logout), hasLength(1));

    rotation.complete(response(renewedA().toJson()));
    await drain(tester);
    expect(sessions.active, isNull);
    expect(find.byType(LoginPage), findsOneWidget);
    expect(count17, findsNothing);
    expect(summaryReads(), 2);
    final restored = Sessions(secret, cache);
    await tester.runAsync(restored.restore);
    expect(restored.active, isNull);
  });

  for (final accountId in ['synthetic-A', 'synthetic-B']) {
    testOnPhone(
      'late successful rotation cannot overwrite a new $accountId login',
      (tester) async {
        await mount(tester);
        await navigate(tester, '/me');
        await openMemberSummary(tester);
        await summaryCount(tester, count17);
        final rotation = await holdRotation(tester);
        final next = (await tester.runAsync(
          () => sessions.activate(
            newCredentials(accountId, 'next-login', 'next-refresh'),
          ),
        ))!;
        expect(next, isNot(same(scope)));
        await pumpUntil(tester, find.text('暂不测评'));
        await navigate(tester, '/me');
        await openMemberSummary(tester);
        final count41 = find.text('手动记录 41 次');
        await summaryCount(tester, count41);
        final beforeRelease = requests.length;

        rotation.complete(response(renewedA().toJson()));
        await drain(tester);
        expect(requests, hasLength(beforeRelease));
        expect(sessions.active, same(next));
        expect(sessions.require(next).refresh, 'next-refresh');
        expect(
          requests.where((request) => request.$1 == AppOp.emotionSummary),
          [
            (AppOp.emotionSummary, 'Bearer access'),
            (AppOp.emotionSummary, 'Bearer access'),
            (AppOp.emotionSummary, 'Bearer next-login'),
          ],
        );
        expect(count17, findsNothing);
        expect(count41, findsOneWidget);
        expect(find.byType(LoginPage), findsNothing);

        final restored = Sessions(secret, cache);
        await tester.runAsync(restored.restore);
        expect(restored.active!.account, accountId);
        expect(restored.require(restored.active!).refresh, 'next-refresh');
      },
    );
  }

  testOnPhone(
    'switch account through practice and open the official membership tile',
    (tester) async {
      await mount(tester);
      await openMeFromPractice(tester);
      await openMemberSummary(tester);
      await summaryCount(tester, count17);
      await goBack(tester);
      await goBack(tester);
      await tapVisible(
        tester,
        find.widgetWithText(NavigationDestination, '练习'),
      );
      await pumpUntil(tester, currentPage<HomeShell>('/practice'));
      await tapVisible(
        tester,
        find.widgetWithText(NavigationDestination, '我的'),
      );
      await openMemberSummary(tester);
      await summaryCount(tester, count17);
      expect(tester.takeException(), isNull);

      await tester.runAsync(
        () => sessions.activate(
          newCredentials('synthetic-B', 'next-login', 'next-refresh'),
        ),
      );
      await pumpUntil(tester, find.text('暂不测评'));
      await openMeFromPractice(tester);
      serve = (op, req) async {
        if (op == AppOp.emotionSummary) {
          expect(req.headers['Authorization'], 'Bearer next-login');
          return response({
            'groups': [_group(_privateContactB, 41)],
          });
        }
        return ordinary(op, req);
      };
      await openMemberSummary(tester);
      await summaryCount(tester, find.text('手动记录 41 次'));
      expect(find.text('手动记录 41 次'), findsOneWidget);
      expect(count17, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  test('T32B release switches default to false', () {
    expect(t32bHealthReplayApproved, isFalse);
    expect(t32bVoiceReplayApproved, isFalse);
    expect(t32bLiveFramesApproved, isFalse);
  });

  testOnPhone('pending summary cannot retain counts past shortened expiry', (
    tester,
  ) async {
    await mount(tester);
    await navigate(tester, '/emotion');
    await summaryCount(tester, count17);
    final pending = Completer<http.StreamedResponse>();
    expiresAt = DateTime.now().add(const Duration(seconds: 4));
    serve = (op, req) =>
        op == AppOp.emotionSummary ? pending.future : ordinary(op, req);
    await tapVisible(tester, reload);
    await pumpUntilCondition(
      tester,
      () => calls.where((op) => op == AppOp.emotionSummary).length == 2,
      reason: 'shortened entitlement must permit only the in-flight refresh',
    );
    expect(count17, findsOneWidget);
    await tester.runAsync(() async {
      final untilExpiry = expiresAt!.difference(DateTime.now());
      await Future<void>.delayed(
        untilExpiry + const Duration(milliseconds: 50),
      );
    });
    await tester.pump(const Duration(seconds: 5));
    await pumpUntil(tester, find.text('会员已到期，会员数据已隐藏。'));
    expect(count17, findsNothing);
    pending.complete(
      response({
        'groups': [_group(_privateContactA, 99)],
      }),
    );
    await drain(tester);
    expect(find.text('手动记录 99 次'), findsNothing);
    expect(find.text('我上头了'), findsOneWidget);
  });

  testOnPhone(
    'background summary refresh 401 cannot retire the current lease',
    (tester) async {
      final refresh = Completer<http.StreamedResponse>();
      serve = (op, req) async {
        if (op == AppOp.emotionSummary) {
          return response({'code': 'unauthenticated'}, 401);
        }
        if (op == AppOp.refreshTokens) return refresh.future;
        return ordinary(op, req);
      };
      await mount(tester);
      await navigate(tester, '/emotion');
      await pumpUntilCondition(
        tester,
        () => calls.contains(AppOp.refreshTokens),
        reason: 'the current summary must initiate token refresh',
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      refresh.complete(response({'code': 'unauthenticated'}, 401));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await drain(tester);
      expect(sessions.require(scope).access, 'access');
      expect(calls.where((op) => op == AppOp.emotionSummary), hasLength(1));

      serve = ordinary;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await summaryCount(tester, count17);
      expect(summaryRequest.headers['Authorization'], 'Bearer access');
    },
  );

  testOnPhone('late A summary is fenced after B replaces the navigator', (
    tester,
  ) async {
    final lateA = Completer<http.StreamedResponse>();
    serve = (op, req) async {
      if (op != AppOp.emotionSummary) return ordinary(op, req);
      if (req.headers['Authorization'] == 'Bearer access') return lateA.future;
      expect(req.headers['Authorization'], 'Bearer access-B');
      return response({
        'groups': [_group(_privateContactB, 29)],
      });
    };
    await mount(tester);
    await navigate(tester, '/emotion');
    await pumpUntilCondition(
      tester,
      () => calls.contains(AppOp.emotionSummary),
      reason: 'A must have a summary in flight',
    );
    AccountScope? newScope;
    unawaited(
      sessions.activate(tokens('synthetic-B', 'access-B')).then((value) {
        newScope = value;
      }),
    );
    await pumpUntilCondition(
      tester,
      () => newScope != null,
      reason: 'B activation must finish retiring A and committing B',
    );
    await pumpUntilCondition(
      tester,
      () => emotionTitle.evaluate().isEmpty,
      reason: 'account replacement must reset named routes',
    );
    await navigate(tester, '/emotion');
    await summaryCount(tester, find.text('手动记录 29 次'));
    lateA.complete(
      response({
        'groups': [_group(_privateContactA, 99)],
      }),
    );
    await drain(tester);
    expect(find.text('手动记录 29 次'), findsOneWidget);
    expect(find.text('手动记录 99 次'), findsNothing);
    expect(sessions.active, same(newScope));
    expect(calls, isNot(contains(AppOp.refreshTokens)));
  });
}
