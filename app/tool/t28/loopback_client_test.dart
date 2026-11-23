import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/transport.dart';
import 'package:http/http.dart' as http;

import 'loopback_client.dart';

class _ProxySentinel {
  int requests = 0;
}

class _SyntheticRoute implements Exception {
  const _SyntheticRoute();
}

/// Stops at the HttpClient boundary and records whether the resolved route
/// would use the host proxy or connect directly. This keeps the assertion
/// deterministic in sandboxes that forbid listening on TCP sockets.
class _RoutingHttpClient implements HttpClient {
  final _ProxySentinel proxy;
  String Function(Uri url)? _findProxy;
  int directRequests = 0;

  _RoutingHttpClient(this.proxy);

  @override
  set findProxy(String Function(Uri url)? value) {
    _findProxy = value;
  }

  @override
  set connectionTimeout(Duration? value) {}

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final route = _findProxy?.call(url) ?? 'DIRECT';
    if (route == 'DIRECT') {
      directRequests++;
    } else if (route.startsWith('PROXY ')) {
      proxy.requests++;
    } else {
      throw StateError('unexpected synthetic proxy route: $route');
    }
    throw const _SyntheticRoute();
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'unexpected HttpClient call: ${invocation.memberName}',
  );
}

void main() {
  final targetUri = Uri.parse('http://127.0.0.1:41028/t28-loopback-probe');
  const proxyEnvironment = {'http_proxy': 'http://127.0.0.1:41029'};

  test('default test client inherits the host proxy sentinel', () async {
    expect(
      HttpClient.findProxyFromEnvironment(
        targetUri,
        environment: proxyEnvironment,
      ),
      'PROXY 127.0.0.1:41029',
    );

    final sentinel = _ProxySentinel();
    final clients = <_RoutingHttpClient>[];
    await HttpOverrides.runZoned(
      () async {
        final inheritedProxy = http.Client();
        try {
          await expectLater(
            inheritedProxy.get(targetUri),
            throwsA(isA<_SyntheticRoute>()),
          );
          expect(
            sentinel.requests,
            1,
            reason: 'the default client must reproduce the host proxy route',
          );
          expect(clients.single.directRequests, 0);
        } finally {
          inheritedProxy.close();
        }
      },
      createHttpClient: (_) {
        final client = _RoutingHttpClient(sentinel);
        client.findProxy = (uri) => HttpClient.findProxyFromEnvironment(
          uri,
          environment: proxyEnvironment,
        );
        clients.add(client);
        return client;
      },
    );
  });

  test(
    'loopback test client sends zero requests to the proxy sentinel',
    () async {
      final sentinel = _ProxySentinel();
      final clients = <_RoutingHttpClient>[];
      await HttpOverrides.runZoned(
        () async {
          final isolated = loopbackOnlyClient();
          try {
            await expectLater(
              isolated.get(targetUri),
              throwsA(isA<_SyntheticRoute>()),
            );
            expect(clients.single.directRequests, 1);
            expect(
              sentinel.requests,
              0,
              reason: 'loopback fixture traffic must not reach the proxy',
            );

            await expectLater(
              isolated.get(Uri.parse('http://192.0.2.1/t28-probe')),
              throwsA(isA<StateError>()),
              reason: 'the test client must refuse non-loopback targets',
            );
            expect(clients.single.directRequests, 1);
            expect(
              sentinel.requests,
              0,
              reason: 'rejected non-loopback traffic must not reach the proxy',
            );
          } finally {
            isolated.close();
          }
        },
        createHttpClient: (_) {
          final client = _RoutingHttpClient(sentinel);
          client.findProxy = (uri) => HttpClient.findProxyFromEnvironment(
            uri,
            environment: proxyEnvironment,
          );
          clients.add(client);
          return client;
        },
      );
    },
  );

  test('isolated live client bypasses a real local proxy sentinel', () async {
    late HttpServer target;
    late HttpServer sentinel;
    try {
      target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      sentinel = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    } on SocketException catch (error) {
      markTestSkipped(
        'loopback sockets unavailable in this sandbox: '
        '${error.osError?.message ?? error.message}',
      );
      return;
    }
    addTearDown(() => target.close(force: true));
    addTearDown(() => sentinel.close(force: true));

    var targetRequests = 0;
    var proxyRequests = 0;
    final redirectTarget = Uri.parse(
      'http://192.0.2.1/t28-non-loopback-redirect-target',
    );

    target.listen((request) async {
      targetRequests++;
      if (request.uri.path == '/redirect') {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          redirectTarget.toString(),
        );
      } else {
        request.response.statusCode = HttpStatus.noContent;
      }
      await request.response.close();
    });

    sentinel.listen((request) async {
      proxyRequests++;
      request.response.statusCode = HttpStatus.badGateway;
      await request.response.close();
    });

    final localTarget = Uri.parse(
      'http://127.0.0.1:${target.port}/t28-loopback-probe',
    );
    final localRedirect = Uri.parse('http://127.0.0.1:${target.port}/redirect');

    // The override is scoped to this test zone. It simulates a proxy
    // environment for the default-client positive control without changing
    // process variables or the Flutter test runner's control connection.
    await HttpOverrides.runZoned(() async {
      final inheritedProxy = http.Client();
      try {
        final proxied = await inheritedProxy.get(localTarget);
        expect(proxied.statusCode, HttpStatus.badGateway);
        expect(proxyRequests, 1);
        expect(targetRequests, 0);
      } finally {
        inheritedProxy.close();
      }

      final fixtureClient = loopbackOnlyClient();
      try {
        final direct = await fixtureClient.get(localTarget);
        expect(direct.statusCode, HttpStatus.noContent);
        expect(targetRequests, 1);
        expect(
          proxyRequests,
          1,
          reason: 'the fixture request must add zero sentinel requests',
        );

        final response = await fixtureClient.get(localRedirect);
        expect(response.statusCode, HttpStatus.found);
        expect(
          response.headers[HttpHeaders.locationHeader],
          redirectTarget.toString(),
        );
        expect(
          targetRequests,
          2,
          reason: 'the redirect response must not trigger a follow-up request',
        );
        expect(
          proxyRequests,
          1,
          reason: 'a non-loopback redirect must not reach the proxy',
        );
      } finally {
        fixtureClient.close();
      }

      final business = HttpTransport(loopbackOnlyClient());
      try {
        final response = await business.send(
          AppOp.checkHealth,
          http.Request('GET', localTarget),
        );
        expect(response.statusCode, HttpStatus.noContent);
        await response.stream.drain<void>();
        expect(targetRequests, 3);
        expect(
          proxyRequests,
          1,
          reason: 'the business request must add zero sentinel requests',
        );
      } finally {
        business.close();
      }
    }, findProxyFromEnvironment: (_, _) => 'PROXY 127.0.0.1:${sentinel.port}');
  });
}
