import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq_admin/core/tasks.dart';

void main() {
  group('task template variables', () {
    test('official role-play template is accepted', () {
      expect(validateTaskTemplate('role_play', '请围绕 {{scene}} 展开练习。'), isNull);
      expect(
        validateTaskTemplate('role_play', '请围绕 {{  scene\t}} 展开练习。'),
        isNull,
      );
    });

    test('scoring accepts all variables supplied by its production calls', () {
      expect(
        validateTaskTemplate(
          'scoring',
          '评估 {{assessment}}；目标 {{target_item}}；重试 {{retry}}。',
        ),
        isNull,
      );
    });

    test('profile inference accepts both supplied variables', () {
      expect(
        validateTaskTemplate(
          'profile_inference',
          '情境 {{scene}}，选项 {{options}}',
        ),
        isNull,
      );
    });

    test('unsupported variable names the task contract', () {
      expect(
        validateTaskTemplate('role_play', '请结合 {{profile}} 回答。'),
        '不支持变量 {{profile}}；当前任务可用变量：{{scene}}',
      );
    });

    test('all distinct unsupported variables are reported', () {
      expect(
        validateTaskTemplate(
          'role_play',
          '{{profile}} {{scene}} {{context}} {{profile}}',
        ),
        '不支持变量 {{profile}}、{{context}}；当前任务可用变量：{{scene}}',
      );
    });

    test('tasks without variables reject every placeholder', () {
      expect(
        validateTaskTemplate('reply_suggestion', '分析 {{scene}}'),
        '不支持变量 {{scene}}；当前任务不可使用变量',
      );
    });

    test('empty, NUL, and oversized templates are rejected', () {
      expect(validateTaskTemplate('role_play', '  \n\t'), '请先填写模板正文');
      expect(validateTaskTemplate('role_play', '前\u0000后'), contains('模板语法无效'));
      expect(
        validateTaskTemplate('role_play', 'a' * (64 * 1024 + 1)),
        '模板不能超过 64 KiB',
      );
    });

    test('malformed placeholders are rejected', () {
      for (final template in [
        '未闭合 {{scene',
        '多余 }}',
        '{{scene extra}}',
        '{{9scene}}',
        '{{scene\n}}',
        '{{{scene}}',
      ]) {
        expect(
          validateTaskTemplate('role_play', template),
          contains('模板语法无效'),
          reason: template,
        );
      }
    });

    test('unicode text and repeated allowed variables are valid', () {
      expect(
        validateTaskTemplate('role_play', '场景：{{scene}}\n再试一次：{{ scene }}。'),
        isNull,
      );
    });

    test('rejects templates that render blank for every legal call', () {
      for (final template in [
        '{{retry}}',
        '{{target_item}}',
        '{{retry}}{{target_item}}',
      ]) {
        expect(
          validateTaskTemplate('scoring', template),
          '模板在合法输入下为空；请保留必然提供的变量或固定说明文字',
          reason: template,
        );
      }
      expect(
        validateTaskTemplate('scoring', '评估 {{assessment}}；{{retry}}'),
        isNull,
      );
    });

    test('uses each task variable runtime bound for overflow checks', () {
      expect(validateTaskTemplate('role_play', '{{scene}}' * 44), isNull);
      expect(validateTaskTemplate('role_play', '{{scene}}' * 2788), isNull);
      expect(
        validateTaskTemplate('role_play', '{{scene}}' * 2789),
        '模板在最长合法输入下超过 256 KiB',
      );
      expect(validateTaskTemplate('role_play', '请围绕 {{scene}} 展开练习。'), isNull);
    });

    test('the admin hint matches the selected task', () {
      expect(taskVariableHint('role_play'), '可用变量：{{scene}}（最长 94 字节）');
      expect(
        taskVariableHint('scoring'),
        '可用变量：{{assessment}}（最长 12 字节）、{{target_item}}（最长 11 字节）、{{retry}}（最长 96 字节）',
      );
      expect(taskVariableHint('reply_suggestion'), '可用变量：无');
    });

    test('accepts a fifteen-rule scoring rubric within runtime bounds', () {
      const rule =
          '规则：先确认事实，再区分感受、需要和请求；不要贴标签或替对方作判断。'
          '评估类型：{{assessment}}；本轮重点：{{target_item}}；重试说明：{{retry}}。';
      final rubric = List.filled(15, rule).join('\n');

      expect('{{'.allMatches(rubric).length, 45);
      expect(validateTaskTemplate('scoring', rubric), isNull);
    });
  });
}
