import '../../core/endpoints.g.dart';
import '../../core/session.dart';

enum ContactPurpose {
  contacts('contacts'),
  chatImport('chat_import');

  const ContactPurpose(this.wire);
  final String wire;
}

// Version of the two purpose notices shown by this feature, not login consent.
const contactNoticeVersion = '2026-11';

class ConsentUnconfirmed implements Exception {}

class ContactDecisions {
  ContactDecisions(this.api, this.scope);
  final MobileEndpoints api;
  final AccountScope scope;
  Future<Set<ContactPurpose>> current() async {
    final grants = <ContactPurpose>{};
    final seen = <String>{};
    String? cursor;
    do {
      final page = await api.listConsents(scope: scope, cursor: cursor);
      for (final row in page['items'] as List) {
        for (final p in ContactPurpose.values) {
          if (row['purpose'] == p.wire &&
              row['version'] == contactNoticeVersion &&
              row['granted'] == true) {
            grants.add(p);
          }
        }
      }
      cursor = page['next_cursor'] as String?;
      if (cursor != null && !seen.add(cursor)) throw ConsentUnconfirmed();
    } while (cursor != null);
    return grants;
  }

  Future<void> grant(ContactPurpose purpose) async {
    final receipt = await api.setConsent(
      scope: scope,
      purpose: purpose.wire,
      body: {'version': contactNoticeVersion, 'granted': true},
    );
    if (receipt['purpose'] != purpose.wire ||
        receipt['granted'] != true ||
        receipt['version'] != contactNoticeVersion) {
      throw ConsentUnconfirmed();
    }
  }
}
