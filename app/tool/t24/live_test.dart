import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/endpoints.g.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/contacts/models.dart' show newRequestId;
import 'package:high_eq/features/contacts/scene.dart';
import 'package:high_eq/features/reviews/model.dart';
import 'package:high_eq/features/reviews/repository.dart';
import 'package:http/http.dart' as http;

import '../../test/isolation_test.dart' show MemorySecret;

void main() {
  test(
    'real T24 client ↔ T23 HTTP: consent, replay, history, revocation and recovery',
    () async {
      final environment = Platform.environment;
      final rawOrigin = environment['T24_ORIGIN'];
      final fixtureToken = environment['T24_FIXTURE_TOKEN'];
      final devTicket = environment['T24_DEV_TICKET'];
      expect(rawOrigin, isNotNull, reason: 'T24_ORIGIN is required');
      expect(fixtureToken, isNotNull, reason: 'T24_FIXTURE_TOKEN is required');
      expect(devTicket, isNotNull, reason: 'T24_DEV_TICKET is required');
      final origin = Uri.parse(rawOrigin!);
      expect(origin.scheme, 'http');
      expect(origin.host, '127.0.0.1');

      final control = http.Client();
      addTearDown(control.close);
      Future<Json> fixture(String method, String path, [Json? body]) async {
        final request = http.Request(method, origin.resolve(path));
        request.headers['X-T24-Fixture-Token'] = fixtureToken!;
        if (body != null) {
          request.headers['Content-Type'] = 'application/json';
          request.bodyBytes = utf8.encode(jsonEncode(body));
        }
        final response = await control.send(request);
        final raw = await response.stream.bytesToString();
        expect(
          response.statusCode,
          200,
          reason: 'fixture $method $path returned ${response.statusCode}: $raw',
        );
        final value = jsonDecode(raw);
        if (value is! Json) {
          throw TestFailure('fixture $method $path returned non-object JSON');
        }
        return value;
      }

      Future<void> mode(int value) async {
        await fixture('PUT', '/__t24/mode', {'mode': value});
      }

      int counter(Json state, String name) {
        final value = state[name];
        if (value is! int) throw TestFailure('fixture state.$name is not int');
        return value;
      }

      final tmp = await Directory.systemTemp.createTemp('t24-live');
      addTearDown(() => tmp.delete(recursive: true));
      final sessions = Sessions(MemorySecret(), tmp);
      final transport = HttpTransport(http.Client());
      addTearDown(transport.close);
      final api = AppApi(origin, transport, sessions);
      final wire = MobileEndpoints(api);
      final scope = await sessions.activate(
        Tokens.fromJson(
          await wire.login(
            body: {
              'credential': {'provider': 'apple', 'proof': devTicket!},
              'age_confirmed': true,
              'terms_version': '2026-11',
              'privacy_version': '2026-11',
            },
          ),
        ),
      );
      final reviews = ApiReviews(api, scope);

      Future<int> remaining() async {
        final rights = await wire.getEntitlements(scope: scope);
        final allowances = rights['allowances'];
        if (allowances is! List) throw TestFailure('allowances is not a list');
        final row = allowances.whereType<Json>().singleWhere(
          (value) => value['feature'] == 'review',
        );
        final value = row['remaining'];
        if (value is! int) throw TestFailure('review remaining is not int');
        return value;
      }

      ReviewDraft draft(String requestId) => ReviewDraft(
        requestId: requestId,
        happened: '合成联验：我在会上打断同事后继续汇报。',
        myFeeling: '着急，也有点担心被否定。',
        theirFeeling: '可能还没说完，感到被打断。',
        myAction: '我先说完',
        nextAction: '先停下来问对方是否还需要补充。',
        scene: Scene.work,
        occurredAt: DateTime.utc(2026, 11, 22, 2),
      );

      expect(await reviews.allowed(), isFalse);
      final beforeConsentRemaining = await remaining();
      final firstDraft = draft(newRequestId());
      await expectLater(
        reviews.submit(firstDraft),
        throwsA(
          isA<ApiFailure>()
              .having((error) => error.status, 'status', 403)
              .having((error) => error.code, 'code', 'forbidden'),
        ),
      );
      var state = await fixture('GET', '/__t24/state');
      expect(counter(state, 'analyses'), 0);
      expect(counter(state, 'scores'), 0);
      expect(await remaining(), beforeConsentRemaining);

      await reviews.grant();
      expect(await reviews.allowed(), isTrue);
      final initialRemaining = await remaining();
      expect(initialRemaining, beforeConsentRemaining);
      final firstAttempt = await reviews.submit(firstDraft);
      expect(firstAttempt, isA<ReviewReady>());
      final first = (firstAttempt as ReviewReady).record;
      expect(first.submitted.requestId, firstDraft.requestId);
      expect(first.submitted.myAction, '我先说完');
      expect(first.score.total, 20);
      expect(first.score.observation.reason, contains('我先说完'));
      expect(first.repairPhrase, '刚才我打断了你，你愿意说完吗？');
      expect(first.id, isNot(first.score.scoreId));
      expect(await remaining(), initialRemaining - 1);

      final replay = await reviews.submit(firstDraft);
      expect(replay, isA<ReviewReady>());
      expect((replay as ReviewReady).record.id, first.id);
      expect(replay.record.score.scoreId, first.score.scoreId);
      expect(await remaining(), initialRemaining - 1);
      state = await fixture('GET', '/__t24/state');
      expect(counter(state, 'analyses'), 1);
      expect(counter(state, 'scores'), 1);

      var history = await reviews.history(limit: 20, scene: Scene.work);
      expect(history.items, hasLength(1));
      expect(history.items.single.id, first.id);
      expect(history.items.single.repairPhrase, first.repairPhrase);

      await wire.setConsent(
        scope: scope,
        purpose: 'review',
        body: {'version': 'v1', 'granted': false},
      );
      expect(await reviews.allowed(), isFalse);
      final revokedDraft = draft(newRequestId());
      await expectLater(
        reviews.submit(revokedDraft),
        throwsA(
          isA<ApiFailure>()
              .having((error) => error.status, 'status', 403)
              .having((error) => error.code, 'code', 'forbidden'),
        ),
      );
      expect(await remaining(), initialRemaining - 1);
      state = await fixture('GET', '/__t24/state');
      expect(counter(state, 'analyses'), 1);
      expect(counter(state, 'scores'), 1);

      await reviews.grant();
      expect(await reviews.allowed(), isTrue);
      await mode(2);
      final outageDraft = draft(newRequestId());
      await expectLater(
        reviews.submit(outageDraft),
        throwsA(
          isA<ApiFailure>()
              .having((error) => error.status, 'status', 503)
              .having((error) => error.code, 'code', 'moderation_unavailable')
              .having((error) => error.retryable, 'retryable', true)
              .having(
                (error) => error.message,
                'message without a charge promise',
                allOf(isNot(contains('未扣次')), isNot(contains('已扣次'))),
              ),
        ),
      );
      expect(await remaining(), initialRemaining - 1);
      state = await fixture('GET', '/__t24/state');
      expect(counter(state, 'analyses'), 2);
      expect(counter(state, 'scores'), 1);

      await mode(0);
      final recoveredAttempt = await reviews.submit(outageDraft);
      expect(recoveredAttempt, isA<ReviewReady>());
      final recovered = (recoveredAttempt as ReviewReady).record;
      expect(recovered.submitted.requestId, outageDraft.requestId);
      expect(await remaining(), initialRemaining - 2);
      state = await fixture('GET', '/__t24/state');
      expect(counter(state, 'analyses'), 2);
      expect(counter(state, 'scores'), 2);

      history = await reviews.history(limit: 20, scene: Scene.work);
      expect(history.items, hasLength(2));
      expect(
        history.items.map((record) => record.id),
        unorderedEquals([first.id, recovered.id]),
      );
    },
  );
}
