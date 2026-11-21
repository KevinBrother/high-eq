import 'package:flutter/material.dart';

typedef RowData = Map<String, dynamic>;
const tasks = {
  'role_play': '角色扮演',
  'reply_suggestion': '回复建议',
  'scoring': '评分',
  'profile_inference': '画像推断',
  'review_analysis': '复盘分析',
  'content_generation': '内容生成',
  'classification': '简单分类',
};
const sentFields =
    'model,messages.role,messages.content,stream,response_format.type';

// Secrets only live in this form until it is disposed; no echo, persistence or
// initial value from a masked key. Editors are inline so session expiry removes them.
class ConfigEditor extends StatefulWidget {
  const ConfigEditor({
    super.key,
    required this.section,
    required this.item,
    required this.models,
    required this.admissions,
    required this.save,
    required this.cancel,
    required this.busy,
  });
  final String section;
  final RowData item;
  final List<RowData> models, admissions;
  final Future<void> Function(RowData) save;
  final VoidCallback cancel;
  final bool busy;
  @override
  State<ConfigEditor> createState() => _Editor();
}

class _Editor extends State<ConfigEditor> {
  final form = GlobalKey<FormState>();
  late final RowData v = {...widget.item};
  bool confirmed = false;
  Widget text(
    String k,
    String label, {
    bool secret = false,
    bool numeric = false,
    bool optional = false,
    String? initial,
    String? Function(String)? check,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      key: ValueKey('$k:$initial'),
      initialValue: initial ?? v[k]?.toString(),
      decoration: InputDecoration(labelText: label),
      obscureText: secret,
      autocorrect: !secret,
      enableSuggestions: !secret,
      keyboardType: numeric ? TextInputType.number : null,
      onChanged: (s) => v[k] = s,
      validator: (s) {
        if ((s ?? '').trim().isEmpty) {
          return optional ? null : '请填写$label';
        }
        return check?.call(s!);
      },
    ),
  );
  Widget select(
    String k,
    String label,
    Map<String, String> options, {
    bool optional = false,
    void Function(String)? change,
  }) {
    final val = v[k]?.toString();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        key: ValueKey('$k:$val'),
        isExpanded: true,
        initialValue: options.containsKey(val) ? val : null,
        decoration: InputDecoration(labelText: label),
        items: [
          for (final e in options.entries)
            DropdownMenuItem(
              value: e.key,
              child: Text(e.value, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (s) => setState(() {
          v[k] = s;
          change?.call(s!);
        }),
        validator: (s) =>
            !optional && (s == null || s.isEmpty) ? '请选择$label' : null,
      ),
    );
  }

  String? price(String s) {
    final n = double.tryParse(s);
    return n == null || !n.isFinite || n < 0 || n > 999999.999999
        ? '请输入有效非负单价'
        : null;
  }

  RowData? get evidence => widget.admissions
      .where((a) => a['ref'] == v['admission_ref'])
      .firstOrNull;
  List<Widget> model() {
    final a = evidence;
    return [
      select(
        'admission_ref',
        '已核验凭据',
        {
          for (final a in widget.admissions)
            a['ref']:
                '${a['provider']} · ${a['model_scope']} · ${a['purpose']} · ${a['ref']}',
        },
        change: (_) {
          v['model_name'] = evidence?['model_scope'] == '*'
              ? ''
              : evidence?['model_scope'];
        },
      ),
      if (a != null)
        Text('${a['kind'] == 'model' ? '生成模型' : '审核模型'} · ${a['endpoint']}'),
      text('name', '显示名称'),
      if (a?['model_scope'] == '*') text('model_name', '合同覆盖的模型名'),
      text(
        'input_cny_per_million',
        '输入单价（元 / 百万 token）',
        numeric: true,
        check: price,
      ),
      text(
        'output_cny_per_million',
        '输出单价（元 / 百万 token）',
        numeric: true,
        check: price,
      ),
      text(
        'api_key',
        widget.item['id'] == null ? '平台密钥' : '新密钥（留空保留原密钥）',
        secret: true,
        optional: widget.item['id'] != null,
        check: (s) =>
            RegExp(r'^[!-~]{5,4096}$').hasMatch(s) ? null : '至少 5 位，不含空格',
      ),
      SwitchListTile(
        value: v['enabled'] == true,
        title: const Text('启用模型'),
        onChanged: (b) => setState(() => v['enabled'] = b),
      ),
    ];
  }

  List<Widget> admission() => [
    text('provider', '服务商'),
    text(
      'endpoint',
      '合同约定 HTTPS 基址',
      check: (s) => Uri.tryParse(s)?.scheme == 'https' ? null : '仅接受 HTTPS',
    ),
    text('model_scope', '模型范围（仅全端点合同可填 *）'),
    select('kind', '用途类型', {'model': '生成模型', 'moderation': '审核模型'}),
    text('purpose', '合同用途'),
    text('sent_fields', '实际发送字段（逗号分隔）', initial: sentFields),
    text(
      'max_retention_days',
      '最长留存天数',
      numeric: true,
      check: (s) => (int.tryParse(s) ?? -1) < 0 ? '请输入非负整数' : null,
    ),
    text('deletion_method', '删除途径'),
    text('terms_evidence', '条款凭据编号或位置'),
    CheckboxListTile(
      value: confirmed,
      onChanged: (b) => setState(() => confirmed = b == true),
      title: const Text('已独立核验凭据、境内处理及存储、不出境和上述条款'),
    ),
  ];
  List<Widget> route() {
    Map<String, String> options(String kind) => {
      for (final m in widget.models)
        if (m['kind'] == kind &&
            m['enabled'] == true &&
            m['input_cny_per_million'] != null &&
            m['output_cny_per_million'] != null &&
            widget.admissions.any((a) => a['ref'] == m['admission_ref']))
          m['id']: '${m['name']} · ${m['model_name']}',
    };
    return [
      Text(tasks[v['task']] ?? ''),
      select(
        'primary_model',
        '主模型',
        options('model'),
        change: (s) {
          if (v['fallback_model'] == s) v['fallback_model'] = null;
        },
      ),
      select(
        'fallback_model',
        '备用模型',
        options('model')..remove(v['primary_model']),
      ),
      select('moderation_model', '审核模型', options('moderation')),
      select('canary_model', '灰度模型', {
        '': '不使用灰度',
        ...options('model'),
      }, optional: true),
      text(
        'canary_percent',
        '灰度用户比例（0–100%）',
        numeric: true,
        check: (s) {
          final n = int.tryParse(s);
          return n == null || n < 0 || n > 100
              ? '请输入 0–100 的整数'
              : n > 0 && (v['canary_model'] ?? '') == ''
              ? '请先选择灰度模型'
              : null;
        },
      ),
    ];
  }

  void submit() {
    if (!form.currentState!.validate()) return;
    switch (widget.section) {
      case 'admissions':
        if (!confirmed) return;
        widget.save({
          ...v,
          'sent_fields': (v['sent_fields'] ?? sentFields)
              .toString()
              .split(',')
              .map((s) => s.trim())
              .toList(),
          'max_retention_days': int.parse(v['max_retention_days'].toString()),
          'processing_country': 'CN',
          'storage_country': 'CN',
          'cross_border': false,
        });
      case 'models':
        final a = evidence!;
        widget.save({
          for (final k in ['kind', 'provider', 'endpoint']) k: a[k],
          'admission_ref': a['ref'],
          'enabled': v['enabled'] == true,
          'name': v['name'],
          'model_name': a['model_scope'] == '*'
              ? v['model_name']
              : a['model_scope'],
          for (final k in ['input_cny_per_million', 'output_cny_per_million'])
            k: double.parse(v[k].toString()),
          if ((v['api_key'] ?? '') != '') 'api_key': v['api_key'],
        });
      default:
        widget.save({
          for (final k in [
            'primary_model',
            'fallback_model',
            'moderation_model',
          ])
            k: v[k],
          'canary_model': (v['canary_model'] ?? '') == ''
              ? null
              : v['canary_model'],
          'canary_percent': int.parse(v['canary_percent'].toString()),
        });
    }
  }

  @override
  Widget build(BuildContext context) => Form(
    key: form,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...switch (widget.section) {
          'models' => model(),
          'routes' => route(),
          _ => admission(),
        },
        Wrap(
          spacing: 12,
          children: [
            FilledButton(
              onPressed:
                  widget.busy || widget.section == 'admissions' && !confirmed
                  ? null
                  : submit,
              child: const Text('保存配置'),
            ),
            TextButton(
              onPressed: widget.busy ? null : widget.cancel,
              child: const Text('取消'),
            ),
          ],
        ),
      ],
    ),
  );
}
