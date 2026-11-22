import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Creates a test-only HTTP client that can only reach numeric loopback hosts
/// and always bypasses proxy environment settings.
http.Client loopbackDirectClient() {
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
        'T29 test client rejected a non-loopback or unsupported request',
      );
    }
    request.followRedirects = false;
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
