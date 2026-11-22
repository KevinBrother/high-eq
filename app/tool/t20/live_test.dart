import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/endpoints.g.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/contacts/models.dart' show newRequestId;
import 'package:high_eq/features/contacts/scene.dart';
import 'package:high_eq/features/practice/conversation.dart';
import 'package:high_eq/features/practice/repository.dart';
import 'package:http/http.dart' as http;

import '../../test/isolation_test.dart' show MemorySecret;

void main() {
  test(
    'real T20 client ↔ T19 HTTP/SSE: consent, recovery, capped and failures',
    () async {
      final origin = Uri.parse(Platform.environment['T20_ORIGIN']!);
      expect(origin.scheme, 'http');
      expect(origin.host, '127.0.0.1');
      final tmp = await Directory.systemTemp.createTemp('t20');
      addTearDown(() => tmp.delete(recursive: true));
      final sessions = Sessions(MemorySecret(), tmp);
      final transport = HttpTransport(http.Client());
      addTearDown(transport.close);
      final api = AppApi(origin, transport, sessions),
          wire = MobileEndpoints(api);
      Future<AccountScope> login(String ticket) async => sessions.activate(
        Tokens.fromJson(
          await wire.login(
            body: {
              'credential': {'provider': 'apple', 'proof': ticket},
              'age_confirmed': true,
              'terms_version': '2026-11',
              'privacy_version': '2026-11',
            },
          ),
        ),
      );
      final scope = await login(Platform.environment['T20_DEV_TICKET']!);
      var repo = ApiPractice(api, scope);
      final controlClient = http.Client();
      addTearDown(controlClient.close);

      Future<void> control(String action, [String? sessionId]) async {
        final query = <String, String>{'action': action};
        if (sessionId case final id?) query['session_id'] = id;
        final uri = origin.replace(
          path: '/_t20/control',
          queryParameters: query,
        );
        final response = await controlClient.post(uri);
        expect(response.statusCode, 200, reason: response.body);
      }

      Future<Json> createPreset() async {
        final levels = await repo.levels(Scene.work, 1);
        expect(levels, isNotEmpty);
        return repo.create({
          'request_id': newRequestId(),
          'level_id': levels.first['id'],
        });
      }

      Future<Json> createCustom() => repo.create({
        'request_id': newRequestId(),
        'scene': 'work',
        'scenario': '合成预演：对齐一次项目交付时间。',
      });

      Future<Json> waitForReply(String id) async {
        final deadline = DateTime.now().add(const Duration(seconds: 12));
        while (DateTime.now().isBefore(deadline)) {
          final session = await repo.get(id);
          if ((session['messages'] as List).length >= 2 &&
              (session['messages'] as List).last['role'] == 'assistant') {
            return session;
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        fail('saved assistant reply did not appear');
      }

      expect(await repo.practiceConsent(), isFalse);
      await expectLater(
        createCustom(),
        throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 403)),
      );
      await repo.grantPracticeConsent();
      expect(await repo.practiceConsent(), isTrue);

      final preset = await createPreset();
      expect(preset['session_id'], isNotEmpty);
      expect(preset['mode'], 'single_skill');
      final custom = await createCustom();
      expect(custom['session_id'], isNotEmpty);
      expect(custom['mode'], 'full_session');

      final normal = Conversation(repo, preset);
      addTearDown(normal.dispose);
      await normal.recover();
      await normal.send('合成甲。合成乙。');
      expect(normal.status, 'active');
      expect(normal.hasSavedReply, isTrue);
      expect(normal.rows.last['text'], '合成甲。合成乙。');
      final normalHistory = await repo.get(preset['session_id']);
      expect(normalHistory['messages'], hasLength(2));
      expect((normalHistory['settlement'] as Json)['status'], 'charged');

      await control('hold');
      final interrupted = Conversation(repo, custom);
      await interrupted.recover();
      final cancelled = interrupted.send('合成中断与恢复');
      while (interrupted.fragment != '合成甲。') {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      interrupted.dispose();
      // Release before waiting for the cancelled request: the provider must have
      // a chance to persist the reply even though the client has detached.
      await control('release');
      await cancelled;
      final recoveredHistory = await waitForReply(custom['session_id']);
      expect(recoveredHistory['status'], 'active');
      final recovered = Conversation(repo, recoveredHistory);
      addTearDown(recovered.dispose);
      await recovered.recover();
      expect(recovered.command, isNull);
      expect(recovered.hasSavedReply, isTrue);
      expect(recovered.rows.last['text'], '合成甲。合成乙。');
      await recovered.finish();
      expect(recovered.status, 'complete');
      expect(recovered.snapshot['result'], isA<Json>());

      // Model requests are untouched: this is a new client recovering a completed
      // custom launch via the detail endpoint, not via local text or list history.
      final fresh = ApiPractice(api, scope);
      final firstId = custom['session_id'] as String;
      final setup = (await fresh.get(firstId))['setup'] as Json;
      expect(setup['scenario'], '合成预演：对齐一次项目交付时间。');
      expect(custom.containsKey('setup'), isFalse);
      expect(
        (await fresh.history()).every((item) => !item.containsKey('setup')),
        isTrue,
      );
      final repeated = await fresh.create({
        ...setup,
        'request_id': newRequestId(),
        'previous_id': firstId,
      });
      expect(repeated.containsKey('setup'), isFalse);
      final second = await fresh.get(repeated['session_id'] as String);
      expect(second['setup']['previous_id'], firstId);
      expect(second['setup']['scenario'], setup['scenario']);

      final capped = await createPreset();
      final cappedConversation = Conversation(repo, capped);
      addTearDown(cappedConversation.dispose);
      await cappedConversation.recover();
      await cappedConversation.send('合成封顶前发言');
      final cappedId = capped['session_id'] as String;
      await control('cap', cappedId);
      await cappedConversation.send('合成封顶后发言');
      expect(cappedConversation.status, 'capped');
      expect(cappedConversation.canSend, isFalse);
      expect(cappedConversation.canScore, isTrue);
      await cappedConversation.finish();
      expect(cappedConversation.status, 'complete');
      expect(cappedConversation.snapshot['result'], isA<Json>());

      final empty = await createPreset();
      final emptyId = empty['session_id'] as String;
      final emptyConversation = Conversation(repo, empty);
      addTearDown(emptyConversation.dispose);
      await emptyConversation.recover();
      await control('cap', emptyId);
      await emptyConversation.send('合成无历史封顶发言');
      expect(emptyConversation.status, 'capped');
      expect(emptyConversation.rows, isEmpty);
      expect(emptyConversation.canScore, isFalse);
      await emptyConversation.finish();
      await expectLater(
        repo.finish(emptyId),
        throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 409)),
      );

      // Three completed first replies have spent account A's real free allowance.
      // Don't let a quota rejection make a crisis/outage test pass or fail by accident.
      final entitlements = await wire.getEntitlements(scope: scope);
      expect(entitlements['tier'], 'free');
      final allowance = (entitlements['allowances'] as List)
          .cast<Json>()
          .singleWhere((v) => v['feature'] == 'practice');
      expect(allowance['remaining'], 0);
      final terminalScope = await login(
        Platform.environment['T20_TERMINAL_TICKET']!,
      );
      expect(terminalScope.account, isNot(scope.account));
      repo = ApiPractice(api, terminalScope);
      expect(await repo.practiceConsent(), isFalse);
      await repo.grantPracticeConsent();
      Future<Conversation> scoredSession() async {
        await control('normal');
        // The shared T19 vendor injects moderation faults during full-score review.
        final session = await createCustom();
        expect(session['mode'], 'full_session');
        final conversation = Conversation(repo, session);
        await conversation.recover();
        await conversation.send('合成评分阶段内容');
        expect(conversation.status, 'active');
        expect(conversation.hasSavedReply, isTrue);
        return conversation;
      }

      final safety = await scoredSession();
      addTearDown(safety.dispose);
      await control('safety');
      await safety.finish();
      expect(safety.status, 'safety');
      expect(safety.canScore, isFalse);
      expect(safety.canRetry, isFalse);

      final outage = await scoredSession();
      addTearDown(outage.dispose);
      await control('outage');
      await outage.finish();
      expect(outage.status, 'moderation_unavailable');
      expect(outage.canScore, isFalse);
      expect(outage.canRetry, isTrue);
      expect(outage.command?['kind'], 'finish');
      await control('normal');
      await outage.retry();
      expect(outage.status, 'complete');
      expect(outage.snapshot['result'], isA<Json>());
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
