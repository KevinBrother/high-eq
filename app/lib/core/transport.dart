import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'app_op.g.dart';

typedef Json = Map<String, dynamic>;

abstract interface class Transport {
  Future<http.StreamedResponse> send(AppOp op, http.Request request);
  void close();
}

class HttpTransport implements Transport {
  final http.Client _client;
  HttpTransport(this._client);
  @override
  Future<http.StreamedResponse> send(AppOp op, http.Request request) =>
      _client.send(request);
  @override
  void close() => _client.close();
}

class ExampleTransport implements Transport {
  late final Future<Json> _fixtures = rootBundle
      .loadString('assets/contract_examples.json')
      .then((s) => jsonDecode(s) as Json);
  @override
  Future<http.StreamedResponse> send(AppOp op, http.Request request) async {
    final fixture = (await _fixtures)[op.name];
    if (op == AppOp.exportData) {
      return http.StreamedResponse(
        Stream.value(base64Decode(fixture)),
        200,
        headers: {'content-type': op.accept},
      );
    }
    if (op == AppOp.sendMessage) {
      final id = (jsonDecode(request.body) as Json)['client_message_id'];
      final events = (fixture as List).cast<String>().map(
        (frame) => utf8.encode(
          frame.replaceAll('85b72033-9f07-4bbc-8567-fc31f26508ab', id),
        ),
      );
      return http.StreamedResponse(
        Stream.fromIterable(events),
        200,
        headers: {'content-type': op.accept},
      );
    }
    final result = switch (op) {
      AppOp.login || AppOp.refreshTokens || AppOp.switchIdentity => {
        ...fixture as Json,
        'expires_at': DateTime.now()
            .toUtc()
            .add(const Duration(hours: 1))
            .toIso8601String(),
      },
      _ => fixture,
    };
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(result))),
      200,
      headers: {'content-type': op.accept},
    );
  }

  @override
  void close() {}
}
