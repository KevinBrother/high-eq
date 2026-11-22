import 'dart:convert';
import '../../core/sse.dart';
import '../../core/transport.dart';
import '../contacts/models.dart' show newRequestId;
import '../contacts/repository.dart';
import '../contacts/scene.dart';
import 'repository.dart';

/// Account-lifetime offline rehearsal. No HTTP client, inference or balance writes.
class DemoPractice implements PracticeRepository {
  DemoPractice({ContactsRepository? contacts}) : _contacts = contacts;
  final ContactsRepository? _contacts;
  final _sessions = <String, Json>{},
      _setups = <String, Json>{},
      _journal = <String, Json>{};
  bool _practiceConsent = false;
  @override
  Future<bool> practiceConsent() async => _practiceConsent;
  @override
  Future<void> grantPracticeConsent() async => _practiceConsent = true;
  final _levels = [
    for (final scene in Scene.values)
      for (var d = 1; d <= 3; d++)
        {
          'id': newRequestId(),
          'title': ['先说发生了什么', '说清我的需要', '一起商量下一步'][d - 1],
          'scene': scene.name,
          'difficulty': d,
          'mode': d == 3 ? 'full_session' : 'single_skill',
          'target_item': d == 3
              ? null
              : d == 2
              ? 'need'
              : 'observation',
        },
  ];
  Json _copy(Json j) => jsonDecode(jsonEncode(j));
  Json _summary(Json session) => _copy(session)..remove('setup');

  // The demo has no database foreign keys. Mirror activities.contact_id's
  // ON DELETE CASCADE by pruning only sessions and pending intents tied to a
  // relation that is no longer present in the shared contact store.
  Future<void> _pruneDeletedContacts() async {
    final contacts = _contacts;
    if (contacts == null) return;
    final ids = (await contacts.load()).people.map((p) => p.id).toSet();
    bool removed(Json? setup) {
      final contact = setup?['contact_id'];
      return contact is String && !ids.contains(contact);
    }

    final gone = <String>{};
    for (final entry in _setups.entries) {
      if (removed(entry.value)) gone.add(entry.key);
    }
    for (final id in _sessions.keys) {
      if (removed(_setups[id])) gone.add(id);
    }
    for (final id in gone) {
      _setups.remove(id);
      _sessions.remove(id);
    }
    final pending = _journal['creating'];
    final pendingInput = pending?['input'];
    if (pendingInput is Json && removed(pendingInput)) {
      _journal.remove('creating');
    }
    _journal.removeWhere((key, _) => gone.contains(key));
  }

  @override
  Future<List<Json>> levels(Scene scene, int? difficulty) async => _levels
      .where(
        (l) =>
            l['scene'] == scene.name &&
            (difficulty == null || l['difficulty'] == difficulty),
      )
      .map(_copy)
      .toList();
  @override
  Future<List<Json>> history() async {
    await _pruneDeletedContacts();
    return _sessions.values.toList().reversed.map(_summary).toList();
  }

  @override
  Future<Json> create(Json body) async {
    final id = body['request_id'] as String;
    final level = _levels.where((l) => l['id'] == body['level_id']).firstOrNull;
    if (body['level_id'] != null && level == null) {
      throw const FormatException();
    }
    _setups.putIfAbsent(id, () => _copy(body));
    _sessions.putIfAbsent(
      id,
      () => {
        'session_id': id,
        'status': 'pending',
        'mode': level?['mode'] ?? 'full_session',
        'target_item': level?['target_item'],
        if (level != null) 'level_id': level['id'],
        'messages': <Json>[],
        'settlement': {
          'status': 'uncharged',
          'net_charge': 0,
          'charged_day': null,
        },
      },
    );
    return _summary(_sessions[id]!);
  }

  @override
  Future<Json> get(String id) async {
    await _pruneDeletedContacts();
    final s = _sessions[id];
    if (s == null) throw StateError('会话已随关系人删除');
    return {..._copy(s), if (_setups[id] != null) 'setup': _copy(_setups[id]!)};
  }

  @override
  Future<Json?> read(String key) async {
    await _pruneDeletedContacts();
    return _journal[key];
  }

  @override
  Future<void> remember(String key, Json? value) async {
    if (value == null) {
      _journal.remove(key);
    } else {
      _journal[key] = value;
    }
  }

  @override
  Stream<ReplyEvent> send(String id, Json body) async* {
    final s = _sessions[id]!,
        rows = s['messages'] as List<Json>,
        mid = body['client_message_id'];
    if (!['pending', 'active'].contains(s['status'])) throw StateError('已结束');
    var saved = rows
        .where((r) => r['role'] == 'assistant' && r['client_message_id'] == mid)
        .firstOrNull;
    if (saved == null) {
      final parts = rows.isEmpty
          ? ['我想听听你的想法。', '你最在意哪件事？']
          : ['我明白一些了。', '你希望接下来怎么做？'];
      for (final part in parts) {
        yield ReplyEvent(ReplyEventKind.fragment, {
          'client_message_id': mid,
          'text': part,
        });
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (s['status'] == 'exited') return;
      Json row(String role, String text) => {
        'seq': rows.length + 1,
        'role': role,
        'text': text,
        'id': newRequestId(),
        'client_message_id': mid,
      };
      rows.add(row('user', body['text']));
      saved = row('assistant', parts.join());
      rows.add(saved);
      s['status'] = 'active';
      if (s['settlement']['status'] == 'uncharged') {
        s['settlement'] = {
          'status': 'charged',
          'net_charge': 1,
          'charged_day': DateTime.now().toIso8601String().substring(0, 10),
        };
      }
    }
    yield ReplyEvent(ReplyEventKind.replySaved, {
      'client_message_id': mid,
      'message_id': saved['id'],
      'settlement': s['settlement'],
    });
  }

  @override
  Future<Json> exit(String id) async {
    final s = _sessions[id]!;
    s['status'] = 'exited';
    return _copy(s['settlement']);
  }

  @override
  Future<Json> finish(String id) async {
    final s = _sessions[id]!;
    if (s['result'] != null) return _copy(s['result']);
    final turns = (s['messages'] as List).length ~/ 2;
    final improved = turns > 1, points = improved ? 25 : 15;
    s['status'] = 'complete';
    s['result'] = {
      'mode': s['mode'],
      'settlement': s['settlement'],
      if (s['mode'] == 'single_skill')
        'progress': {
          'target_item': s['target_item'],
          'score': points,
          'reason': '从具体发生的事开始，再说你在意什么。',
          'next_action': improved ? 'pass' : 'retry_in_three_days',
        }
      else
        'score': {
          'score_id': newRequestId(),
          'mode': 'express',
          'nvc': {
            for (final k in skills.keys)
              k: {'score': points, 'reason': '可以再把情境说具体一些。'},
            'total': points * 4,
          },
          'emotion': {
            for (final k in ['read_others', 'self_management', 'relationship'])
              k: {'level': 3, 'reason': '给彼此留了一点商量的空间。'},
          },
          'target_turn': turns,
          'better_version': '我们能约个时间，一起把下一步定下来吗？',
          'why_better': '说出了希望对方参与的具体行动。',
        },
    };
    return _copy(s['result']);
  }
}
