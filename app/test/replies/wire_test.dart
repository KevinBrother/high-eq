import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/endpoints.g.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/contacts/purpose.dart';
import 'package:high_eq/features/replies/repository.dart';
import 'package:high_eq/features/replies/result.dart';
import 'package:http/http.dart' as http;
import '../client_test.dart' show Handler, response;
import '../isolation_test.dart' show MemorySecret, tokens;

const _allowedReply = {
  'items': [
    {
      'purpose': 'reply_chat_import',
      'version': '2026-11-reply',
      'granted': true,
      'decision_id': '90ed4318-470a-4ec1-8da5-b4798ee63a75',
      'updated_at': '2026-11-21T09:00:00+08:00',
    },
  ],
  'next_cursor': null,
};

void main() {
  test('两个进入顺序各自读取当前用途，旧版本和已撤回决定不能互相授权', () async {
    final dir = await Directory.systemTemp.createTemp();
    addTearDown(() => dir.delete(recursive: true));
    final sessions = Sessions(MemorySecret(), dir);
    final scope = await sessions.activate(tokens('fixture'));
    final wire = Handler();
    Json decision(String purpose, String version, {bool granted = true}) => {
      'purpose': purpose,
      'version': version,
      'granted': granted,
      'decision_id': '90ed4318-470a-4ec1-8da5-b4798ee63a75',
      'updated_at': '2026-11-21T09:00:00+08:00',
    };
    final contacts = decision('contacts', '2026-11');
    final contactImport = decision('chat_import', '2026-11');
    final replyImport = decision('reply_chat_import', '2026-11-reply');
    var items = [contacts, contactImport];
    wire.handle = (op, req) async {
      expect(op, AppOp.listConsents);
      expect(req.url.path, '/v1/me/consents');
      return response({'items': items, 'next_cursor': null});
    };
    final api = AppApi(Uri.https('offline.invalid'), wire, sessions);
    final reply = ReplyService(api, scope);
    final book = ContactDecisions(MobileEndpoints(api), scope);

    expect((await book.current()).grants, {
      ContactPurpose.contacts,
      ContactPurpose.chatImport,
    });
    expect(await reply.allowed(), isFalse);
    items = [contacts, contactImport, decision('reply_chat_import', '2026-11')];
    expect(await reply.allowed(), isFalse);
    items = [contacts, contactImport, replyImport];
    expect(await reply.allowed(), isTrue);
    items = [
      contacts,
      contactImport,
      {...replyImport, 'granted': false},
    ];
    expect(await reply.allowed(), isFalse);
    expect((await book.current()).grants, {
      ContactPurpose.contacts,
      ContactPurpose.chatImport,
    });
    items = [contacts, contactImport, replyImport];
    expect(await reply.allowed(), isTrue);

    items = [contacts, replyImport];
    expect(await reply.allowed(), isTrue);
    expect((await book.current()).grants, {ContactPurpose.contacts});
    items = [contacts, replyImport, decision('chat_import', 'legacy')];
    expect((await book.current()).grants, {ContactPurpose.contacts});
    items = [
      contacts,
      replyImport,
      {...contactImport, 'granted': false},
    ];
    expect((await book.current()).grants, {ContactPurpose.contacts});
    expect(await reply.allowed(), isTrue);
    items = [contacts, replyImport, contactImport];
    expect((await book.current()).grants, {
      ContactPurpose.contacts,
      ContactPurpose.chatImport,
    });
  });
  test('回复授权必须同时匹配专用用途和精确版本', () async {
    final dir = await Directory.systemTemp.createTemp();
    addTearDown(() => dir.delete(recursive: true));
    final sessions = Sessions(MemorySecret(), dir);
    final scope = await sessions.activate(tokens('fixture'));
    final wire = Handler();
    var version = '2026-11-reply';
    wire.handle = (op, req) async {
      expect(op, AppOp.listConsents);
      return response({
        'items': [
          {
            'purpose': 'reply_chat_import',
            'version': version,
            'granted': true,
            'decision_id': '90ed4318-470a-4ec1-8da5-b4798ee63a75',
            'updated_at': '2026-11-21T09:00:00+08:00',
          },
        ],
        'next_cursor': null,
      });
    };
    final repo = ReplyService(
      AppApi(Uri.https('offline.invalid'), wire, sessions),
      scope,
    );

    expect(await repo.allowed(), isTrue);
    version = '2026-11';
    expect(await repo.allowed(), isFalse);
  });
  test('回复同意写入专用用途和精确版本', () async {
    final dir = await Directory.systemTemp.createTemp();
    addTearDown(() => dir.delete(recursive: true));
    final sessions = Sessions(MemorySecret(), dir);
    final scope = await sessions.activate(tokens('fixture'));
    final wire = Handler();
    wire.handle = (op, req) async {
      expect(op, AppOp.setConsent);
      expect(req.method, 'PUT');
      expect(req.url.path, '/v1/me/consents/reply_chat_import');
      expect(jsonDecode(req.body), {
        'granted': true,
        'version': '2026-11-reply',
      });
      return response({
        'purpose': 'reply_chat_import',
        'version': '2026-11-reply',
        'granted': true,
        'updated_at': '2026-11-21T09:00:00+08:00',
      });
    };
    final repo = ReplyService(
      AppApi(Uri.https('offline.invalid'), wire, sessions),
      scope,
    );

    await repo.grant();
  });
  for (final receipt in [
    {
      'purpose': 'chat_import',
      'version': '2026-11-reply',
      'granted': true,
      'updated_at': '2026-11-21T09:00:00+08:00',
    },
    {
      'purpose': 'reply_chat_import',
      'version': '2026-11',
      'granted': true,
      'updated_at': '2026-11-21T09:00:00+08:00',
    },
  ]) {
    test(
      '回复同意回执的用途或版本不匹配时拒绝 ${receipt['purpose']}/${receipt['version']}',
      () async {
        final dir = await Directory.systemTemp.createTemp();
        addTearDown(() => dir.delete(recursive: true));
        final sessions = Sessions(MemorySecret(), dir);
        final scope = await sessions.activate(tokens('fixture'));
        final wire = Handler();
        wire.handle = (op, req) async => response(receipt);
        final repo = ReplyService(
          AppApi(Uri.https('offline.invalid'), wire, sessions),
          scope,
        );

        await expectLater(repo.grant(), throwsA(isA<FormatException>()));
      },
    );
  }
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
      if (op == AppOp.listConsents) return response(_allowedReply);
      expect(op, AppOp.createReply);
      expect(req.url.path, '/v1/replies');
      expect(jsonDecode(utf8.decode(req.bodyBytes)), {
        ...input,
        'reply_consent_id': '90ed4318-470a-4ec1-8da5-b4798ee63a75',
      });
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
    wire.handle = (op, req) async => op == AppOp.listConsents
        ? response(_allowedReply)
        : response(examples['createReply'], 202);
    expect(await repo.analyze(input), isA<NoResult>());
    final lateResult = Completer<http.StreamedResponse>();
    final started = Completer<void>();
    wire.handle = (op, req) async {
      if (op == AppOp.listConsents) return response(_allowedReply);
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
  test('计入授权 UUID 后超过 32 KiB 时不发送 POST', () async {
    final dir = await Directory.systemTemp.createTemp();
    addTearDown(() => dir.delete(recursive: true));
    final sessions = Sessions(MemorySecret(), dir);
    final scope = await sessions.activate(tokens('fixture'));
    final wire = Handler();
    final repo = ReplyService(
      AppApi(Uri.https('offline.invalid'), wire, sessions),
      scope,
    );
    final input = <String, Object?>{
      'request_id': '85b72033-9f07-4bbc-8567-fc31f26508ab',
      'chat_text': '',
    };
    input['chat_text'] =
        'x' * (replyRequestLimitBytes - utf8.encode(jsonEncode(input)).length);
    expect(replyInputFits(input), isTrue);
    var posts = 0;
    wire.handle = (op, req) async {
      if (op == AppOp.listConsents) return response(_allowedReply);
      posts++;
      return response({});
    };
    await expectLater(repo.analyze(input), throwsA(isA<ReplyInputTooLarge>()));
    expect(posts, 0);
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
