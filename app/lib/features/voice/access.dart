import '../../core/api.dart';
import '../../core/app_op.g.dart';
import '../../core/consent.dart';
import '../../core/session.dart';
import 'features.dart';

abstract interface class VoiceAccess {
  Future<bool> readIfAllowed(
    AccountScope scope,
    CollectionPurpose purpose, {
    required Future<bool> Function() systemGranted,
    required void Function() beginRead,
  });

  Future<bool> hasConsent(AccountScope scope, CollectionPurpose purpose);
  Future<DateTime?> memberExpiry(AccountScope scope);
  Future<void> setConsent(
    AccountScope scope,
    CollectionPurpose purpose,
    bool granted,
  );
}

abstract interface class VoiceUploader {
  Future<void> upload(
    AccountScope scope,
    VoiceWindow window, {
    Future<void> Function()? beforeSend,
  });
}

String wirePurpose(CollectionPurpose purpose) => switch (purpose) {
  CollectionPurpose.voice => 'voice',
  CollectionPurpose.audioRetention => 'audio_retention',
  CollectionPurpose.health => 'health',
};

class ApiVoiceAccess implements VoiceAccess {
  final AppApi api;
  final ConsentGate gate;
  ApiVoiceAccess(this.api, {ConsentGate? gate})
    : gate = gate ?? ConsentGate(api);

  @override
  Future<bool> readIfAllowed(
    AccountScope scope,
    CollectionPurpose purpose, {
    required Future<bool> Function() systemGranted,
    required void Function() beginRead,
  }) => gate.readIfAllowed(
    scope,
    purpose,
    systemGranted: systemGranted,
    beginRead: beginRead,
  );

  @override
  Future<bool> hasConsent(AccountScope scope, CollectionPurpose purpose) async {
    final wanted = wirePurpose(purpose);
    final seen = <String>{};
    String? cursor;
    do {
      final page = await api.json(
        AppOp.listConsents,
        scope: scope,
        query: {'cursor': ?cursor},
      );
      for (final item in page['items'] as List) {
        if (item is Map && item['purpose'] == wanted) {
          return item['granted'] == true;
        }
      }
      cursor = page['next_cursor'] as String?;
      if (cursor != null && !seen.add(cursor)) return false;
    } while (cursor != null);
    return false;
  }

  @override
  Future<DateTime?> memberExpiry(AccountScope scope) async {
    final rights = await api.json(AppOp.getEntitlements, scope: scope);
    if (rights['tier'] != 'member') return null;
    final expires = DateTime.tryParse(rights['expires_at'] as String? ?? '');
    return expires?.toUtc();
  }

  @override
  Future<void> setConsent(
    AccountScope scope,
    CollectionPurpose purpose,
    bool granted,
  ) async {
    final version = api.sessions.consentVersion(wirePurpose(purpose));
    final receipt = await api.json(
      AppOp.setConsent,
      scope: scope,
      path: {'purpose': wirePurpose(purpose)},
      body: {'version': '2026-11', 'granted': granted},
    );
    if (receipt['purpose'] != wirePurpose(purpose) ||
        receipt['granted'] != granted) {
      throw const FormatException('授权回执不匹配');
    }
    if (purpose == CollectionPurpose.voice) {
      granted
          ? api.sessions.noteConsentGranted(
              scope,
              'voice',
              expectedVersion: version,
            )
          : api.sessions.noteConsentWithdrawn(
              scope,
              'voice',
              expectedVersion: version,
            );
    }
  }
}

class ApiVoiceUploader implements VoiceUploader {
  final AppApi api;
  const ApiVoiceUploader(this.api);

  @override
  Future<void> upload(
    AccountScope scope,
    VoiceWindow window, {
    Future<void> Function()? beforeSend,
  }) async {
    await api.jsonGuarded(
      AppOp.uploadWindow,
      scope: scope,
      body: window.toWire(),
      beforeSend: beforeSend ?? () async {},
    );
  }
}
