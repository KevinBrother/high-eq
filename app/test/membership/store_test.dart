import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/features/membership/store.dart';
import '../client_test.dart' show Handler, response;
import '../isolation_test.dart' show MemorySecret, tokens;

class _Port extends StorePort {
  _Port() : super(false);
  final calls = <Object>[];
  bool cancel = false;
  @override
  Future<void> available(String channel) async => calls.add(channel);
  @override
  Future<List<String>> apple(String? plan, String? token) async {
    calls.add((plan, token));
    return ['synthetic-jws'];
  }

  @override
  Future<void> finish(String signed) async => calls.add('finish');
  @override
  Future<void> android(String channel, String payload) async {
    calls.add((channel, payload));
    if (cancel) throw PlatformException(code: 'cancelled');
  }
}

void main() {
  late _Port port;
  late Handler http;
  late MemberStore store;
  late Sessions sessions;
  setUp(() async {
    final dir = await Directory.systemTemp.createTemp();
    addTearDown(() => dir.delete(recursive: true));
    sessions = Sessions(MemorySecret(), dir);
    final a = await sessions.activate(tokens('A'));
    port = _Port();
    http = Handler();
    store = MemberStore(
      AppApi(Uri.https('example.invalid'), http, sessions),
      a,
      port: port,
    );
  });
  test('购买带当前账号 token，恢复不重绑；409 不 finish、不换号', () async {
    const accountToken = 'c4836c1a-b65c-4239-8603-555fee954db2';
    bool conflict = false;
    final ops = <AppOp>[];
    http.handle = (op, req) async {
      ops.add(op);
      expect(req.headers['Authorization'], 'Bearer access');
      if (op == AppOp.getPurchaseToken) {
        return response({'app_account_token': accountToken});
      }
      expect(op, AppOp.restorePurchase);
      expect(jsonDecode(req.body), {'signed_transaction': 'synthetic-jws'});
      return conflict
          ? response({
              'code': 'conflict',
              'retryable': false,
              'message': '账号不符',
            }, 409)
          : response({'tier': 'member'});
    };
    expect(await store.apple(plan: 'yearly'), true);
    conflict = true;
    await expectLater(
      store.apple(),
      throwsA(isA<ApiFailure>().having((x) => x.status, 'status', 409)),
    );
    expect(ops, [
      AppOp.getPurchaseToken,
      AppOp.restorePurchase,
      AppOp.restorePurchase,
    ]);
    expect(port.calls, [
      'apple',
      ('yearly', accountToken),
      'finish',
      'apple',
      (null, null),
    ]);
    expect(sessions.active?.account, 'A');
  });
  test('安卓取消后使用同一账号同套餐的原 request_id；SDK 返回不授予权益', () async {
    final ids = <String>[];
    http.handle = (op, req) async {
      expect(op, AppOp.createOrder);
      final body = jsonDecode(req.body);
      expect(body['platform'], 'wechat');
      expect(body['product'], 'monthly');
      ids.add(body['request_id']);
      return response({
        'order_id': 'example',
        'payment_payload': 'signed-payload',
      });
    };
    port.cancel = true;
    await expectLater(
      store.android('wechat', 'monthly'),
      throwsA(isA<PlatformException>()),
    );
    port.cancel = false;
    await store.android('wechat', 'monthly');
    expect(ids.toSet(), hasLength(1));
    expect(port.calls, [
      'wechat',
      ('wechat', 'signed-payload'),
      'wechat',
      ('wechat', 'signed-payload'),
    ]);
  });
}
