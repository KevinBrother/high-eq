import 'api.dart';
import 'app_op.g.dart';
import 'session.dart';
import 'transport.dart' show Json;

enum CollectionPurpose { health, voice, audioRetention }

/// This gate never asks for OS permissions. A denied/unavailable read must not
/// block manual marking or other free, non-sensor features.
class ConsentGate {
  final AppApi api;
  ConsentGate(this.api);
  Future<bool> readIfAllowed(
    AccountScope scope,
    CollectionPurpose purpose, {
    required Future<bool> Function() systemGranted,
    required void Function() beginRead,
    bool Function(Map record)? acceptsGrant,
    void Function(DateTime expiry)? onExpiry,
    void Function()? onDenied,
    bool forHealthUpload = false,
  }) async {
    Future<Json> query(AppOp op, [Map<String, String> query = const {}]) =>
        forHealthUpload && purpose == CollectionPurpose.health
        ? api.jsonForHealthUploadGate(op, scope: scope, query: query)
        : api.json(op, scope: scope, query: query);

    bool denied() {
      onDenied?.call();
      return false;
    }

    try {
      final needed = switch (purpose) {
        CollectionPurpose.health => {'health'},
        CollectionPurpose.voice => {'voice'},
        CollectionPurpose.audioRetention => {'voice', 'audio_retention'},
      };
      final allowed = <String>{};
      final seenCursors = <String>{};
      String? cursor;
      do {
        final page = await query(AppOp.listConsents, {'cursor': ?cursor});
        for (final record in page['items'] as List) {
          if (record['granted'] == true &&
              (!needed.contains(record['purpose']) ||
                  (acceptsGrant?.call(record) ?? true))) {
            allowed.add(record['purpose'] as String);
          }
          if (record['granted'] == false &&
              needed.contains(record['purpose'])) {
            return denied();
          }
        }
        cursor = page['next_cursor'] as String?;
        if (cursor != null && !seenCursors.add(cursor)) return false;
      } while (cursor != null);
      if (!allowed.containsAll(needed) || !await systemGranted()) {
        return denied();
      }
      final rights = await query(AppOp.getEntitlements);
      if (rights['tier'] != 'member') return denied();
      final expiry = DateTime.tryParse(rights['expires_at'] as String? ?? '');
      if (expiry == null || !expiry.isAfter(DateTime.now())) return denied();
      api.sessions.require(scope);
      onExpiry?.call(expiry);
    } catch (_) {
      return false;
    } // Offline, malformed data, logout: fail closed.
    beginRead(); // No await between the final account check and the native read.
    return true;
  }
}
