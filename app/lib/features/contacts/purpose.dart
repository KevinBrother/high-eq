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

typedef ContactInferenceGrant = ({
  String account,
  String contactsRevision,
  String chatImportRevision,
});

/// One account's current decisions for the purposes owned by contacts.
///
/// Revisions bind an inference operation to the exact consent records that
/// authorized it. A grant boolean alone is insufficient because withdrawing
/// and granting again returns to `true` with a new record.
final class ContactConsentSnapshot {
  ContactConsentSnapshot(this.account, Map<ContactPurpose, String> revisions)
    : _revisions = Map.unmodifiable(revisions);

  final String account;
  final Map<ContactPurpose, String> _revisions;

  Set<ContactPurpose> get grants => Set.unmodifiable(_revisions.keys);

  bool allows(ContactPurpose purpose) => _revisions.containsKey(purpose);

  ContactInferenceGrant? get inferenceGrant {
    final contactsRevision = _revisions[ContactPurpose.contacts];
    final chatImportRevision = _revisions[ContactPurpose.chatImport];
    if (contactsRevision == null || chatImportRevision == null) return null;
    return (
      account: account,
      contactsRevision: contactsRevision,
      chatImportRevision: chatImportRevision,
    );
  }
}

/// The consent records that authorized an operation were withdrawn, replaced,
/// or could not be compared before a network send.
final class ContactConsentChanged implements Exception {
  const ContactConsentChanged();
}

class ContactDecisions {
  ContactDecisions(this.api, this.scope);
  final MobileEndpoints api;
  final AccountScope scope;
  Future<ContactConsentSnapshot> current() async {
    final revisions = <ContactPurpose, String>{};
    final seen = <String>{};
    String? cursor;
    do {
      final page = await api.listConsents(scope: scope, cursor: cursor);
      for (final row in page['items'] as List) {
        final purpose = ContactPurpose.values
            .where((candidate) => row['purpose'] == candidate.wire)
            .firstOrNull;
        if (purpose == null ||
            row['version'] != contactNoticeVersion ||
            row['granted'] != true) {
          continue;
        }
        final updatedAt = row['updated_at'];
        if (updatedAt is! String || DateTime.tryParse(updatedAt) == null) {
          throw ConsentUnconfirmed();
        }
        final revision =
            '${purpose.wire}\u0000$contactNoticeVersion\u0000true\u0000$updatedAt';
        final prior = revisions[purpose];
        if (prior != null && prior != revision) throw ConsentUnconfirmed();
        revisions[purpose] = revision;
      }
      cursor = page['next_cursor'] as String?;
      if (cursor != null && !seen.add(cursor)) throw ConsentUnconfirmed();
    } while (cursor != null);
    return ContactConsentSnapshot(scope.account, revisions);
  }

  Future<void> grant(ContactPurpose purpose) async {
    final receipt = await api.setConsent(
      scope: scope,
      purpose: purpose.wire,
      body: {'version': contactNoticeVersion, 'granted': true},
    );
    if (receipt['purpose'] != purpose.wire ||
        receipt['granted'] != true ||
        receipt['version'] != contactNoticeVersion ||
        receipt['updated_at'] is! String ||
        DateTime.tryParse(receipt['updated_at'] as String) == null) {
      throw ConsentUnconfirmed();
    }
  }
}
