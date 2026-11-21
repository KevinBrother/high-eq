import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/sse.dart';
import 'package:high_eq/core/transport.dart';
import 'isolation_test.dart' show MemorySecret, tokens;

void main() {
  test(
    'real loopback HTTP sends UTF-8 JSON and bearer, decodes streamed terminal frame',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final paths = <String>[];
      server.listen((req) async {
        paths.add(req.uri.path);
        expect(
          req.headers.value(HttpHeaders.authorizationHeader),
          'Bearer access',
        );
        if (req.method == 'POST') {
          expect(req.headers.value('accept'), 'text/event-stream');
          final body = jsonDecode(await utf8.decoder.bind(req).join());
          expect(body, {'client_message_id': 'm', 'text': '练习'});
          req.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          req.response.write(
            'event: in_progress\r\ndata: {"client_message_id":"m"}\r\n\r\n',
          );
        } else {
          expect(req.uri.queryParameters, {'cursor': '一 / 二'});
          req.response.headers.contentType = ContentType.json;
          req.response.write('{"items":[],"next_cursor":null}');
        }
        await req.response.close();
      });
      final dir = await Directory.systemTemp.createTemp();
      addTearDown(() => dir.delete(recursive: true));
      final sessions = Sessions(MemorySecret(), dir);
      final a = await sessions.activate(tokens('A'));
      final transport = HttpTransport(http.Client());
      addTearDown(transport.close);
      final api = AppApi(
        Uri.parse('http://127.0.0.1:${server.port}'),
        transport,
        sessions,
      );
      expect(
        (await api.messages(a, 's', 'm', '练习').single).kind,
        ReplyEventKind.inProgress,
      );
      expect(
        (await api.json(
          AppOp.listSessions,
          scope: a,
          query: {'cursor': '一 / 二'},
        ))['items'],
        isEmpty,
      );
      expect(paths, ['/v1/sessions/s/messages', '/v1/sessions']);
    },
  );
}
