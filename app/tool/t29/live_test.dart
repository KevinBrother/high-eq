import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/endpoints.g.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/voice/access.dart';
import 'package:high_eq/features/voice/controller.dart';
import 'package:high_eq/features/voice/platform.dart';
import 'package:high_eq/features/voice/store.dart';
import 'package:http/http.dart' as http;

import '../../test/isolation_test.dart' show MemorySecret;
import '../../test/voice/synthetic.dart';
import 'loopback_client.dart';

class _Exchange {
  final AppOp op;
  final String method;
  final String path;
  final Map<String, String> headers;
  final Uint8List body;

  const _Exchange({
    required this.op,
    required this.method,
    required this.path,
    required this.headers,
    required this.body,
  });

  @override
  String toString() => '_Exchange($op, $method, $path)';
}

/// Wraps the real HTTP transport and only injects the two outages required by
/// this contract test. Every successful request still crosses the real socket.
class _RecordingTransport implements Transport {
  final Transport inner;
  final List<_Exchange> exchanges = [];
  bool offline = false;
  bool failSignalWindowUploads = false;

  _RecordingTransport(this.inner);

  @override
  Future<http.StreamedResponse> send(AppOp op, http.Request request) async {
    exchanges.add(
      _Exchange(
        op: op,
        method: request.method,
        path: request.url.path,
        headers: Map.unmodifiable(request.headers),
        body: Uint8List.fromList(request.bodyBytes),
      ),
    );
    if (offline || (failSignalWindowUploads && op == AppOp.uploadWindow)) {
      return http.StreamedResponse(
        Stream.value(
          utf8.encode(
            jsonEncode({
              'code': 'unavailable',
              'message': 'synthetic T29 transport outage',
              'retryable': true,
            }),
          ),
        ),
        503,
        headers: {'content-type': 'application/json'},
      );
    }
    try {
      return await inner.send(op, request);
    } on Exception {
      // Do not let transport exceptions echo request URLs, headers or bodies.
      throw TestFailure('business ${op.name} request failed');
    }
  }

  List<_Exchange> signalWindows() =>
      exchanges.where((item) => item.op == AppOp.uploadWindow).toList();

  @override
  void close() => inner.close();
}

/// The only device substitute: a synthetic PCM source and fake OS permission.
/// It never records from a real microphone or sends audio anywhere.
class _SyntheticVoicePlatform implements VoiceCapturePlatform {
  final StreamController<VoicePcmChunk> _pcm =
      StreamController<VoicePcmChunk>.broadcast();
  final List<Uint8List> played = [];
  bool permission = true;
  int permissionChecks = 0;
  int permissionRequests = 0;
  int startCalls = 0;
  int stopCalls = 0;
  int stopPlaybackCalls = 0;
  bool _closed = false;
  Future<void>? _disposing;

  @override
  Stream<VoicePcmChunk> get pcm => _pcm.stream;

  void emit(Uint8List pcm, DateTime startsAt) {
    if (_closed) throw StateError('synthetic voice platform is closed');
    _pcm.add(VoicePcmChunk(pcm: pcm, capturedAt: startsAt.toUtc()));
  }

  @override
  Future<bool> checkPermission() async {
    permissionChecks++;
    return permission;
  }

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return permission;
  }

  @override
  Future<void> start() async {
    startCalls++;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> playPcm(Uint8List pcm) async {
    played.add(Uint8List.fromList(pcm));
  }

  @override
  Future<void> stopPlayback() async {
    stopPlaybackCalls++;
  }

  @override
  Future<void> dispose() => _disposing ??= _dispose();

  Future<void> _dispose() async {
    if (_closed) return;
    _closed = true;
    await _pcm.close();
  }
}

Future<void> _emitAndSettle(
  _SyntheticVoicePlatform platform,
  VoiceController controller,
  Uint8List pcm,
  DateTime startsAt,
) async {
  platform.emit(pcm, startsAt);
  await pumpEventQueue();
  await controller.settle();
  await pumpEventQueue();
}

Json _jsonBody(_Exchange exchange) {
  Object? value;
  try {
    value = jsonDecode(utf8.decode(exchange.body));
  } on FormatException {
    throw TestFailure(
      '${exchange.method} ${exchange.path} returned invalid JSON',
    );
  }
  if (value is! Json) {
    throw TestFailure(
      '${exchange.method} ${exchange.path} returned non-object JSON',
    );
  }
  return value;
}

void _expectStatisticsOnly(Json body) {
  const allowedTopLevel = {
    'channel',
    'starts_at',
    'duration_seconds',
    'exercise',
    'voiced_seconds',
    'volume',
    'pitch',
  };
  expect(body.keys.toSet().difference(allowedTopLevel), isEmpty);
  expect(
    body.keys.toSet().intersection({'speech_rate', 'speech_rate_unit'}),
    isEmpty,
  );
  expect(body['channel'], 'voice');
  expect(body['duration_seconds'], 30);
  expect(body['exercise'], false);
  expect(body['voiced_seconds'], isA<int>());

  const allowedStat = {'mean', 'maximum', 'sample_count', 'valid_seconds'};
  for (final name in ['volume', 'pitch']) {
    final stat = body[name];
    if (stat == null) continue;
    if (stat is! Json) {
      throw TestFailure('$name must be a wire statistic');
    }
    expect(stat.keys.toSet().difference(allowedStat), isEmpty);
  }
}

void _expectNoRawAudio(_Exchange exchange) {
  final body = utf8.decode(exchange.body).toLowerCase();
  final headers = exchange.headers.entries
      .map((entry) => '${entry.key}:${entry.value}')
      .join('\n')
      .toLowerCase();
  for (final forbidden in [
    'pcm',
    'audio',
    'transcript',
    'base64',
    'data:audio',
  ]) {
    expect(
      body.contains(forbidden),
      isFalse,
      reason: 'forbidden request-body marker: $forbidden',
    );
    expect(
      headers.contains(forbidden),
      isFalse,
      reason: 'forbidden request-header marker: $forbidden',
    );
  }
  expect(exchange.body.length, lessThan(8192));
}

int _windowCount(Json page) {
  final windows = page['windows'];
  if (windows is! List) {
    throw TestFailure('bridge windows payload is not a list');
  }
  return windows.length;
}

Json _storedWindow(Json page, DateTime startsAt) {
  final windows = page['windows'];
  if (windows is! List) {
    throw TestFailure('bridge windows payload is not a list');
  }
  final matches = windows.whereType<Json>().where((item) {
    final raw = item['starts_at'];
    final parsed = raw is String ? DateTime.tryParse(raw) : null;
    return parsed != null && parsed.toUtc().isAtSameMomentAs(startsAt);
  }).toList();
  if (matches.length != 1) {
    throw TestFailure('expected one stored window at $startsAt');
  }
  return matches.single;
}

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

void main() {
  test(
    'real T29 client and T30 storage enforce membership, privacy, retention and revocation',
    () async {
      final environment = Platform.environment;
      final rawOrigin = environment['T29_ORIGIN'];
      final fixtureToken = environment['T29_FIXTURE_TOKEN'];
      final devTicket = environment['T29_DEV_TICKET'];
      expect(rawOrigin, isNotNull, reason: 'T29_ORIGIN is required');
      expect(fixtureToken, isNotNull, reason: 'T29_FIXTURE_TOKEN is required');
      expect(devTicket, isNotNull, reason: 'T29_DEV_TICKET is required');
      final origin = Uri.parse(rawOrigin!);
      final originAddress = InternetAddress.tryParse(origin.host);
      expect(origin.scheme, 'http');
      expect(
        originAddress?.isLoopback,
        isTrue,
        reason: 'T29_ORIGIN must use a numeric loopback host',
      );
      expect(origin.hasPort, isTrue);

      final control = loopbackDirectClient();
      addTearDown(control.close);
      Future<Json> fixture(
        String method,
        String path, {
        Json? body,
        Map<String, String>? query,
      }) async {
        final uri = origin.resolve(path).replace(queryParameters: query);
        final request = http.Request(method, uri);
        request.headers['X-T29-Fixture-Token'] = fixtureToken!;
        if (body != null) {
          request.headers['Content-Type'] = 'application/json';
          request.bodyBytes = utf8.encode(jsonEncode(body));
        }
        http.StreamedResponse response;
        try {
          response = await control.send(request);
        } on Exception {
          // Keep fixture failures free of URLs, tokens and response payloads.
          throw TestFailure('fixture $method $path request failed');
        }
        String raw;
        try {
          raw = await response.stream.bytesToString();
        } on Exception {
          throw TestFailure('fixture $method $path response read failed');
        }
        if (response.statusCode != 200) {
          throw TestFailure(
            'fixture $method $path returned HTTP ${response.statusCode}',
          );
        }
        Object? value;
        try {
          value = jsonDecode(raw);
        } on FormatException {
          throw TestFailure('fixture $method $path returned invalid JSON');
        }
        if (value is! Json) {
          throw TestFailure('fixture $method $path returned non-object JSON');
        }
        return value;
      }

      final directory = await Directory.systemTemp.createTemp('t29-live');
      addTearDown(() => directory.delete(recursive: true));
      final secret = MemorySecret();
      final sessions = Sessions(secret, directory);
      final transport = _RecordingTransport(
        HttpTransport(loopbackDirectClient()),
      );
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

      final access = ApiVoiceAccess(api);
      final uploader = ApiVoiceUploader(api);
      final store = VoiceWindowStore(sessions, scope);
      final platform = _SyntheticVoicePlatform();
      final controller = VoiceController(
        sessions: sessions,
        scope: scope,
        access: access,
        uploader: uploader,
        platform: platform,
        store: store,
        now: () => DateTime.now().toUtc(),
      );
      addTearDown(() async {
        controller.dispose();
        await platform.dispose();
      });

      // Keep actual consent rows unchanged. Let T30 see complete 30-second
      // slots after the genuine grant. Only PCM and OS permission are simulated.
      Future<DateTime> allocateStart() async {
        final now = DateTime.now().toUtc();
        final ms = now.millisecondsSinceEpoch;
        final start = DateTime.fromMillisecondsSinceEpoch(
          (ms ~/ 30000 + 1) * 30000,
          isUtc: true,
        );
        await Future<void>.delayed(
          start
              .add(const Duration(seconds: 30, milliseconds: 200))
              .difference(now),
        );
        return start;
      }

      Future<Json> storedWindows() =>
          fixture('GET', '/__t29/windows', query: {'user_id': scope.account});

      await controller.initialize();
      expect(controller.voiceConsent, isFalse);
      expect(controller.memberActive, isFalse);
      expect(await controller.grantVoiceConsent(), isTrue);
      expect(controller.voiceConsent, isTrue);

      // A consenting free account still cannot start native capture.
      expect(await controller.start(), isFalse);
      expect(controller.isCapturing, isFalse);
      expect(platform.startCalls, 0);
      expect(transport.signalWindows().length, 0);

      await fixture('POST', '/__t29/member', body: {'user_id': scope.account});
      expect(await controller.start(), isTrue, reason: controller.notice);
      expect(controller.memberActive, isTrue);
      expect(controller.retentionConsent, isFalse);
      expect(controller.retainAudio, isFalse);
      expect(platform.startCalls, 1);

      final firstStart = await allocateStart();
      await _emitAndSettle(
        platform,
        controller,
        tone(duration: const Duration(seconds: 30), syllableHz: 4),
        firstStart,
      );
      expect(controller.pendingCount, 0);
      expect(controller.recordings.length, 0);
      expect(transport.signalWindows().length, 1);
      final firstRequest = transport.signalWindows().single;
      expect(firstRequest.method, 'POST');
      expect(firstRequest.path, '/v1/signal-windows');
      _expectStatisticsOnly(_jsonBody(firstRequest));
      _expectNoRawAudio(firstRequest);

      var windows = await storedWindows();
      final firstStored = _storedWindow(windows, firstStart);
      expect(firstStored['channel'], 'voice');
      expect(firstStored['duration_seconds'], 30);
      expect(firstStored['exercise'], false);
      expect(firstStored['voiced_seconds'], greaterThan(20));
      expect(firstStored.containsKey('speech_rate'), isFalse);
      expect(firstStored.containsKey('speech_rate_unit'), isFalse);
      expect(firstStored['volume'], isNotNull);
      expect(firstStored['pitch'], isNotNull);

      // Refusing audio retention must not disable statistics analysis.
      final noRetentionStart = await allocateStart();
      await _emitAndSettle(
        platform,
        controller,
        tone(duration: const Duration(seconds: 30), syllableHz: 4),
        noRetentionStart,
      );
      expect(controller.retentionConsent, isFalse);
      expect(controller.retainAudio, isFalse);
      expect(controller.recordings.length, 0);
      expect(transport.signalWindows().length, 2);
      windows = await storedWindows();
      expect(
        _storedWindow(windows, noRetentionStart)['voiced_seconds'],
        greaterThan(20),
      );

      // A real retention grant followed by a real withdrawal also keeps the
      // independent statistics path working.
      expect(await controller.enableRetention(), isTrue);
      expect(controller.retainAudio, isTrue);
      await controller.disableRetention();
      expect(controller.retentionConsent, isFalse);
      expect(controller.retainAudio, isFalse);
      expect(await store.retentionRevoked(), isFalse);
      final revokedRetentionStart = await allocateStart();
      await _emitAndSettle(
        platform,
        controller,
        tone(duration: const Duration(seconds: 30), syllableHz: 4),
        revokedRetentionStart,
      );
      expect(transport.signalWindows().length, 3);
      expect(controller.recordings.length, 0);
      windows = await storedWindows();
      expect(
        _storedWindow(windows, revokedRetentionStart)['voiced_seconds'],
        greaterThan(20),
      );

      // Pure silence is a real stored aggregate with no invented feature data.
      final silenceStart = await allocateStart();
      await _emitAndSettle(
        platform,
        controller,
        silence(duration: const Duration(seconds: 30)),
        silenceStart,
      );
      expect(controller.latestAnalysis?.voicedSeconds, 0);
      expect(transport.signalWindows().length, 4);
      windows = await storedWindows();
      final silentStored = _storedWindow(windows, silenceStart);
      expect(silentStored['voiced_seconds'], 0);
      expect(silentStored.containsKey('speech_rate'), isFalse);
      expect(silentStored.containsKey('speech_rate_unit'), isFalse);
      expect(silentStored.containsKey('volume'), isFalse);
      expect(silentStored.containsKey('pitch'), isFalse);

      // Retention stores the exact local PCM, playback never uploads it, and
      // the server still receives only the statistics object.
      expect(await controller.enableRetention(), isTrue);
      final recordingStart = await allocateStart();
      final recordedPcm = tone(
        duration: const Duration(seconds: 30),
        syllableHz: 4,
      );
      await _emitAndSettle(platform, controller, recordedPcm, recordingStart);
      expect(controller.recordings.length, 1);
      expect(controller.recordings.single.startsAt, recordingStart);
      expect(transport.signalWindows().length, 5);
      await controller.stop();
      final uploadsBeforePlayback = transport.signalWindows().length;
      expect(
        await controller.playRecording(controller.recordings.single.id),
        isTrue,
      );
      expect(platform.played.length, 1);
      expect(_sameBytes(platform.played.single, recordedPcm), isTrue);
      expect(transport.signalWindows().length, uploadsBeforePlayback);

      // A signal-window outage leaves the encrypted local queue intact.
      expect(await controller.start(), isTrue, reason: controller.notice);
      transport.failSignalWindowUploads = true;
      final failedStart = await allocateStart();
      await _emitAndSettle(
        platform,
        controller,
        tone(duration: const Duration(seconds: 30), syllableHz: 4),
        failedStart,
      );
      expect(controller.pendingCount, 1);
      expect((await store.pending()).length, 1);
      expect(controller.recordings.length, 2);
      expect(transport.signalWindows().length, 6);
      final failedRequest = transport.signalWindows().last;
      _expectStatisticsOnly(_jsonBody(failedRequest));
      _expectNoRawAudio(failedRequest);
      expect(_windowCount(await storedWindows()), 5);

      // Offline revocation must persist a fail-closed marker, clear both local
      // queues/recordings, and never restart capture or replay old windows.
      transport.offline = true;
      final startCallsBeforeRevoke = platform.startCalls;
      expect(await controller.revokeVoice(), isFalse);
      expect(controller.voiceRevocationPending, isTrue);
      expect(controller.isCapturing, isFalse);
      expect(controller.pendingCount, 0);
      expect(controller.recordings.length, 0);
      expect(await store.voiceRevoked(), isTrue);
      expect((await store.pending()).length, 0);
      expect((await store.recordings()).length, 0);
      expect(platform.startCalls, startCallsBeforeRevoke);

      transport.offline = false;
      final uploadsBeforeRecovery = transport.signalWindows().length;
      expect(await controller.uploadPending(), isFalse);
      expect(transport.signalWindows().length, uploadsBeforeRecovery);
      expect(_windowCount(await storedWindows()), 5);

      // Reconstructing Sessions from the same secret and directory preserves
      // the revocation marker and remains fail-closed even though the server
      // still has the old online consent because revocation was offline.
      controller.dispose();
      await platform.dispose();
      final restoredSessions = Sessions(secret, directory);
      await restoredSessions.restore();
      final restoredScope = restoredSessions.active;
      expect(restoredScope, isNotNull);
      expect(
        restoredScope!.account == scope.account,
        isTrue,
        reason: 'restored account mismatch',
      );
      final restoredStore = VoiceWindowStore(restoredSessions, restoredScope);
      expect(await restoredStore.voiceRevoked(), isTrue);
      expect((await restoredStore.pending()).length, 0);
      expect((await restoredStore.recordings()).length, 0);

      final restoredApi = AppApi(origin, transport, restoredSessions);
      final restoredPlatform = _SyntheticVoicePlatform();
      final restoredController = VoiceController(
        sessions: restoredSessions,
        scope: restoredScope,
        access: ApiVoiceAccess(restoredApi),
        uploader: ApiVoiceUploader(restoredApi),
        platform: restoredPlatform,
        store: restoredStore,
        now: () => DateTime.now().toUtc(),
      );
      addTearDown(() async {
        restoredController.dispose();
        await restoredPlatform.dispose();
      });
      await restoredController.initialize();
      expect(restoredController.voiceRevocationPending, isTrue);
      expect(restoredController.voiceConsent, isFalse);
      expect(await restoredController.start(), isFalse);
      expect(restoredPlatform.startCalls, 0);
      expect(_windowCount(await storedWindows()), 5);
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
