import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/voice/access.dart';
import 'package:high_eq/features/voice/features.dart';
import 'package:http/http.dart' as http;

class _MemorySecret implements SecretStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> replace(String? next) async => value = next;
}

class _Handler implements Transport {
  late Future<http.StreamedResponse> Function(AppOp, http.Request) handle;

  @override
  Future<http.StreamedResponse> send(AppOp op, http.Request request) =>
      handle(op, request);

  @override
  void close() {}
}

http.StreamedResponse _response(Map<String, dynamic> body, [int code = 200]) =>
    http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(body))),
      code,
      headers: {'content-type': 'application/json'},
    );

void main() {
  late Directory directory;
  late Sessions sessions;
  late AccountScope scope;
  late _Handler handler;
  late ApiVoiceUploader uploader;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('t29-upload-retry');
    sessions = Sessions(_MemorySecret(), directory);
    final now = DateTime.now().toUtc();
    scope = await sessions.activate(
      Tokens('A', 'access-A', 'refresh-A', now.add(const Duration(hours: 1))),
    );
    handler = _Handler();
    uploader = ApiVoiceUploader(
      AppApi(Uri.https('test.invalid'), handler, sessions),
    );
  });

  tearDown(() => directory.delete(recursive: true));

  test(
    'voice upload never sends after the account is cleared during beforeSend',
    () async {
      var uploadCalls = 0;
      handler.handle = (op, request) async {
        if (op == AppOp.uploadWindow) uploadCalls++;
        fail('unexpected operation: ${op.name}');
      };
      final entered = Completer<void>();
      final release = Completer<void>();

      final sending = uploader.upload(
        scope,
        VoiceWindow(
          startsAt: DateTime.utc(2026, 11, 21, 9),
          analysis: const VoiceAnalysis(voicedSeconds: 0),
        ),
        beforeSend: () async {
          entered.complete();
          await release.future;
        },
      );
      await entered.future;
      await sessions.clear();
      release.complete();

      await expectLater(sending, throwsA(isA<SessionChanged>()));
      expect(uploadCalls, 0);
    },
  );

  test(
    'voice upload rechecks revocation after a 401 refresh before resending',
    () async {
      var beforeSendCalls = 0;
      var uploadCalls = 0;
      var refreshCalls = 0;
      handler.handle = (op, request) async {
        if (op == AppOp.refreshTokens) {
          refreshCalls++;
          return _response(
            Tokens(
              'A',
              'new-access',
              'new-refresh',
              DateTime.now().toUtc().add(const Duration(hours: 1)),
            ).toJson(),
          );
        }
        if (op == AppOp.uploadWindow) {
          uploadCalls++;
          expect(request.headers['Authorization'], 'Bearer access-A');
          return _response({'code': 'unauthenticated'}, 401);
        }
        fail('unexpected operation: ${op.name}');
      };

      await expectLater(
        uploader.upload(
          scope,
          VoiceWindow(
            startsAt: DateTime.utc(2026, 11, 21, 9),
            analysis: const VoiceAnalysis(voicedSeconds: 0),
          ),
          beforeSend: () async {
            beforeSendCalls++;
            if (beforeSendCalls == 2) {
              throw StateError('voice revoked during token refresh');
            }
          },
        ),
        throwsA(isA<StateError>()),
      );

      expect(beforeSendCalls, 2);
      expect(uploadCalls, 1);
      expect(refreshCalls, 1);
      expect(sessions.require(scope).access, 'new-access');
    },
  );

  test('guarded upload clears the account when 401 refresh fails', () async {
    var beforeSendCalls = 0;
    var uploadCalls = 0;
    var refreshCalls = 0;
    handler.handle = (op, request) async {
      if (op == AppOp.refreshTokens) {
        refreshCalls++;
        return _response({
          'code': 'unavailable',
          'message': 'refresh unavailable',
          'retryable': true,
        }, 503);
      }
      if (op == AppOp.uploadWindow) {
        uploadCalls++;
        return _response({'code': 'unauthenticated'}, 401);
      }
      fail('unexpected operation: ${op.name}');
    };

    await expectLater(
      uploader.upload(
        scope,
        VoiceWindow(
          startsAt: DateTime.utc(2026, 11, 21, 9),
          analysis: const VoiceAnalysis(voicedSeconds: 0),
        ),
        beforeSend: () async => beforeSendCalls++,
      ),
      throwsA(
        isA<ApiFailure>()
            .having((e) => e.status, 'status', 401)
            .having((e) => e.code, 'code', 'unauthenticated'),
      ),
    );

    expect(beforeSendCalls, 1);
    expect(uploadCalls, 1);
    expect(refreshCalls, 1);
    expect(sessions.active, isNull);
  });

  test(
    'guarded upload clears the account when the replay is unauthorized',
    () async {
      var beforeSendCalls = 0;
      var uploadCalls = 0;
      var refreshCalls = 0;
      handler.handle = (op, request) async {
        if (op == AppOp.refreshTokens) {
          refreshCalls++;
          return _response(
            Tokens(
              'A',
              'new-access',
              'new-refresh',
              DateTime.now().toUtc().add(const Duration(hours: 1)),
            ).toJson(),
          );
        }
        if (op == AppOp.uploadWindow) {
          uploadCalls++;
          return _response({'code': 'unauthenticated'}, 401);
        }
        fail('unexpected operation: ${op.name}');
      };

      await expectLater(
        uploader.upload(
          scope,
          VoiceWindow(
            startsAt: DateTime.utc(2026, 11, 21, 9),
            analysis: const VoiceAnalysis(voicedSeconds: 0),
          ),
          beforeSend: () async => beforeSendCalls++,
        ),
        throwsA(
          isA<ApiFailure>()
              .having((e) => e.status, 'status', 401)
              .having((e) => e.code, 'code', 'unauthenticated'),
        ),
      );

      expect(beforeSendCalls, 2);
      expect(uploadCalls, 2);
      expect(refreshCalls, 1);
      expect(sessions.active, isNull);
    },
  );
}
