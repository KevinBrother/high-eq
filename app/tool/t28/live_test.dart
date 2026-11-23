import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/consent.dart';
import 'package:high_eq/core/endpoints.g.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/health/platform.dart';
import 'package:high_eq/features/health/sync.dart';
import 'package:high_eq/features/health/windows.dart';
import 'package:http/http.dart' as http;

import '../../test/isolation_test.dart' show MemorySecret;
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
}

/// Wraps the real socket transport only to retain the exact requests sent.
class _RecordingTransport implements Transport {
  final Transport inner;
  final List<_Exchange> exchanges = [];

  _RecordingTransport(this.inner);

  @override
  Future<http.StreamedResponse> send(AppOp op, http.Request request) {
    exchanges.add(
      _Exchange(
        op: op,
        method: request.method,
        path: request.url.path,
        headers: Map.unmodifiable(request.headers),
        body: Uint8List.fromList(request.bodyBytes),
      ),
    );
    return inner.send(op, request);
  }

  List<_Exchange> get windowUploads =>
      exchanges.where((item) => item.op == AppOp.uploadWindow).toList();

  @override
  void close() => inner.close();
}

/// The only device substitute: synthetic historical samples plus a fake OS
/// authorization result. This never reads the real HealthKit or vendor store.
class _SyntheticHealthPort implements HealthPort {
  int requests = 0;
  int queryableCalls = 0;
  int reads = 0;
  int stopCalls = 0;

  @override
  Future<String?> source() async => 'apple_history';

  @override
  Future<bool> request({void Function()? onSystemPrompt}) async {
    requests++;
    onSystemPrompt?.call();
    return true;
  }

  @override
  Future<bool> queryable() async {
    queryableCalls++;
    return true;
  }

  @override
  Future<List<List>> read(int from, int to) async {
    reads++;
    return [
      ['heart_rate', from, from, 72],
    ];
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }
}

Json _jsonBody(_Exchange exchange) {
  final value = jsonDecode(utf8.decode(exchange.body));
  expect(value, isA<Json>(), reason: '${exchange.method} ${exchange.path}');
  return value as Json;
}

Json _healthWindow(DateTime startsAt) => {
  'channel': 'health',
  'starts_at': startsAt.toUtc().toIso8601String(),
  'duration_seconds': 30,
  'source': 'apple_history',
  'exercise': false,
  'heart_rate': {
    'mean': 72.0,
    'maximum': 72.0,
    'sample_count': 1,
    'valid_seconds': 1,
  },
};

Future<void> _expectForbidden(Future<Json> request) async {
  try {
    await request;
    fail('expected T30 to reject the unconsented window');
  } on ApiFailure catch (error) {
    expect(error.status, 403, reason: error.message);
  }
}

Future<Json?> _currentHealthConsent(
  MobileEndpoints wire,
  AccountScope scope,
) async {
  String? cursor;
  final seen = <String>{};
  do {
    final page = await wire.listConsents(scope: scope, cursor: cursor);
    for (final row in page['items'] as List) {
      if (row is Json && row['purpose'] == 'health') return row;
    }
    cursor = page['next_cursor'] as String?;
    if (cursor != null && !seen.add(cursor)) {
      fail('T05 returned a repeated consent cursor');
    }
  } while (cursor != null);
  return null;
}

Future<void> _waitForCompleteWindow(int collectionFrom) async {
  final deadline = DateTime.now().add(const Duration(minutes: 8));
  while (DateTime.now().isBefore(deadline)) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (floorSlot(now - 300000) >= collectionFrom + slotMs) return;
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  fail(
    'health collection boundary did not reach a complete upload slot: '
    'collection_from=$collectionFrom',
  );
}

void _expectStatisticsOnly(_Exchange exchange) {
  expect(exchange.method, 'POST');
  expect(exchange.path, '/v1/signal-windows');
  final body = _jsonBody(exchange);
  expect(
    body.keys.toSet(),
    {
      'channel',
      'starts_at',
      'duration_seconds',
      'exercise',
      'source',
      'heart_rate',
    },
    reason: 'only the documented health aggregate may cross the wire',
  );
  expect(body['channel'], 'health');
  expect(body['duration_seconds'], 30);
  expect(body['exercise'], false);
  expect(body['source'], 'apple_history');

  final heart = body['heart_rate'];
  expect(heart, isA<Json>());
  expect((heart as Json).keys.toSet(), {
    'mean',
    'maximum',
    'sample_count',
    'valid_seconds',
  });
  expect(heart['mean'], 72.0);
  expect(heart['maximum'], 72.0);
  expect(heart['sample_count'], 1);
  expect(heart['valid_seconds'], 1);

  final raw = utf8.decode(exchange.body).toLowerCase();
  for (final forbidden in ['healthkit', 'raw', 'payload', 'sample_value']) {
    expect(raw, isNot(contains(forbidden)), reason: 'raw health data leaked');
  }
}

Json _singleStoredWindow(Json page, DateTime startsAt) {
  final windows = page['windows'];
  expect(windows, isA<List>(), reason: 'fixture windows payload');
  final matches = (windows as List).whereType<Json>().where((item) {
    final raw = item['starts_at'];
    final parsed = raw is String ? DateTime.tryParse(raw) : null;
    return parsed != null && parsed.toUtc().isAtSameMomentAs(startsAt);
  }).toList();
  expect(matches, hasLength(1), reason: 'one stored window at $startsAt');
  return matches.single;
}

void main() {
  test(
    'real T28 client and T30 storage enforce consent, collection, and withdrawal',
    () async {
      final environment = Platform.environment;
      final rawOrigin = environment['T28_ORIGIN'];
      final fixtureToken = environment['T28_FIXTURE_TOKEN'];
      final devTicket = environment['T28_DEV_TICKET'];
      expect(rawOrigin, isNotNull, reason: 'T28_ORIGIN is required');
      expect(fixtureToken, isNotNull, reason: 'T28_FIXTURE_TOKEN is required');
      expect(devTicket, isNotNull, reason: 'T28_DEV_TICKET is required');
      final origin = Uri.parse(rawOrigin!);
      expect(origin.scheme, 'http');
      expect(origin.host, '127.0.0.1');
      expect(origin.hasPort, isTrue);

      final control = loopbackOnlyClient();
      addTearDown(control.close);
      Future<Json> fixture(
        String method,
        String path, {
        Json? body,
        Map<String, String>? query,
      }) async {
        final uri = origin.resolve(path).replace(queryParameters: query);
        final request = http.Request(method, uri);
        request.headers['X-T28-Fixture-Token'] = fixtureToken!;
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

      final directory = await Directory.systemTemp.createTemp('t28-live');
      addTearDown(() => directory.delete(recursive: true));
      final sessions = Sessions(MemorySecret(), directory);
      final transport = _RecordingTransport(
        HttpTransport(loopbackOnlyClient()),
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

      final port = _SyntheticHealthPort();
      final sync = HealthSync(api, scope, ConsentGate(api), port);
      addTearDown(sync.close);

      // Off means no collection and no transfer at all. The fake OS grant does
      // not create consent or membership by itself.
      expect((await sync.state())['mode'], 'off');
      final idleExchanges = transport.exchanges.length;
      await sync.tick();
      expect(transport.exchanges, hasLength(idleExchanges));
      expect(port.reads, 0);
      expect(transport.windowUploads, isEmpty);

      // A non-member cannot enable collection or prompt the device.
      await expectLater(sync.enable(), throwsA(isA<StateError>()));
      expect(port.requests, 0);
      expect(port.reads, 0);
      expect(await _currentHealthConsent(wire, scope), isNull);

      // The fixture grants only a disposable membership. T05 consent remains
      // absent, so the real T30 transaction must reject a valid aggregate.
      await fixture('POST', '/__t28/member', body: {'user_id': scope.account});
      final directAt = DateTime.fromMillisecondsSinceEpoch(
        floorSlot(DateTime.now().millisecondsSinceEpoch - 60000),
        isUtc: true,
      );
      await _expectForbidden(
        wire.uploadWindow(scope: scope, body: _healthWindow(directAt)),
      );
      expect(port.reads, 0);

      // enable() performs the real T05 grant and then crosses the full local
      // gate. Only the OS prompt result and historical samples are synthetic.
      await sync.enable();
      expect((await sync.state())['mode'], 'on');
      expect(port.requests, 1);
      expect(port.reads, 0);
      final enabledConsent = await _currentHealthConsent(wire, scope);
      expect(enabledConsent, isNotNull);
      expect(enabledConsent!['granted'], isTrue);

      final enabled = await sync.state();
      final collectionFrom = enabled['collection_from'];
      expect(collectionFrom, isA<int>());
      final from = collectionFrom as int;
      expect(enabled['cursor'], from);

      // Production deliberately withholds the newest five minutes. Wait for a
      // complete server-valid 30-second slot after the real consent timestamp;
      // injecting a future clock would not prove T30's transaction checks.
      await _waitForCompleteWindow(from);
      final uploadsBefore = transport.windowUploads.length;
      await sync.tick();
      expect(port.reads, 1, reason: 'one gated synthetic history query');
      expect(
        transport.windowUploads,
        hasLength(uploadsBefore + 1),
        reason: 'one aggregate upload after a complete window',
      );
      final upload = transport.windowUploads.last;
      _expectStatisticsOnly(upload);
      final sent = _jsonBody(upload);
      expect(
        DateTime.parse(sent['starts_at'] as String).millisecondsSinceEpoch,
        from,
      );

      final stored = await fixture(
        'GET',
        '/__t28/windows',
        query: {'user_id': scope.account},
      );
      final window = _singleStoredWindow(
        stored,
        DateTime.fromMillisecondsSinceEpoch(from, isUtc: true),
      );
      expect(window['channel'], 'health');
      expect(window['duration_seconds'], 30);
      expect(window['source'], 'apple_history');
      expect(window['exercise'], false);
      final heart = window['heart_rate'] as Json;
      expect(heart['mean'], 72.0);
      expect(heart['maximum'], 72.0);
      expect(heart['sample_count'], 1);
      expect(heart['valid_seconds'], 1);

      // Explicit withdrawal stops local collection, writes the real T05
      // revocation, and leaves the stored aggregate unchanged.
      final uploadsBeforeWithdrawal = transport.windowUploads.length;
      await sync.withdraw();
      expect((await sync.state())['mode'], 'off');
      expect(port.stopCalls, greaterThanOrEqualTo(1));
      final withdrawnConsent = await _currentHealthConsent(wire, scope);
      expect(withdrawnConsent, isNotNull);
      expect(withdrawnConsent!['granted'], isFalse);

      await sync.tick();
      expect(port.reads, 1, reason: 'withdrawn client must not read again');
      expect(
        transport.windowUploads,
        hasLength(uploadsBeforeWithdrawal),
        reason: 'withdrawn client must not upload again',
      );

      final postWithdrawalAt = DateTime.fromMillisecondsSinceEpoch(
        floorSlot(DateTime.now().millisecondsSinceEpoch - 60000),
        isUtc: true,
      );
      await _expectForbidden(
        wire.uploadWindow(scope: scope, body: _healthWindow(postWithdrawalAt)),
      );
      final after = await fixture(
        'GET',
        '/__t28/windows',
        query: {'user_id': scope.account},
      );
      expect(after['windows'], hasLength(1));
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
