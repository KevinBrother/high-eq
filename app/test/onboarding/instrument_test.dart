import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/features/onboarding/repository.dart';
import '../isolation_test.dart' show MemorySecret, tokens;
import '../client_test.dart' show Handler, response;

void main() {
  test('服务端可改变维度的题序；首页只读最新一份，不下载整段测评历史', () async {
    final dir = await Directory.systemTemp.createTemp();
    addTearDown(() => dir.delete(recursive: true));
    final sessions = Sessions(MemorySecret(), dir);
    final scope = await sessions.activate(tokens('A'));
    final transport = Handler(),
        book = AssessmentBook(
          AppApi(Uri.https('local.invalid'), transport, sessions),
          scope,
        );
    final q = jsonDecode(
      File('assets/contract_examples.json').readAsStringSync(),
    )['getInstrument'];
    q['items'][0]['dimension'] = 'OEA';
    q['items'][4]['dimension'] = 'SEA';
    transport.handle = (_, _) async => response(q);
    expect((await book.instrument())['items'][0]['dimension'], 'OEA');
    transport.handle = (_, req) async {
      expect(req.url.queryParameters['limit'], '1');
      return response({
        'items': [
          {'id': 'latest'},
        ],
        'next_cursor': 'past',
      });
    };
    expect((await book.latest())?['id'], 'latest');
  });
}
