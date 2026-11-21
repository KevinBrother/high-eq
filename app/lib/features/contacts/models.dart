import 'dart:math';
import '../../core/transport.dart';
import 'scene.dart';

String newRequestId() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = bytes[6] & 15 | 64;
  bytes[8] = bytes[8] & 63 | 128;
  final h = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

// Translate only a supplied label; confidence is never used to infer a trait.
const _plainLabels = {
  '开放性高': '愿意试试不熟悉的办法',
  '尽责性高': '喜欢事先说好安排',
  '外向性高': '更愿意把想法说出来',
  '宜人性高': '会先听听别人的需要',
  '竞争型': '遇到分歧时更想说明自己的立场',
  '合作型': '愿意一起找兼顾双方的办法',
  '妥协型': '愿意各让一步',
  '回避型': '想先缓一缓，再谈分歧',
  '迁就型': '会先照顾对方的想法',
  '回避型依恋': '在亲密相处时需要一些独处空间',
  '焦虑型依恋': '在联系减少时想得到回应',
  '安全型依恋': '愿意直接说出需要',
};
final _unsafe = RegExp(
  '一定|绝对|肯定|必然|总是|每次都|毫无例外|永远|从不|从来不|天生|注定|必定|百分之百|100%|人格障碍|抑郁症|躁郁症|双相|精神病|焦虑症|自恋狂|控制狂|有病|诊断|确诊',
);
String observation(String value) =>
    value.trim().isEmpty || value.trim() == '沟通练习' || _unsafe.hasMatch(value)
    ? '线索还不够，可以再观察几次。'
    : '可能的倾向：${_plainLabels[value.trim()] ?? value.trim()}';

class Contact {
  Contact.fromJson(Json j)
    : id = j['id'] as String,
      name = j['nickname'] as String,
      scene = Scene.values.byName(j['scene']),
      editable = j['editable'] as bool,
      profile = j['profile'] as Json;
  final String id, name;
  final Scene scene;
  final bool editable;
  final Json profile;
}

class Book {
  Book(this.people, this.rights) {
    final limit = rights['max_active_contacts'];
    if (!rights.containsKey('max_active_contacts') ||
        (limit != null && (limit is! int || limit < 0))) {
      throw const FormatException('无效的关系人名额');
    }
  }
  final List<Contact> people;
  final Json rights;
  DateTime? get expires =>
      DateTime.tryParse(rights['expires_at'] as String? ?? '');
  bool get member =>
      rights['tier'] == 'member' && expires?.isAfter(DateTime.now()) == true;
  int? get limit => member
      ? rights['max_active_contacts'] as int?
      : min(1, (rights['max_active_contacts'] as int?) ?? 1);
  bool get consistent =>
      (rights['tier'] == 'free' || member) &&
      (limit == null || people.where((p) => p.editable).length <= limit!);
  bool get canAdd => consistent && (limit == null || people.length < limit!);
  bool usable(Contact c) =>
      consistent && people.any((p) => p.id == c.id && p.editable);
  bool canChoose(Contact c) =>
      consistent && !member && limit == 1 && !c.editable;
}

typedef Question = ({String id, String prompt});
List<Question> questionsFrom(Json j) {
  final qs = [
    for (final q in j['items'] as List)
      (id: q['id'] as String, prompt: q['prompt'] as String),
  ];
  if (qs.length < 5 ||
      qs.length > 8 ||
      qs.any((q) => q.prompt.trim().isEmpty) ||
      qs.map((q) => q.id).toSet().length != qs.length) {
    throw const FormatException('问题清单无效');
  }
  return qs;
}
