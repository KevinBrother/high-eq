import 'dart:convert';
import 'package:flutter/services.dart';
import '../../core/transport.dart';
import 'models.dart';
import 'purpose.dart';
import 'repository.dart';

/// Volatile examples, not an inference service. Never retain chat or answers.
class DemoContacts implements ContactsRepository {
  final _grants = <ContactPurpose>{};
  @override
  Future<Set<ContactPurpose>> currentGrants() async =>
      Set.unmodifiable(_grants);
  @override
  Future<void> grant(ContactPurpose purpose) async {
    _grants.add(purpose);
  }

  late final Future<Json> _examples = rootBundle
      .loadString('assets/contract_examples.json', cache: false)
      .then((v) => jsonDecode(v) as Json);
  late final Future<List<Json>> _rows = _examples.then((j) {
    final row = j['listContacts']['items'][0] as Json;
    return [
      {...row},
      {
        ...row,
        'id': newRequestId(),
        'scene': 'friends',
        'nickname': '老朋友',
        'editable': false,
      },
    ];
  });
  @override
  Future<Book> load() async => Book(
    (await _rows).map(Contact.fromJson).toList(),
    (await _examples)['getEntitlements'],
  );
  @override
  Future<List<Question>> questions() async =>
      questionsFrom((await _examples)['getContactQuestions']);
  @override
  Future<void> save(Json input, {String? id}) async {
    final rows = await _rows;
    final book = await load();
    if (id == null) {
      if (!book.canAdd) throw StateError('名额已用');
      rows.add({
        ...((await _examples)['createContact'] as Json),
        'id': newRequestId(),
        'nickname': input['nickname'],
        'scene': input['scene'],
      });
    } else {
      final c = rows.singleWhere((p) => p['id'] == id && p['editable'] == true);
      c.addAll({'nickname': input['nickname'], 'scene': input['scene']});
    }
  }

  @override
  Future<void> remove(String id) async {
    final rows = await _rows;
    rows.removeWhere((p) => p['id'] == id);
    if (rows.isNotEmpty && !rows.any((p) => p['editable'] == true)) {
      rows.first['editable'] = true;
    }
  }

  @override
  Future<void> choose(String id) async {
    final rows = await _rows;
    for (final p in rows) {
      p['editable'] = p['id'] == id;
    }
  }

  @override
  Future<Json> infer(String id, String requestId, String text) async =>
      (await _examples)['inferProfile'] as Json;
}
