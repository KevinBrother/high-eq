import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/contacts/scene.dart';
import 'package:high_eq/features/practice/conversation.dart';
import 'package:high_eq/features/practice/repository.dart';
import '../client_test.dart' show Handler, response;
import '../isolation_test.dart' show MemorySecret, tokens;

const sid = '00000000-0000-4000-8000-000000000001';
const ledger = {
  'status': 'charged',
  'net_charge': 1,
  'charged_day': '2026-11-20',
};
const refund = {
  'status': 'refunded',
  'net_charge': 0,
  'charged_day': '2026-11-20',
};
void main() {
  late Sessions sessions;
  late ApiPractice repo;
  late Handler transport;
  setUp(() async {
    final dir = await Directory.systemTemp.createTemp();
    addTearDown(() => dir.delete(recursive: true));
    sessions = Sessions(MemorySecret(), dir);
    transport = Handler();
    final scope = await sessions.activate(tokens('A'));
    repo = ApiPractice(
      AppApi(Uri.https('offline.invalid'), transport, sessions),
      scope,
    );
  });
  test('生成端点传筛选、分页、创建分支；待发内容不随账号转移', () async {
    final queries = <Map<String, String>>[];
    final input = {'request_id': sid, 'scene': 'family', 'scenario': '合成情境'};
    transport.handle = (op, req) async {
      expect(req.headers['Authorization'], 'Bearer access');
      if (op == AppOp.createSession) {
        expect(req.url.path, '/v1/sessions');
        expect(jsonDecode(req.body), input);
        return response({'session_id': sid});
      }
      expect(req.url.path, '/v1/levels');
      queries.add(req.url.queryParameters);
      return response({
        'items': [],
        'next_cursor': queries.length == 1 ? 'page-2' : null,
      });
    };
    await repo.levels(Scene.family, 2);
    expect(queries, [
      {'limit': '100', 'scene': 'family', 'difficulty': '2'},
      {
        'limit': '100',
        'scene': 'family',
        'difficulty': '2',
        'cursor': 'page-2',
      },
    ]);
    await repo.create(input);
    await repo.remember(sid, {
      'kind': 'send',
      'body': {'text': '合成草稿'},
    });
    await sessions.clear();
    final b = await sessions.activate(tokens('B'));
    expect(await ApiPractice(repo.api, b).read(sid), isNull);
    await expectLater(repo.get(sid), throwsA(isA<SessionChanged>()));
  });
  test('真实解帧：进行中、复用原 ID、服务已存但断线；重开只 GET，评分失败读取原日退款', () async {
    var sends = 0, finishes = 0;
    final bodies = <Json>[];
    final s = <String, dynamic>{
      'session_id': sid,
      'mode': 'full_session',
      'target_item': null,
      'status': 'pending',
      'messages': [],
      'settlement': {
        'status': 'uncharged',
        'charged_day': null,
        'net_charge': 0,
      },
    };
    transport.handle = (op, req) async {
      expect(req.url.path, startsWith('/v1/sessions/$sid'));
      if (op == AppOp.getSession) {
        expect(req.method, 'GET');
        return response(s);
      }
      if (op == AppOp.finishSession) {
        finishes++;
        expect(req.url.path, '/v1/sessions/$sid/finish');
        expect(req.body, isEmpty);
        s['status'] = 'failed';
        s['settlement'] = refund;
        return response({
          'code': 'internal_error',
          'message': '评分失败',
          'retryable': false,
        }, 500);
      }
      expect(op, AppOp.sendMessage);
      expect(req.url.path, '/v1/sessions/$sid/messages');
      expect(req.headers['Accept'], 'text/event-stream');
      final body = jsonDecode(req.body) as Json;
      bodies.add(body);
      final mid = body['client_message_id'];
      sends++;
      if (sends == 2) {
        s['status'] = 'active';
        s['settlement'] = ledger;
        s['messages'] = [
          {
            'id': sid,
            'seq': 1,
            'role': 'user',
            'text': body['text'],
            'client_message_id': mid,
          },
          {
            'id': '00000000-0000-4000-8000-000000000002',
            'seq': 2,
            'role': 'assistant',
            'text': '已保存的原回复',
            'client_message_id': mid,
          },
        ];
      }
      final bytes = utf8.encode(
        sends == 1
            ? 'event: in_progress\ndata: {"client_message_id":"$mid"}\n\n'
            : 'event: fragment\ndata: {"text":"半句","client_message_id":"$mid"}\n\n',
      );
      return http.StreamedResponse(
        Stream.fromIterable(bytes.map((n) => [n])),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    };
    final c = Conversation(repo, await repo.get(sid));
    await c.recover();
    await c.send('合成发言');
    expect(c.needsRead, isTrue);
    await c.recover();
    await c.retry();
    expect(c.needsRead, isTrue);
    expect(bodies, [bodies.first, bodies.first]);
    c.dispose();
    final reopened = Conversation(repo, await repo.get(sid));
    await reopened.recover();
    expect(reopened.rows.last['text'], '已保存的原回复');
    expect(reopened.command, isNull);
    expect(reopened.snapshot['settlement'], ledger);
    expect(sends, 2);
    await reopened.finish();
    expect(reopened.status, 'failed');
    expect(
      settlementLabel(reopened.snapshot['settlement']),
      contains('已退回 2026-11-20'),
    );
    await reopened.recover();
    expect(finishes, 1);
    expect(await repo.read(sid), isNull);
    reopened.dispose();
  });
}
