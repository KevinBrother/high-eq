import 'dart:convert';

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

/// Mirrors the server-side task variable contract. Keeping this explicit makes
/// an unsupported template fail in the editor before a draft or release write.
const taskVariables = <String, List<String>>{
  'role_play': ['scene'],
  'scoring': ['assessment', 'target_item', 'retry'],
  'profile_inference': ['scene', 'options'],
  'reply_suggestion': [],
  'review_analysis': [],
  'content_generation': [],
  'classification': [],
};

const _identifier = r'^[a-zA-Z_][a-zA-Z0-9_]*$';
const _maxTemplateBytes = 64 * 1024;
const _maxRenderedBytes = 256 * 1024;

// These are the largest values production calls actually supply, not the
// separate 6,000-byte custom-scenario input ceiling. Custom text stays in the
// first user message and only its validated category enters {{scene}}.
const _taskVariableMaxBytes = <String, Map<String, int>>{
  'role_play': {'scene': 94},
  'scoring': {'assessment': 12, 'target_item': 11, 'retry': 96},
  'profile_inference': {'scene': 7, 'options': 501},
};

const _taskGuaranteedVariables = <String, Set<String>>{
  'role_play': {'scene'},
  'scoring': {'assessment'},
  'profile_inference': {'scene', 'options'},
};

String taskVariableHint(String task) {
  final names = taskVariables[task] ?? const <String>[];
  if (names.isEmpty) return '可用变量：无';
  final limits = _taskVariableMaxBytes[task] ?? const <String, int>{};
  return '可用变量：${names.map((name) => '{{$name}}（最长 ${limits[name]} 字节）').join('、')}';
}

/// Returns a user-facing error, or null when the template is valid for [task].
/// The parser intentionally follows the Go contract: only double-brace ASCII
/// identifiers are placeholders, and only spaces/tabs are allowed inside them.
String? validateTaskTemplate(String task, String template) {
  if (template.trim().isEmpty) return '请先填写模板正文';
  if (template.contains('\u0000')) return '模板语法无效：不能包含 NUL 字符';
  if (utf8.encode(template).length > _maxTemplateBytes) {
    return '模板不能超过 64 KiB';
  }
  final allowed = taskVariables[task];
  if (allowed == null) return '未知任务';

  final unsupported = <String>[];
  var worstCaseBytes = utf8.encode(template).length;
  var renderable = StringBuffer();
  var literalStart = 0;
  for (var i = 0; i + 1 < template.length;) {
    final pair = template.substring(i, i + 2);
    if (pair == '}}') return '模板语法无效：存在多余的 }}';
    if (pair != '{{') {
      i++;
      continue;
    }
    final end = template.indexOf('}}', i + 2);
    if (end < 0) return '模板语法无效：存在未闭合的 {{';
    final name = _trimTemplateSpace(template.substring(i + 2, end));
    if (!RegExp(_identifier).hasMatch(name)) {
      return '模板语法无效：变量名不合法';
    }
    if (!allowed.contains(name) && !unsupported.contains(name)) {
      unsupported.add(name);
    }
    final placeholder = template.substring(i, end + 2);
    final variableMaxBytes = _taskVariableMaxBytes[task]?[name];
    if (variableMaxBytes != null) {
      worstCaseBytes += variableMaxBytes - utf8.encode(placeholder).length;
    }
    renderable.write(template.substring(literalStart, i));
    if (_taskGuaranteedVariables[task]?.contains(name) ?? false) {
      renderable.write('x');
    }
    literalStart = end + 2;
    i = end + 2;
  }
  if (unsupported.isNotEmpty) {
    final names = unsupported.map((name) => '{{$name}}').join('、');
    final availability = allowed.isEmpty
        ? '当前任务不可使用变量'
        : '当前任务可用变量：${allowed.map((name) => '{{$name}}').join('、')}';
    return '不支持变量 $names；$availability';
  }
  if (worstCaseBytes > _maxRenderedBytes) {
    return '模板在最长合法输入下超过 256 KiB';
  }
  renderable.write(template.substring(literalStart));
  if (renderable.toString().trim().isEmpty) {
    return '模板在合法输入下为空；请保留必然提供的变量或固定说明文字';
  }
  return null;
}

String _trimTemplateSpace(String value) {
  var start = 0;
  var end = value.length;
  while (start < end && (value[start] == ' ' || value[start] == '\t')) {
    start++;
  }
  while (end > start && (value[end - 1] == ' ' || value[end - 1] == '\t')) {
    end--;
  }
  return value.substring(start, end);
}
