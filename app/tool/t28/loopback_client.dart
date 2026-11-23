import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Test-only client for the T28 live harness.
///
/// Fixture control and business HTTP must never inherit a developer or CI host
/// proxy. The wrapper validates the original target before sending and disables
/// redirects, so neither a malformed origin nor a redirect can escape loopback.
http.Client loopbackOnlyClient() {
  final client = HttpClient()
    ..findProxy = ((_) => 'DIRECT')
    ..connectionTimeout = const Duration(seconds: 10);
  return _LoopbackOnlyClient(IOClient(client));
}

class _LoopbackOnlyClient extends http.BaseClient {
  final http.Client _inner;

  _LoopbackOnlyClient(this._inner);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final uri = request.url;
    final address = InternetAddress.tryParse(uri.host);
    if ((uri.scheme != 'http' && uri.scheme != 'https') ||
        address == null ||
        !address.isLoopback) {
      // Do not include the URL or host: callers must not leak request data in
      // failure output.
      throw StateError(
        'T28 test client rejected a non-loopback or unsupported request',
      );
    }
    request.followRedirects = false;
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
