import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/providers.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/main.dart';
import '../client_test.dart' show Handler;
import '../isolation_test.dart' show MemorySecret, tokens;

class _EntrySessions extends Sessions {
  _EntrySessions(this.known) : super(MemorySecret(), Directory.systemTemp);
  final AccountScope known;
  final cache = <String, List<int>>{};
  @override
  Future<AccountScope> activate(Tokens _) async {
    (identity as ValueNotifier<AccountScope?>).value = known;
    return known;
  }

  @override
  Tokens require(AccountScope scope) {
    if (!identical(scope, active)) throw SessionChanged();
    return tokens(scope.account);
  }

  @override
  Future<List<int>?> get(AccountScope _, CacheKind kind, String id) async =>
      cache['${kind.name}:$id'];

  @override
  Future<void> put(
    AccountScope _,
    CacheKind kind,
    String id,
    List<int> bytes,
  ) async {
    cache['${kind.name}:$id'] = bytes;
  }

  @override
  Future<void> remove(AccountScope _, CacheKind kind, String id) async {
    cache.remove('${kind.name}:$id');
  }

  @override
  Future<void> clear() async {
    (identity as ValueNotifier<AccountScope?>).value = null;
    cache.clear();
  }
}

Future<_EntrySessions> _entrySessions(WidgetTester t) async {
  final scope = await t.runAsync(() async {
    final dir = await Directory.systemTemp.createTemp();
    try {
      return await Sessions(
        MemorySecret(),
        dir,
      ).activate(tokens('synthetic-A'));
    } finally {
      await dir.delete(recursive: true);
    }
  });
  return _EntrySessions(scope!);
}

class _RouteApi extends AppApi {
  _RouteApi(super.origin, super.transport, super.sessions, this.samples);
  final Json samples;
  final ops = <AppOp>[];
  final analyzeBodies = <Json>[];
  var chatImportGranted = false;

  Json _consent() => {
    'purpose': 'chat_import',
    'version': '2026-11',
    'granted': chatImportGranted,
    'updated_at': '2026-11-21T09:00:00+08:00',
  };

  @override
  Future<Json> json(
    AppOp op, {
    AccountScope? scope,
    Map<String, String> path = const {},
    Map<String, String> query = const {},
    Json? body,
  }) async {
    ops.add(op);
    switch (op) {
      case AppOp.listConsents:
        return {
          'items': chatImportGranted ? [_consent()] : <Json>[],
          'next_cursor': null,
        };
      case AppOp.setConsent:
        chatImportGranted = body?['granted'] == true;
        return _consent();
      default:
        return samples[op.name] as Json;
    }
  }

  @override
  Stream<List<int>> bytes(
    AppOp op, {
    AccountScope? scope,
    Map<String, String> path = const {},
    Map<String, String> query = const {},
    Json? body,
    void Function()? beforeSend,
    void Function(int)? onStatus,
  }) {
    beforeSend?.call();
    ops.add(op);
    if (op != AppOp.createReply || body == null) {
      throw StateError('unexpected streamed route: ${op.name}');
    }
    analyzeBodies.add(body);
    onStatus?.call(202);
    return Stream.value(
      utf8.encode(
        jsonEncode({'request_id': body['request_id'], 'status': 'in_progress'}),
      ),
    );
  }
}

({_RouteApi api, List<AppOp> ops, List<Json> analyzeBodies}) syntheticApi(
  Sessions sessions,
  Json samples,
) {
  final transport = Handler()
    ..handle = (op, _) async =>
        throw StateError('unexpected transport: ${op.name}');
  final api = _RouteApi(
    Uri.https('offline.invalid'),
    transport,
    sessions,
    samples,
  );
  return (api: api, ops: api.ops, analyzeBodies: api.analyzeBodies);
}

void main() {
  testWidgets('真实路由：从合成分享进入登录，切换身份前后不自动分析', (t) async {
    final sessions = await _entrySessions(t);
    final samples = jsonDecode(
      File('assets/contract_examples.json').readAsStringSync(),
    );
    final synthetic = syntheticApi(sessions, samples);
    const channel = MethodChannel('cn.higheq/reply-share');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    String? next = '合成分享文字';
    messenger.setMockMethodCallHandler(channel, (call) async {
      final value = next;
      next = null;
      return value;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await t.pumpWidget(
      ProviderScope(
        overrides: [apiProvider.overrideWith((ref) => synthetic.api)],
        child: const HighEqApp(),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('隐私政策与用户协议'), findsOneWidget);
    expect(find.text('合成分享文字'), findsNothing);
    expect(find.text('分享已暂存，登录后可编辑'), findsOneWidget);
    expect(synthetic.ops, isEmpty);
    await t.runAsync(() => sessions.activate(tokens('synthetic-A')));
    await t.pumpAndSettle();
    expect(find.text('回复助手'), findsOneWidget);
    expect(find.text('合成分享文字'), findsOneWidget);
    expect(find.text('首次导入说明'), findsOneWidget);
    expect(synthetic.ops, isNot(contains(AppOp.createReply)));
    expect(synthetic.analyzeBodies, isEmpty);
    await t.tap(find.text('暂不导入'));
    for (
      var i = 0;
      i < 20 && find.text('是否同意开始本次自评？').evaluate().isEmpty;
      i++
    ) {
      await t.pump(const Duration(milliseconds: 100));
    }
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('回复助手'), findsNothing);
    expect(find.text('合成分享文字'), findsNothing);
    expect(find.text('是否同意开始本次自评？'), findsOneWidget);
    await t.runAsync(() => sessions.clear());
    await t.pumpAndSettle();
    expect(find.text('合成分享文字'), findsNothing);
    expect(find.text('分享已暂存，登录后可编辑'), findsNothing);
  });
  testWidgets('登录后热分享压入新页面，关闭后保留原请求与 202 操作', (t) async {
    final sessions = await _entrySessions(t);
    final samples = jsonDecode(
      File('assets/contract_examples.json').readAsStringSync(),
    );
    final synthetic = syntheticApi(sessions, samples);
    const channel = MethodChannel('cn.higheq/reply-share');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    String? next = '第一条冷分享';
    messenger.setMockMethodCallHandler(channel, (call) async {
      final value = next;
      next = null;
      return value;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await t.pumpWidget(
      ProviderScope(
        overrides: [apiProvider.overrideWith((ref) => synthetic.api)],
        child: const HighEqApp(),
      ),
    );
    await t.pumpAndSettle();
    await t.runAsync(() => sessions.activate(tokens('synthetic-A')));
    await t.pumpAndSettle();
    await t.tap(find.text('同意导入说明'));
    await t.pumpAndSettle();
    await t.tap(find.text('开始分析'));
    await t.pumpAndSettle();
    expect(synthetic.analyzeBodies, hasLength(1));
    final originalId = synthetic.analyzeBodies.single['request_id'];
    expect(find.text('查看原请求结果'), findsOneWidget);

    next = '第二条热分享';
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('available'),
      ),
      (_) {},
    );
    await t.pumpAndSettle();
    expect(find.text('第二条热分享'), findsOneWidget);
    expect(find.text('第一条冷分享'), findsNothing);

    await t.tap(find.byType(CloseButton));
    await t.pumpAndSettle();
    expect(find.text('第一条冷分享'), findsOneWidget);
    expect(find.text('查看原请求结果'), findsOneWidget);
    expect(synthetic.analyzeBodies.single['request_id'], originalId);
  });
}
