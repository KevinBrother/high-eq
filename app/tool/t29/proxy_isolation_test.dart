import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/endpoints.g.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:http/http.dart' as http;

import 'loopback_client.dart';

class _MemorySecret implements SecretStore {
  String? _value;

  @override
  Future<String?> read() async => _value;

  @override
  Future<void> replace(String? value) async {
    _value = value;
  }
}

Future<void> _respondJson(HttpRequest request) async {
  request.response.statusCode = HttpStatus.ok;
  request.response.headers.contentType = ContentType.json;
  request.response.write('{"ok":true}');
  await request.response.close();
}

void main() {
  test(
    'fixture and business clients bypass an isolate-scoped sentinel proxy',
    () async {
      final rawSentinelProxy = Platform.environment['T29_SENTINEL_PROXY'];
      if (rawSentinelProxy == null) {
        throw TestFailure('run this test through with_sentinel_proxy.sh');
      }
      final sentinelProxy = Uri.tryParse(rawSentinelProxy);
      if (sentinelProxy == null ||
          sentinelProxy.scheme != 'http' ||
          sentinelProxy.host != '127.0.0.1' ||
          !sentinelProxy.hasPort) {
        throw TestFailure(
          'T29_SENTINEL_PROXY must name an isolated loopback proxy',
        );
      }

      final fixtureServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final businessServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => fixtureServer.close(force: true));
      addTearDown(() => businessServer.close(force: true));

      var redirectTargets = 0;
      fixtureServer.listen((request) async {
        if (request.uri.path == '/redirect') {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            '/redirect-target',
          );
          await request.response.close();
          return;
        }
        if (request.uri.path == '/redirect-target') {
          redirectTargets++;
        }
        await _respondJson(request);
      });
      businessServer.listen((request) async {
        if (request.uri.path != '/v1/health') {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        await _respondJson(request);
      });

      // The override is scoped to this test zone. It simulates a proxy
      // environment for default clients without changing process variables or
      // the Flutter test runner's control connection.
      await HttpOverrides.runZoned(
        () async {
          final defaultClient = http.Client();
          addTearDown(defaultClient.close);
          late http.Response controlResponse;
          try {
            controlResponse = await defaultClient
                .get(Uri.parse('http://127.0.0.1:1/sentinel-control'))
                .timeout(const Duration(seconds: 10));
          } catch (_) {
            throw TestFailure(
              'default client did not reach the synthetic proxy sentinel',
            );
          }
          expect(controlResponse.statusCode, HttpStatus.badGateway);
          expect(controlResponse.body, isEmpty);

          final fixtureClient = loopbackDirectClient();
          addTearDown(fixtureClient.close);
          final fixtureResponse = await fixtureClient.get(
            Uri(
              scheme: 'http',
              host: '127.0.0.1',
              port: fixtureServer.port,
              path: '/fixture',
            ),
          );
          expect(fixtureResponse.statusCode, HttpStatus.ok);
          expect(_isJsonOk(fixtureResponse.body), isTrue);

          final redirectResponse = await fixtureClient.get(
            Uri(
              scheme: 'http',
              host: '127.0.0.1',
              port: fixtureServer.port,
              path: '/redirect',
            ),
          );
          expect(redirectResponse.statusCode, HttpStatus.found);
          expect(
            redirectResponse.headers[HttpHeaders.locationHeader],
            '/redirect-target',
          );
          expect(redirectTargets, 0);

          final directory = await Directory.systemTemp.createTemp(
            't29-proxy-isolation',
          );
          addTearDown(() => directory.delete(recursive: true));
          final sessions = Sessions(_MemorySecret(), directory);
          final transport = HttpTransport(loopbackDirectClient());
          addTearDown(transport.close);
          final api = AppApi(
            Uri(scheme: 'http', host: '127.0.0.1', port: businessServer.port),
            transport,
            sessions,
          );
          final health = await MobileEndpoints(api).checkHealth();
          expect(health['ok'], isTrue);

          final rejectedClient = loopbackDirectClient();
          addTearDown(rejectedClient.close);
          await expectLater(
            rejectedClient.get(Uri.parse('http://192.0.2.1/not-loopback')),
            throwsA(isA<StateError>()),
          );
          await expectLater(
            rejectedClient.get(Uri.parse('http://localhost:1/not-numeric')),
            throwsA(isA<StateError>()),
          );
        },
        findProxyFromEnvironment: (_, _) =>
            'PROXY 127.0.0.1:${sentinelProxy.port}',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

bool _isJsonOk(String raw) {
  try {
    final value = jsonDecode(raw);
    return value is Map<String, dynamic> && value['ok'] == true;
  } catch (_) {
    return false;
  }
}
