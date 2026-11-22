import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/endpoints.g.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/growth/models.dart';
import 'package:high_eq/features/growth/repository.dart';
import 'package:high_eq/features/onboarding/repository.dart';
import 'package:http/http.dart' as http;

import '../../test/isolation_test.dart' show MemorySecret;

void main() {
  final ticket = Platform.environment['T27_DEV_TICKET'];
  test(
    'real T27 app ↔ T26 HTTP: assessment, first plan, completion and reopen',
    () async {
      final rawOrigin = Platform.environment['T27_ORIGIN'];
      expect(rawOrigin, isNotNull, reason: 'T27_ORIGIN is required');
      final origin = Uri.parse(rawOrigin!);
      expect(origin.scheme, 'http');
      expect(origin.host, '127.0.0.1');
      expect(origin.userInfo, isEmpty);

      final directory = await Directory.systemTemp.createTemp('t27-live-');
      addTearDown(() => directory.delete(recursive: true));
      final secret = MemorySecret();
      final sessions = Sessions(secret, directory);
      final transport = HttpTransport(http.Client());
      addTearDown(transport.close);
      final app = AppApi(origin, transport, sessions);
      final wire = MobileEndpoints(app);
      final scope = await sessions.activate(
        Tokens.fromJson(
          await wire.login(
            body: {
              'credential': {'provider': 'apple', 'proof': ticket},
              'age_confirmed': true,
              'privacy_version': policyVersion,
              'terms_version': policyVersion,
            },
          ),
        ),
      );

      final assessmentBook = AssessmentBook(app, scope);
      expect(await assessmentBook.latest(), isNull);
      expect(await assessmentBook.allowed(), isFalse);
      await assessmentBook.grant();
      expect(await assessmentBook.allowed(), isTrue);

      final instrument = await assessmentBook.instrument();
      final answers = [
        for (final value in [1, 3, 5, 7]) ...List.filled(4, value),
      ];
      final assessment = await assessmentBook.submit(
        instrument['version'] as String,
        answers,
      );
      final assessmentId = assessment['id'];
      expect(assessmentId, isA<String>());

      final repository = ApiGrowthRepository(app, scope);
      final first = await repository.load();
      expect(first.plan.items, isNotEmpty);
      expect(first.plan.completed, 0);
      expect(first.latestAssessment?.id, assessmentId);
      expect(first.growth.latestAssessment, assessmentId);
      expect(first.growth.wleisPercent, isNotNull);
      expect(first.growth.validBehaviorCount, 0);
      expect(first.growth.trainingReference, isNull);

      final cards = first.plan.items
          .where((item) => item.kind == PlanKind.card)
          .toList();
      final exercises = first.plan.items
          .where((item) => item.kind == PlanKind.exercise)
          .toList();
      expect(cards.isNotEmpty || exercises.isNotEmpty, isTrue);
      // Exercise 0 is a valid choice, but omitted/null must never be interpreted as 0.
      expect(exercises, isNotEmpty);
      for (final invalid in <Json>[
        {},
        {'choice_index': null},
      ]) {
        await expectLater(
          wire.answerExercise(
            scope: scope,
            id: exercises.first.contentId,
            body: invalid,
          ),
          throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 400)),
        );
      }
      final answered = await repository.answer(exercises.first.contentId, 0);
      expect(answered.explanation, isNotEmpty);
      final target = cards.isNotEmpty ? cards.first : exercises.first;
      if (target.kind == PlanKind.card) {
        final card = await repository.card(target.contentId);
        expect(card.id, target.contentId);
        expect(card.body, isNotEmpty);
      } else {
        final exercise = await repository.exercise(target.contentId);
        expect(exercise.id, target.contentId);
        expect(exercise.choices.length, greaterThanOrEqualTo(2));
        final answer = await repository.answer(target.contentId, 0);
        expect(answer.explanation, isNotEmpty);
      }

      final completion = await repository.complete(target.id);
      expect(completion.streak, greaterThanOrEqualTo(1));

      final saved = await repository.load();
      expect(saved.plan.day, first.plan.day);
      expect(saved.plan.completed, 1);
      expect(
        saved.plan.items.singleWhere((item) => item.id == target.id).completed,
        isTrue,
      );
      expect(saved.latestAssessment?.id, assessmentId);
      expect(saved.growth.latestAssessment, assessmentId);
      expect(saved.growth.streak, completion.streak);
      expect(saved.growth.achievements, completion.achievements);
      expect(saved.growth.validBehaviorCount, 0);
      expect(saved.growth.trainingReference, isNull);

      // A fresh Sessions restore and API client model process restart. The
      // assertions below therefore read the completion from T26, not memory.
      final reopenedSessions = Sessions(secret, directory);
      await reopenedSessions.restore();
      final reopenedScope = reopenedSessions.active;
      expect(reopenedScope, isNotNull);
      final reopenedTransport = HttpTransport(http.Client());
      addTearDown(reopenedTransport.close);
      final reopenedApp = AppApi(origin, reopenedTransport, reopenedSessions);
      final reopened = await ApiGrowthRepository(
        reopenedApp,
        reopenedScope!,
      ).load();

      expect(reopened.plan.toJson(), saved.plan.toJson());
      expect(reopened.growth.toJson(), saved.growth.toJson());
      expect(
        reopened.assessments.map((item) => item.toJson()).toList(),
        saved.assessments.map((item) => item.toJson()).toList(),
      );
      expect(reopened.growth.latestAssessment, assessmentId);
      expect(reopened.growth.streak, completion.streak);
      expect(
        reopened.plan.items
            .singleWhere((item) => item.id == target.id)
            .completed,
        isTrue,
      );
    },
    skip: ticket == null
        ? 'Run app/tool/t27/live.sh with Docker and Flutter'
        : false,
  );
}
