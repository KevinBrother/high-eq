import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq_admin/core/api.dart';
import 'package:high_eq_admin/features/workspace/shell.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Future<void> open(
  WidgetTester t,
  String path,
  Future<http.Response> Function(http.Request) handler,
) async {
  await t.binding.setSurfaceSize(const Size(1200, 1800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        apiProvider.overrideWithValue(
          AdminApi(MockClient(handler), Uri.parse('https://test.invalid')),
        ),
      ],
      child: MaterialApp(
        home: Workspace(
          path: path,
          session: Session('ops', 'operator', DateTime(2030)),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

http.Response response(Object data) =>
    http.Response.bytes(utf8.encode(jsonEncode(data)), 200);
void main() {
  testWidgets('运营从真实入口读取存量，编辑生成新版本，发布与回滚各一次写入', (t) async {
    final versions = [
      {'id': 'old', 'version': 1, 'template': '合成模板 A'},
    ];
    Map<String, dynamic>? release;
    final writes = <Map<String, dynamic>>[];
    await open(t, '/prompts', (r) async {
      expect(r.headers['Authorization'], 'Bearer ops');
      final path = r.url.pathSegments.last;
      if (r.method == 'POST') {
        expect(path, 'prompt-versions');
        final body = jsonDecode(r.body);
        final v = {
          'id': 'new',
          'version': 2,
          'template': body['template'] as String,
        };
        versions.insert(0, v);
        return response(v);
      }
      if (r.method == 'PUT') {
        expect(path, 'prompt-releases');
        release = jsonDecode(r.body);
        writes.add({...release!});
        return response(release!);
      }
      final items = switch (path) {
        'prompt-models' => [
          {'id': 'm', 'name': '生成目标', 'enabled': true},
        ],
        'prompt-versions' => versions,
        'prompt-releases' => [?release],
        _ => throw StateError('unexpected endpoint'),
      };
      return response({'items': items, 'next_cursor': null});
    });
    expect(find.text('合成模板 A'), findsOneWidget);
    await t.enterText(find.byType(TextField), '合成模板 B');
    await t.tap(find.text('保存为新版本'));
    await t.pumpAndSettle();
    expect(versions.length, 2);
    expect(writes, isEmpty);
    expect(find.text('两版正文不同'), findsOneWidget);
    Future<void> tap(String s) async {
      final f = find.text(s).last;
      await t.ensureVisible(f);
      await t.tap(f);
      await t.pumpAndSettle();
    }

    await tap('不分流');
    await tap('v1');
    await tap('发布所选版本');
    expect(writes.single, {
      'task': 'role_play',
      'model_id': 'm',
      'primary_version_id': 'new',
      'experiment_version_id': 'old',
      'experiment_percent': 10,
    });
    await tap('回滚到 v1');
    expect(writes.length, 2);
    expect(writes.last['primary_version_id'], 'old');
    expect(writes.last['experiment_version_id'], isNull);
    expect(writes.last['experiment_percent'], 0);
  });
  testWidgets('提示词页展示任务变量并在提交前拒绝不支持变量', (t) async {
    var posts = 0;
    await open(t, '/prompts', (r) async {
      final path = r.url.pathSegments.last;
      if (r.method == 'POST') {
        posts++;
        return response({
          'id': 'new',
          'version': 2,
          'template': jsonDecode(r.body)['template'],
        });
      }
      final items = switch (path) {
        'prompt-models' => [
          {'id': 'm', 'name': '生成目标', 'enabled': true},
        ],
        'prompt-versions' => [
          {'id': 'old', 'version': 1, 'template': '请围绕 {{scene}} 展开练习。'},
        ],
        'prompt-releases' => <Object>[],
        _ => throw StateError('unexpected endpoint'),
      };
      return response({'items': items, 'next_cursor': null});
    });

    expect(find.textContaining('可用变量：{{scene}}'), findsOneWidget);
    await t.enterText(find.byType(TextField), '请结合 {{profile}} 回答。');
    await t.tap(find.text('保存为新版本'));
    await t.pumpAndSettle();

    expect(posts, 0);
    expect(find.textContaining('不支持变量 {{profile}}'), findsOneWidget);
    expect(find.textContaining('{{scene}}'), findsWidgets);
  });
  testWidgets('看板显示查询值并区分缺价和数值投影缺失', (t) async {
    await open(t, '/metrics', (r) async {
      expect(r.url.path, '/admin/v1/metrics');
      expect(
        r.url.queryParameters.keys,
        containsAll(['from', 'until', 'limit']),
      );
      return response({
        'items': [
          {
            'task': 'scoring',
            'model_id': 'model',
            'prompt_version_id': 'v',
            'calls': 6,
            'mean_latency_ms': 50,
            'failure_rate': 1 / 6,
            'failures': 1,
            'cost_cny': 0.625,
            'unpriced_calls': 1,
            'missing_score_values': 1,
            'score_distribution': [
              {'nvc_total': 74, 'count': 2},
            ],
          },
        ],
        'next_cursor': null,
      });
    });
    expect(find.text('调用 6 次'), findsOneWidget);
    expect(find.textContaining('已知成本 ¥0.62500000'), findsOneWidget);
    expect(find.textContaining('未知成本 1 次'), findsOneWidget);
    expect(find.text('74 分'), findsOneWidget);
    expect(find.text('2 份'), findsOneWidget);
    expect(find.textContaining('尚无数值投影：1'), findsOneWidget);
  });
  testWidgets('提示词页显示后台 400 的固定诊断文案', (t) async {
    var posts = 0;
    await open(t, '/prompts', (request) async {
      final path = request.url.pathSegments.last;
      if (request.method == 'POST') {
        posts++;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'code': 'invalid_argument',
              'message': '提示词模板语法无效或超过 64 KiB',
              'retryable': false,
            }),
          ),
          400,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      final items = switch (path) {
        'prompt-models' => [
          {'id': 'm', 'name': '生成目标', 'enabled': true},
        ],
        'prompt-versions' => [
          {'id': 'old', 'version': 1, 'template': '旧模板'},
        ],
        'prompt-releases' => <Object>[],
        _ => throw StateError('unexpected endpoint'),
      };
      return response({'items': items, 'next_cursor': null});
    });

    await t.enterText(find.byType(TextField), '请围绕 {{scene}} 展开练习。');
    await t.tap(find.text('保存为新版本'));
    await t.pumpAndSettle();

    expect(posts, 1);
    expect(find.text('提示词模板语法无效或超过 64 KiB'), findsOneWidget);
  });
}
