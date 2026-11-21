import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq_admin/core/api.dart';
import 'package:high_eq_admin/features/workspace/shell.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('手输模型路由：运营角色不发起敏感读取', (t) async {
    await t.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Workspace(
            path: '/models',
            session: Session('demo', 'operator', DateTime(2030)),
          ),
        ),
      ),
    );
    expect(find.text('当前角色无权管理模型'), findsOneWidget);
    expect(find.text('新增模型'), findsNothing);
  });
  testWidgets('加载失败可重试；无凭据不允许创建模型，七类路由可见', (t) async {
    var ready = false;
    final retried = AdminApi(
      MockClient((req) async {
        expect(req.headers['Authorization'], 'Bearer demo');
        return ready
            ? http.Response(jsonEncode({'items': [], 'next_cursor': null}), 200)
            : http.Response('', 500);
      }),
      Uri.parse('https://admin.invalid'),
    );
    await t.pumpWidget(
      ProviderScope(
        overrides: [apiProvider.overrideWithValue(retried)],
        child: MaterialApp(
          home: Workspace(
            path: '/models',
            session: Session('demo', 'super_admin', DateTime(2030)),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('重新加载'), findsOneWidget);
    ready = true;
    await t.tap(find.text('重新加载'));
    await t.pumpAndSettle();
    expect(
      t
          .widget<FilledButton>(
            find.ancestor(
              of: find.text('新增模型'),
              matching: find.byWidgetPredicate((w) => w is FilledButton),
            ),
          )
          .onPressed,
      isNull,
    );
    await t.tap(find.text('任务路由'));
    await t.pumpAndSettle();
    expect(find.text('角色扮演'), findsOneWidget);
    await t.tap(find.text('配置路由').first);
    await t.pumpAndSettle();
    expect(find.text('审核模型'), findsOneWidget);
  });
  testWidgets('更换主模型后提交受权路由并刷新清单', (t) async {
    final route = <String, dynamic>{
      'task': 'role_play',
      'primary_model': 'one',
      'fallback_model': 'backup',
      'moderation_model': 'review',
      'canary_model': null,
      'canary_percent': 0,
    };
    int writes = 0;
    final api = AdminApi(
      MockClient((r) async {
        final path = r.url.pathSegments.last;
        expect(r.headers['Authorization'], 'Bearer demo');
        if (r.method == 'PUT') {
          expect(r.url.path, '/admin/v1/routes/role_play');
          final v = jsonDecode(r.body) as Map<String, dynamic>;
          expect(v, {
            ...(Map.of(route)..remove('task')),
            'primary_model': 'two',
          });
          route.addAll(v);
          writes++;
          return http.Response(jsonEncode(route), 200);
        }
        final items = switch (path) {
          'admissions' => [
            {'ref': 'proof'},
          ],
          'models' => [
            for (final id in ['one', 'two', 'backup', 'review'])
              {
                'id': id,
                'name': id,
                'provider': 'demo',
                'model_name': id,
                'endpoint': 'fixture',
                'enabled': true,
                'key_last_four': '1234',
                'admission_ref': 'proof',
                'kind': id == 'review' ? 'moderation' : 'model',
                'input_cny_per_million': 1,
                'output_cny_per_million': 2,
              },
          ],
          _ => [route],
        };
        return http.Response(
          jsonEncode({'items': items, 'next_cursor': null}),
          200,
        );
      }),
      Uri.parse('https://admin.invalid'),
    );
    await t.pumpWidget(
      ProviderScope(
        overrides: [apiProvider.overrideWithValue(api)],
        child: MaterialApp(
          home: Workspace(
            path: '/models',
            session: Session('demo', 'super_admin', DateTime(2030)),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('任务路由'));
    await t.pumpAndSettle();
    await t.tap(find.text('配置路由').first);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('primary_model:one')));
    await t.pumpAndSettle();
    await t.tap(find.text('two · two').last);
    await t.pumpAndSettle();
    final save = find.text('保存配置');
    await t.ensureVisible(save);
    await t.tap(save);
    await t.pumpAndSettle();
    expect(writes, 1);
    expect(find.textContaining('主：two'), findsOneWidget);
  });
}
