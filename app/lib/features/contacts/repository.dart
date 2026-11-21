import '../../core/endpoints.g.dart';
import '../../core/session.dart';
import '../../core/transport.dart';
import 'models.dart';
import 'purpose.dart';

abstract interface class ContactsRepository {
  Future<Set<ContactPurpose>> currentGrants();
  Future<void> grant(ContactPurpose purpose);
  Future<Book> load();
  Future<List<Question>> questions();
  Future<void> save(Json input, {String? id});
  Future<void> remove(String id);
  Future<void> choose(String id);
  Future<Json> infer(String id, String requestId, String text);
}

class ApiContacts implements ContactsRepository {
  ApiContacts(this.api, this.scope);
  final MobileEndpoints api;
  final AccountScope scope;
  late final _consents = ContactDecisions(api, scope);
  @override
  Future<Set<ContactPurpose>> currentGrants() => _consents.current();
  @override
  Future<void> grant(ContactPurpose purpose) => _consents.grant(purpose);
  @override
  Future<Book> load() async {
    final people = <Contact>[];
    final seen = <String>{};
    String? cursor;
    do {
      final page = await api.listContacts(
        scope: scope,
        cursor: cursor,
        limit: 100,
      );
      people.addAll((page['items'] as List).map((j) => Contact.fromJson(j)));
      cursor = page['next_cursor'] as String?;
      if (cursor != null && !seen.add(cursor)) {
        throw const FormatException('分页异常');
      }
    } while (cursor != null);
    return Book(people, await api.getEntitlements(scope: scope));
  }

  @override
  Future<List<Question>> questions() async =>
      questionsFrom(await api.getContactQuestions(scope: scope));
  @override
  Future<void> save(Json input, {String? id}) async {
    if (id == null) {
      await api.createContact(scope: scope, body: input);
    } else {
      await api.editContact(scope: scope, id: id, body: input);
    }
  }

  @override
  Future<void> remove(String id) async {
    if ((await api.deleteContact(scope: scope, id: id))['ok'] != true) {
      throw const FormatException('未确认删除');
    }
  }

  @override
  Future<void> choose(String id) async {
    await api.chooseContact(scope: scope, id: id);
  }

  @override
  Future<Json> infer(String id, String requestId, String text) =>
      api.inferProfile(
        scope: scope,
        id: id,
        body: {'request_id': requestId, 'chat_text': text},
      );
}
