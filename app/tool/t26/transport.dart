import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Creates the real HTTP client used by the T26 live journey.
///
/// The journey's test binding enables real HTTP. This wrapper bypasses proxies,
/// refuses redirects, and rejects every target except a numeric loopback address.
http.Client t26LoopbackClient() {
  final inner = HttpClient()
    ..findProxy = ((_) => 'DIRECT')
    ..connectionTimeout = const Duration(seconds: 10);
  return _T26LoopbackClient(IOClient(inner));
}

class _T26LoopbackClient extends http.BaseClient {
  _T26LoopbackClient(this._inner);

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final uri = request.url;
    final address = InternetAddress.tryParse(uri.host);
    if (uri.scheme != 'http' || address == null || !address.isLoopback) {
      // Do not include the URL or host. A rejected request must not leak a
      // credential or environment value into test output.
      throw StateError(
        'T26 test client rejected a non-loopback or unsupported request',
      );
    }
    request.followRedirects = false;
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
