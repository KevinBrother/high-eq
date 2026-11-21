import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:high_eq_admin/main.dart';
import 'package:high_eq_admin/core/api.dart';

void main() {
  for (final role in ['operator', 'super_admin']) {
    testWidgets('$role 登录、筛选权限与退出', (t) async {
      final calls = <http.Request>[];
      final api = AdminApi(
        MockClient((r) async {
          calls.add(r);
          dynamic result = {'ok': true};
          if (r.url.path.endsWith('/login')) {
            result = {
              'role': role,
              'access_token': 'session',
              'expires_at': DateTime.now()
                  .toUtc()
                  .add(const Duration(hours: 1))
                  .toIso8601String(),
            };
          }
          if (r.url.path.endsWith('/audit-logs')) {
            result = {'items': [], 'next_cursor': null};
          }
          return http.Response.bytes(utf8.encode(jsonEncode(result)), 200);
        }),
        Uri.parse('https://local.test'),
      );
      await t.pumpWidget(
        ProviderScope(
          overrides: [apiProvider.overrideWithValue(api)],
          child: const AdminApp(),
        ),
      );
      await t.enterText(find.byType(TextFormField).at(0), 'ops');
      await t.enterText(find.byType(TextFormField).at(1), 'synthetic');
      await t.tap(find.text('登录'));
      await t.pumpAndSettle();
      expect(find.text('工作台'), findsWidgets);
      if (role == 'operator') {
        expect(find.text('审计记录'), findsNothing);
      } else {
        await t.tap(find.text('审计记录').first);
        await t.pumpAndSettle();
        expect(find.text('没有符合条件的记录'), findsOneWidget);
        expect(calls.last.headers['Authorization'], 'Bearer session');
        final before = calls.length;
        await t.enterText(find.byType(TextFormField), 'not-a-uuid');
        await t.tap(find.text('查询'));
        await t.pumpAndSettle();
        expect(find.text('请输入完整 UUID'), findsOneWidget);
        expect(calls.length, before);
        const actor = '85b72033-9f07-4bbc-8567-fc31f26508ab';
        await t.enterText(find.byType(TextFormField), actor);
        await t.tap(find.text('查询'));
        await t.pumpAndSettle();
        expect(calls.last.url.queryParameters['actor_id'], actor);
        await t.tap(find.text('重置'));
        await t.pumpAndSettle();
        expect(calls.last.url.queryParameters.containsKey('actor_id'), false);
      }
      await t.tap(find.byTooltip('退出登录').first);
      await t.pumpAndSettle();
      expect(find.text('登录'), findsOneWidget);
      expect(calls.last.url.path, '/admin/v1/auth/logout');
    });
  }
}
