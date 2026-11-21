import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/contacts/models.dart';
import 'package:high_eq/features/replies/page.dart';
import 'package:high_eq/features/replies/repository.dart';
import 'package:high_eq/features/replies/result.dart';
import '../client_test.dart' show Handler, response;
import '../isolation_test.dart' show MemorySecret, tokens;

class Fixture implements ReplyRepository {
  final calls = <Json>[];
  final ratings =
      <({String id, int index, String outcome, String? selfReport})>[];
  var allowedCalls = 0;
  var consent = false;
  var available = <Contact>[];
  ReplyQuota? quotaValue;
  Object? quotaFailure;
  Object? feedbackFailure;
  Object? contactsFailure;
  Future<ReplyResult> Function(Json)? analyzeWith;
  late Completer<ReplyResult> response;
  @override
  Future<bool> allowed() async {
    allowedCalls++;
    return consent;
  }

  @override
  Future<void> grant() async {
    consent = true;
  }

  @override
  Future<List<Contact>> contacts() async {
    if (contactsFailure != null) throw contactsFailure!;
    return List.of(available);
  }

  @override
  Future<ReplyQuota?> quota() async {
    if (quotaFailure != null) throw quotaFailure!;
    return quotaValue;
  }

  @override
  Future<ReplyResult> analyze(Json input) {
    calls.add(input);
    final delegate = analyzeWith;
    if (delegate != null) return delegate(input);
    response = Completer();
    return response.future;
  }

  @override
  Future<void> feedback(
    String id,
    int index,
    String outcome, [
    String? selfReport,
  ]) async {
    if (feedbackFailure != null) throw feedbackFailure!;
    ratings.add((
      id: id,
      index: index,
      outcome: outcome,
      selfReport: selfReport,
    ));
  }
}

Contact person(String id, String name) => Contact.fromJson({
  'id': id,
  'nickname': name,
  'scene': 'work',
  'editable': true,
  'profile': <String, Object?>{},
});

Future<void> tap(WidgetTester t, String label) async {
  final f = find.text(label);
  await t.ensureVisible(f);
  await t.tap(f);
  await t.pump();
}

Future<ReplyService> wireReply(Handler wire) async {
  final dir = await Directory.systemTemp.createTemp();
  addTearDown(() => dir.delete(recursive: true));
  final sessions = Sessions(MemorySecret(), dir);
  final scope = await sessions.activate(tokens('fixture'));
  return ReplyService(
    AppApi(Uri.https('offline.invalid'), wire, sessions),
    scope,
  );
}

Future<void> settleWire(WidgetTester t) async {
  await t.runAsync(() => Future<void>.delayed(Duration.zero));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('分享只填草稿；授权不发送；503、202、危机同键重试，修改后新键', (t) async {
    final f = Fixture();
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成分享')));
    await t.pumpAndSettle();
    expect(find.text('合成分享'), findsOneWidget);
    expect(f.calls, isEmpty);
    expect(
      t
          .widget<FilledButton>(find.widgetWithText(FilledButton, '开始分析'))
          .onPressed,
      isNull,
    );
    await tap(t, '同意导入说明');
    await t.pumpAndSettle();
    expect(f.calls, isEmpty);
    await tap(t, '开始分析');
    expect(f.calls.length, 1);
    expect(find.textContaining('待整份审核'), findsOneWidget);
    f.response.completeError(
      const ApiFailure(503, 'moderation_unavailable', '未审核片段', true),
    );
    await t.pumpAndSettle();
    expect(find.text('服务暂不可用，可重试'), findsOneWidget);
    expect(find.text('未审核片段'), findsNothing);
    expect(find.textContaining('12356'), findsNothing);
    await tap(t, '重试原请求');
    f.response.complete(Processing());
    await t.pumpAndSettle();
    await tap(t, '查看原请求结果');
    f.response.complete(Crisis());
    await t.pumpAndSettle();
    expect(f.calls.toSet().length, 1);
    expect(find.textContaining('12356'), findsOneWidget);
    expect(find.text('复制建议'), findsNothing);
    final field = find.byType(TextField).first;
    await t.ensureVisible(field);
    await t.enterText(field, '新的合成内容');
    await t.pumpAndSettle();
    expect(find.textContaining('12356'), findsNothing);
    await tap(t, '开始分析');
    expect(f.calls.last['request_id'], isNot(f.calls.first['request_id']));
    f.response.complete(NoResult());
    await t.pumpAndSettle();
    expect(find.textContaining('暂无完整'), findsOneWidget);
  });
  testWidgets('只复制主动选中的建议；反馈使用零基下标', (t) async {
    final f = Fixture()..consent = true;
    final copied = <Object?>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add(call.arguments['text']);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '示例')));
    await t.pumpAndSettle();
    await tap(t, '开始分析');
    f.response.complete(
      Approved('reply', '可能着急', '想了解进度', [
        (style: '直接', text: '周三交稿。', reason: '具体时间'),
        (style: '确认', text: '想先看提纲吗？', reason: '留出选择'),
      ]),
    );
    await t.pumpAndSettle();
    // With eager children in the viewport, locate both suggestion actions.
    await t.drag(find.byType(ListView), const Offset(0, -800));
    await t.pumpAndSettle();
    expect(copied, isEmpty);
    final copy = find.text('复制建议').last;
    await t.ensureVisible(copy);
    await t.tap(copy);
    await t.pump();
    expect(copied, ['想先看提纲吗？']);
    final use = find.text('我用了这条').last;
    await t.ensureVisible(use);
    await t.pumpAndSettle();
    await t.tap(use);
    await t.pumpAndSettle();
    final outcome = find.byType(TextField).last;
    await t.ensureVisible(outcome);
    await t.enterText(outcome, '更清楚了');
    await t.pumpAndSettle();
    await tap(t, '提交效果反馈');
    expect(f.ratings.single.index, 1);
    expect(f.ratings.single.outcome, '更清楚了');
    expect(f.ratings.single.selfReport, isNull);
  });
  testWidgets('提交前重新确认导入授权；撤回后不发送正文', (t) async {
    final f = Fixture()..consent = true;
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成授权文字')));
    await t.pumpAndSettle();
    expect(f.allowedCalls, 1);

    f.consent = false;
    await tap(t, '开始分析');
    await t.pump();

    expect(f.allowedCalls, 2);
    expect(f.calls, isEmpty);
    expect(find.text('首次导入说明'), findsOneWidget);
    expect(find.textContaining('导入授权已撤回'), findsOneWidget);
  });
  testWidgets('重试前重新确认导入授权；撤回后不重复发送', (t) async {
    final f = Fixture()..consent = true;
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成重试文字')));
    await t.pumpAndSettle();
    await tap(t, '开始分析');
    expect(f.calls.length, 1);
    f.response.completeError(
      const ApiFailure(503, 'moderation_unavailable', '未审核片段', true),
    );
    await t.pumpAndSettle();

    f.consent = false;
    await tap(t, '重试原请求');
    await t.pump();

    expect(f.allowedCalls, 3);
    expect(f.calls.length, 1);
    expect(find.text('首次导入说明'), findsOneWidget);
    expect(find.textContaining('导入授权已撤回'), findsOneWidget);
  });
  testWidgets('按最终 JSON 字节数阻止超限请求', (t) async {
    final f = Fixture()..consent = true;
    // The text itself is below 32 KiB, but the frozen JSON envelope is over it.
    final text = List.filled((32 << 10) - 60, 'a').join();
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: text)));
    await t.pumpAndSettle();

    await tap(t, '开始分析');
    await t.pump();

    expect(f.calls, isEmpty);
    expect(find.textContaining('内容过长'), findsOneWidget);
    expect(
      t
          .widget<FilledButton>(find.widgetWithText(FilledButton, '请先修改输入'))
          .onPressed,
      isNull,
    );
  });
  testWidgets('400 不显示断线文案，也不鼓励原样重试', (t) async {
    final f = Fixture()..consent = true;
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成格式错误')));
    await t.pumpAndSettle();
    await tap(t, '开始分析');
    f.response.completeError(
      const ApiFailure(400, 'invalid_argument', '合成错误正文', false),
    );
    await t.pumpAndSettle();

    expect(find.textContaining('请求内容不符合要求'), findsOneWidget);
    expect(find.textContaining('连接未完成'), findsNothing);
    expect(find.text('合成错误正文'), findsNothing);
    expect(
      t
          .widget<FilledButton>(find.widgetWithText(FilledButton, '请先修改输入'))
          .onPressed,
      isNull,
    );

    await t.enterText(find.byType(TextField).first, '修改后的合成内容');
    await t.pumpAndSettle();
    expect(
      t
          .widget<FilledButton>(find.widgetWithText(FilledButton, '开始分析'))
          .onPressed,
      isNotNull,
    );
  });
  testWidgets('仅改首尾空白时复用原请求 ID；真实内容变化才换 ID', (t) async {
    final f = Fixture()..consent = true;
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成原请求')));
    await t.pumpAndSettle();
    await tap(t, '开始分析');
    final first = Map<String, Object?>.from(f.calls.single);
    f.response.completeError(
      const ApiFailure(503, 'moderation_unavailable', '未审核片段', true),
    );
    await t.pumpAndSettle();

    await t.enterText(find.byType(TextField).first, '  合成原请求  ');
    await t.pumpAndSettle();
    expect(find.text('重试原请求'), findsOneWidget);
    await tap(t, '重试原请求');
    expect(f.calls.length, 2);
    expect(f.calls.last, first);

    f.response.completeError(
      const ApiFailure(503, 'moderation_unavailable', '未审核片段', true),
    );
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).first, '合成新的请求');
    await t.pumpAndSettle();
    await tap(t, '开始分析');
    expect(f.calls.length, 3);
    expect(f.calls.last['request_id'], isNot(first['request_id']));
    expect(f.calls.last['chat_text'], '合成新的请求');
    f.response.complete(NoResult());
    await t.pumpAndSettle();
  });
  testWidgets('409 后必须修改规范化内容才能继续', (t) async {
    final f = Fixture()..consent = true;
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成冲突请求')));
    await t.pumpAndSettle();
    await tap(t, '开始分析');
    f.response.completeError(
      const ApiFailure(409, 'conflict', '同键不同输入', false),
    );
    await t.pumpAndSettle();

    expect(find.textContaining('与原操作不一致'), findsOneWidget);
    expect(
      t
          .widget<FilledButton>(find.widgetWithText(FilledButton, '请先修改输入'))
          .onPressed,
      isNull,
    );
    await t.enterText(find.byType(TextField).first, ' 合成冲突请求 ');
    await t.pumpAndSettle();
    expect(
      t
          .widget<FilledButton>(find.widgetWithText(FilledButton, '请先修改输入'))
          .onPressed,
      isNull,
    );

    await t.enterText(find.byType(TextField).first, '合成冲突请求已修改');
    await t.pumpAndSettle();
    expect(
      t
          .widget<FilledButton>(find.widgetWithText(FilledButton, '开始分析'))
          .onPressed,
      isNotNull,
    );
  });
  testWidgets('非契约 500 不把结果误判为终止，可用原请求重试', (t) async {
    final f = Fixture()..consent = true;
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成网关错误')));
    await t.pumpAndSettle();
    await tap(t, '开始分析');
    final first = Map<String, Object?>.from(f.calls.single);
    f.response.completeError(
      const ApiFailure(500, 'unavailable', '暂时无法连接，请重试', false),
    );
    await t.pumpAndSettle();

    expect(find.textContaining('连接未完成'), findsOneWidget);
    expect(find.textContaining('本次分析已结束'), findsNothing);
    await tap(t, '重试原请求');
    expect(f.calls, hasLength(2));
    expect(f.calls.last, first);
    f.response.complete(NoResult());
    await t.pumpAndSettle();
  });
  testWidgets('T21 已确认终止的 500 不提示原请求可重试', (t) async {
    final f = Fixture()..consent = true;
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成终止失败')));
    await t.pumpAndSettle();
    await tap(t, '开始分析');
    final first = Map<String, Object?>.from(f.calls.single);
    f.response.completeError(
      const ApiFailure(500, 'internal_error', '生成已终止', false),
    );
    await t.pumpAndSettle();

    expect(find.textContaining('本次分析已结束'), findsOneWidget);
    expect(find.textContaining('连接未完成'), findsNothing);
    expect(find.text('重试原请求'), findsNothing);
    expect(find.text('查看原请求结果'), findsNothing);

    await t.enterText(find.byType(TextField).first, '合成终止后新请求');
    await t.pumpAndSettle();
    await tap(t, '开始分析');
    expect(f.calls, hasLength(2));
    expect(f.calls.last['request_id'], isNot(first['request_id']));
    f.response.complete(Processing());
    await t.pumpAndSettle();
  });
  testWidgets('完整终止 500 经真实 HTTP 解析后显示终止', (t) async {
    final wire = Handler();
    final bodies = <Json>[];
    wire.handle = (op, req) async {
      expect(op, AppOp.createReply);
      final body = jsonDecode(req.body) as Json;
      bodies.add(body);
      if (bodies.length == 1) {
        return response({
          'code': 'internal_error',
          'message': '生成已终止',
          'retryable': false,
        }, 500);
      }
      return response({
        'request_id': body['request_id'],
        'status': 'in_progress',
      }, 202);
    };
    final service = await t.runAsync(() => wireReply(wire));
    final f = Fixture()
      ..consent = true
      ..analyzeWith = service!.analyze;
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成完整终止')));
    await t.pumpAndSettle();

    await tap(t, '开始分析');
    await settleWire(t);

    expect(bodies, hasLength(1));
    expect(find.textContaining('本次分析已结束'), findsOneWidget);
    expect(find.textContaining('连接未完成'), findsNothing);
    expect(find.text('重试原请求'), findsNothing);
    expect(find.text('查看原请求结果'), findsNothing);
    expect(find.textContaining('成功'), findsNothing);
    expect(find.textContaining('扣次'), findsNothing);

    await t.enterText(find.byType(TextField).first, '合成终止后的新请求');
    await t.pumpAndSettle();
    await tap(t, '开始分析');
    await settleWire(t);

    expect(bodies, hasLength(2));
    expect(bodies.last['request_id'], isNot(bodies.first['request_id']));
    expect(find.text('查看原请求结果'), findsOneWidget);
  });
  testWidgets('retryable 缺失或错类型的 500 经真实 HTTP 解析后保留原请求', (t) async {
    final wire = Handler();
    final bodies = <Json>[];
    wire.handle = (op, req) async {
      expect(op, AppOp.createReply);
      final body = jsonDecode(req.body) as Json;
      bodies.add(body);
      if (bodies.length == 1) {
        return response({
          'code': 'internal_error',
          'message': 'upstream error',
        }, 500);
      }
      if (bodies.length == 2) {
        return response({
          'code': 'internal_error',
          'message': 'upstream error',
          'retryable': 'false',
        }, 500);
      }
      return response({
        'request_id': body['request_id'],
        'status': 'in_progress',
      }, 202);
    };
    final service = await t.runAsync(() => wireReply(wire));
    final f = Fixture()
      ..consent = true
      ..analyzeWith = service!.analyze;
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成未知结果')));
    await t.pumpAndSettle();

    await tap(t, '开始分析');
    await settleWire(t);

    expect(bodies, hasLength(1));
    expect(find.textContaining('连接未完成'), findsOneWidget);
    expect(find.textContaining('本次分析已结束'), findsNothing);
    expect(find.textContaining('成功'), findsNothing);
    expect(find.textContaining('扣次'), findsNothing);
    expect(find.text('重试原请求'), findsOneWidget);

    await tap(t, '重试原请求');
    await settleWire(t);

    expect(bodies, hasLength(2));
    expect(bodies.last['request_id'], bodies.first['request_id']);
    expect(find.textContaining('连接未完成'), findsOneWidget);
    expect(find.textContaining('本次分析已结束'), findsNothing);
    expect(find.text('重试原请求'), findsOneWidget);

    await tap(t, '重试原请求');
    await settleWire(t);

    expect(bodies, hasLength(3));
    expect(
      bodies.every((body) => body['request_id'] == bodies.first['request_id']),
      isTrue,
    );
    expect(find.text('查看原请求结果'), findsOneWidget);
  });
  testWidgets('429 显示当前剩余额度和权益重置时间', (t) async {
    final f = Fixture()..consent = true;
    final reset = DateTime.now().add(const Duration(hours: 3));
    f.quotaValue = (remaining: 0, resetsAt: reset);
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成额度请求')));
    await t.pumpAndSettle();
    await tap(t, '开始分析');
    f.response.completeError(
      const ApiFailure(429, 'quota_exceeded', '今日次数已用完', false),
    );
    await t.pumpAndSettle();

    expect(find.textContaining('剩余 0 次'), findsOneWidget);
    expect(find.textContaining('重置'), findsOneWidget);
    expect(find.text('今日次数已用完'), findsNothing);
  });
  testWidgets('429 额度查询失败时不编造重置时间', (t) async {
    final f = Fixture()
      ..consent = true
      ..quotaFailure = StateError('synthetic quota failure');
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成额度查询失败')));
    await t.pumpAndSettle();
    await tap(t, '开始分析');
    f.response.completeError(
      const ApiFailure(429, 'quota_exceeded', '今日次数已用完', false),
    );
    await t.pumpAndSettle();

    expect(find.textContaining('请按会员页显示的重置时间'), findsOneWidget);
    expect(find.textContaining('将在'), findsNothing);
    expect(find.text('今日次数已用完'), findsNothing);
  });
  testWidgets('关联关系人变为只读后关闭反馈入口且不发送 POST', (t) async {
    final f = Fixture()
      ..consent = true
      ..available = [person('85b72033-9f07-4bbc-8567-fc31f26508ab', '同事 A')];
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成关系人请求')));
    await t.pumpAndSettle();
    await t.tap(find.text('不关联关系人'));
    await t.pumpAndSettle();
    await t.tap(find.text('同事 A').last);
    await t.pumpAndSettle();
    await tap(t, '开始分析');
    f.response.complete(
      Approved('reply', '可能着急', '想了解进度', [
        (style: '直接', text: '周三交稿。', reason: '具体时间'),
        (style: '确认', text: '想先看提纲吗？', reason: '留出选择'),
      ]),
    );
    await t.pumpAndSettle();
    final use = find.text('我用了这条').first;
    await t.ensureVisible(use);
    await t.pumpAndSettle();
    await t.tap(use);
    await t.pumpAndSettle();
    final outcome = find.byType(TextField).last;
    await t.ensureVisible(outcome);
    await t.enterText(outcome, '更清楚了');
    await t.pumpAndSettle();

    f.available = [];
    await tap(t, '提交效果反馈');

    expect(f.ratings, isEmpty);
    expect(find.textContaining('只读'), findsOneWidget);
    expect(find.text('提交效果反馈'), findsNothing);
  });
  testWidgets('关联关系人分析前降权时不发送聊天正文', (t) async {
    final f = Fixture()
      ..consent = true
      ..available = [person('85b72033-9f07-4bbc-8567-fc31f26508ab', '同事 A')];
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成关系人请求')));
    await t.pumpAndSettle();
    await t.tap(find.text('不关联关系人'));
    await t.pumpAndSettle();
    await t.tap(find.text('同事 A').last);
    await t.pumpAndSettle();

    f.available = [];
    await tap(t, '开始分析');

    expect(f.calls, isEmpty);
    expect(find.textContaining('关系人权限已变更'), findsOneWidget);
    expect(find.text('请先修改输入'), findsOneWidget);
  });
  testWidgets('关系人权限查询失败时分析前不发送聊天正文', (t) async {
    final f = Fixture()
      ..consent = true
      ..available = [person('85b72033-9f07-4bbc-8567-fc31f26508ab', '同事 A')];
    await t.pumpWidget(
      MaterialApp(home: ReplyPage(f, sharedText: '合成关系人查询失败')),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('不关联关系人'));
    await t.pumpAndSettle();
    await t.tap(find.text('同事 A').last);
    await t.pumpAndSettle();

    f.contactsFailure = StateError('synthetic contacts failure');
    await tap(t, '开始分析');

    expect(f.calls, isEmpty);
    expect(find.textContaining('暂时无法确认关系人权限'), findsOneWidget);
    expect(find.text('请先修改输入'), findsOneWidget);
  });
  testWidgets('名册查询超时保留已有 202 原请求，恢复后原体重试', (t) async {
    final f = Fixture()
      ..consent = true
      ..available = [person('85b72033-9f07-4bbc-8567-fc31f26508ab', '同事 A')];
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成关系人待重试')));
    await t.pumpAndSettle();
    await t.tap(find.text('不关联关系人'));
    await t.pumpAndSettle();
    await t.tap(find.text('同事 A').last);
    await t.pumpAndSettle();

    await tap(t, '开始分析');
    final first = Map<String, Object?>.from(f.calls.single);
    f.response.complete(Processing());
    await t.pumpAndSettle();
    expect(find.text('查看原请求结果'), findsOneWidget);

    f.contactsFailure = StateError('synthetic contacts timeout');
    await tap(t, '查看原请求结果');

    expect(f.calls, hasLength(1));
    expect(find.textContaining('原请求已保留'), findsOneWidget);
    expect(find.text('请先修改输入'), findsNothing);
    expect(find.text('重试原请求'), findsOneWidget);

    f.contactsFailure = null;
    await tap(t, '重试原请求');
    expect(f.calls, hasLength(2));
    expect(f.calls.last, first);
    f.response.complete(Processing());
    await t.pumpAndSettle();
  });
  testWidgets('反馈 409 提示已有记录并关闭重试入口', (t) async {
    final f = Fixture()
      ..consent = true
      ..feedbackFailure = const ApiFailure(
        409,
        'conflict',
        '同一条回复不能再次修改反馈',
        false,
      );
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成反馈冲突')));
    await t.pumpAndSettle();
    await tap(t, '开始分析');
    f.response.complete(
      Approved('reply', '可能着急', '想了解进度', [
        (style: '直接', text: '周三交稿。', reason: '具体时间'),
        (style: '确认', text: '想先看提纲吗？', reason: '留出选择'),
      ]),
    );
    await t.pumpAndSettle();
    final use = find.text('我用了这条').first;
    await t.ensureVisible(use);
    await t.pumpAndSettle();
    await t.tap(use);
    await t.pumpAndSettle();
    final outcome = find.byType(TextField).last;
    await t.ensureVisible(outcome);
    await t.enterText(outcome, '更清楚了');
    await t.pumpAndSettle();

    await tap(t, '提交效果反馈');

    expect(find.textContaining('该回复已有反馈记录'), findsOneWidget);
    expect(find.textContaining('可重试'), findsNothing);
    expect(find.text('提交效果反馈'), findsNothing);
  });
  testWidgets('本人确认默认不选；只有显式选择才发送 self_report', (t) async {
    final f = Fixture()..consent = true;
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成本人确认')));
    await t.pumpAndSettle();
    await tap(t, '开始分析');
    f.response.complete(
      Approved('reply', '可能着急', '想了解进度', [
        (style: '直接', text: '周三交稿。', reason: '具体时间'),
        (style: '确认', text: '想先看提纲吗？', reason: '留出选择'),
      ]),
    );
    await t.pumpAndSettle();
    final use = find.text('我用了这条').first;
    await t.ensureVisible(use);
    await t.pumpAndSettle();
    await t.tap(use);
    await t.pumpAndSettle();
    final outcome = find.byType(TextField).last;
    await t.ensureVisible(outcome);
    await t.enterText(outcome, '更清楚了');
    await t.pumpAndSettle();

    final skip = t.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '不填写'));
    expect(skip.selected, isTrue);
    await t.tap(find.widgetWithText(ChoiceChip, '本人当时上头'));
    await t.pumpAndSettle();
    await tap(t, '提交效果反馈');

    expect(f.ratings.single.selfReport, 'overwhelmed');
  });
}
