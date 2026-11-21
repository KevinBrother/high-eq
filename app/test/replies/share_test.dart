import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/features/replies/share_host.dart';
import '../isolation_test.dart' show MemorySecret, tokens;

void main() {
  testWidgets('合成冷分享待登录；热分享只消费一次；退出时清除', (t) async {
    final tmp = Directory.systemTemp.createTempSync();
    addTearDown(() => tmp.deleteSync(recursive: true));
    final sessions = Sessions(MemorySecret(), tmp);
    const channel = MethodChannel('cn.higheq/reply-share');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    String? next = '冷分享';
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'take');
      final value = next;
      next = null;
      return value;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await t.pumpWidget(
      MaterialApp(
        home: ShareHost(
          sessions,
          (scope, draft, rev, close) =>
              Text(scope == null ? '先登录' : draft ?? '无草稿'),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('先登录'), findsOneWidget);
    expect(find.text('冷分享'), findsNothing);
    await t.runAsync(() => sessions.activate(tokens('fixture-A')));
    await t.pumpAndSettle();
    expect(find.text('冷分享'), findsOneWidget);
    next = '热分享';
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('available'),
      ),
      (_) {},
    );
    await t.pumpAndSettle();
    expect(find.text('热分享'), findsOneWidget);
    await t.runAsync(() => sessions.clear());
    await t.runAsync(() => sessions.activate(tokens('fixture-B')));
    await t.pumpAndSettle();
    expect(find.text('无草稿'), findsOneWidget);
  });
}
