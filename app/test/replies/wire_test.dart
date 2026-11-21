import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/replies/repository.dart';
import 'package:high_eq/features/replies/result.dart';
import 'package:http/http.dart' as http;
import '../client_test.dart' show Handler, response;
import '../isolation_test.dart' show MemorySecret, tokens;

void main() {
  test('服务端契约夹具：整包收完前无结果；作用域失效丢弃延迟响应', () async {
    final dir = await Directory.systemTemp.createTemp();
    addTearDown(() => dir.delete(recursive: true));
    final sessions = Sessions(MemorySecret(), dir);
    final scope = await sessions.activate(tokens('fixture'));
    final wire = Handler();
    final repo = ReplyService(
      AppApi(Uri.https('offline.invalid'), wire, sessions),
      scope,
    );
    const id = '85b72033-9f07-4bbc-8567-fc31f26508ab';
    const input = {'request_id': id, 'chat_text': '合成文字'};
    final examples = jsonDecode(
      await File('assets/contract_examples.json').readAsString(),
    );
    final bytes = utf8.encode(jsonEncode(examples['createReply']));
    final stream = StreamController<List<int>>();
    addTearDown(stream.close);
    wire.handle = (op, req) async {
      expect(op, AppOp.createReply);
      expect(req.url.path, '/v1/replies');
      expect(jsonDecode(utf8.decode(req.bodyBytes)), input);
      return http.StreamedResponse(
        stream.stream,
        200,
        headers: {'content-type': 'application/json'},
      );
    };
    ReplyResult? visible;
    final answer = repo.analyze(input).then((r) => visible = r);
    stream.add(bytes.sublist(0, bytes.length - 1));
    await Future<void>.delayed(Duration.zero);
    expect(visible, isNull);
    stream.add(bytes.sublist(bytes.length - 1));
    await stream.close();
    expect(await answer, isA<Approved>());
    wire.handle = (op, req) async => response(examples['createReply'], 202);
    expect(await repo.analyze(input), isA<NoResult>());
    final lateResult = Completer<http.StreamedResponse>();
    final started = Completer<void>();
    wire.handle = (op, req) {
      started.complete();
      return lateResult.future;
    };
    final pending = expectLater(
      repo.analyze(input),
      throwsA(isA<SessionChanged>()),
    );
    await started.future;
    await sessions.clear();
    lateResult.complete(response(examples['createReply']));
    await pending;
  });
  test('超 32 KiB 最终 JSON 在传输前拒绝', () async {
    final dir = await Directory.systemTemp.createTemp();
    addTearDown(() => dir.delete(recursive: true));
    final sessions = Sessions(MemorySecret(), dir);
    final scope = await sessions.activate(tokens('fixture'));
    final wire = Handler();
    final repo = ReplyService(
      AppApi(Uri.https('offline.invalid'), wire, sessions),
      scope,
    );
    var sent = false;
    wire.handle = (op, req) async {
      sent = true;
      throw StateError('oversized request reached transport');
    };
    const id = '85b72033-9f07-4bbc-8567-fc31f26508ab';
    // 11,000 non-ASCII characters are over 32 KiB after UTF-8 encoding.
    final text = List.filled(11000, '中').join();

    await expectLater(
      repo.analyze({'request_id': id, 'chat_text': text}),
      throwsA(isA<ReplyInputTooLarge>()),
    );
    expect(sent, isFalse);
  });
  test('429 额度查询读取 feature=reply 的剩余次数和重置时间', () async {
    final dir = await Directory.systemTemp.createTemp();
    addTearDown(() => dir.delete(recursive: true));
    final sessions = Sessions(MemorySecret(), dir);
    final scope = await sessions.activate(tokens('fixture'));
    final wire = Handler();
    wire.handle = (op, req) async {
      expect(op, AppOp.getEntitlements);
      expect(req.method, 'GET');
      expect(req.url.path, '/v1/entitlements');
      return response({
        'allowances': [
          {
            'feature': 'other',
            'remaining': 9,
            'resets_at': '2026-11-24T00:00:00+08:00',
          },
          {
            'feature': 'reply',
            'remaining': 0,
            'resets_at': '2026-11-23T00:00:00+08:00',
          },
        ],
      });
    };
    final repo = ReplyService(
      AppApi(Uri.https('offline.invalid'), wire, sessions),
      scope,
    );

    final quota = await repo.quota();
    expect(quota?.remaining, 0);
    expect(quota?.resetsAt, DateTime.parse('2026-11-23T00:00:00+08:00'));
  });
  test('反馈报文默认省略 self_report；显式本人确认才发送', () async {
    final dir = await Directory.systemTemp.createTemp();
    addTearDown(() => dir.delete(recursive: true));
    final sessions = Sessions(MemorySecret(), dir);
    final scope = await sessions.activate(tokens('fixture'));
    final wire = Handler();
    final bodies = <Json>[];
    wire.handle = (op, req) async {
      expect(op, AppOp.rateReply);
      expect(req.url.path, '/v1/replies/reply-id/feedback');
      bodies.add(jsonDecode(req.body) as Json);
      return response({'ok': true});
    };
    final repo = ReplyService(
      AppApi(Uri.https('offline.invalid'), wire, sessions),
      scope,
    );

    await repo.feedback('reply-id', 0, '更清楚了');
    await repo.feedback('reply-id', 1, '更清楚了', 'not_overwhelmed');

    expect(bodies[0], {'index': 0, 'outcome': '更清楚了'});
    expect(bodies[1], {
      'index': 1,
      'outcome': '更清楚了',
      'self_report': 'not_overwhelmed',
    });
  });
}
