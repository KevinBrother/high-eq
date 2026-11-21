import 'api.dart';
import 'app_op.g.dart';
import 'session.dart';

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
  }) async {
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
        final page = await api.json(
          AppOp.listConsents,
          scope: scope,
          query: {'cursor': ?cursor},
        );
        for (final record in page['items'] as List) {
          if (record['granted'] == true) {
            allowed.add(record['purpose'] as String);
          }
          if (record['granted'] == false &&
              needed.contains(record['purpose'])) {
            return false;
          }
        }
        cursor = page['next_cursor'] as String?;
        if (cursor != null && !seenCursors.add(cursor)) return false;
      } while (cursor != null);
      if (!allowed.containsAll(needed) || !await systemGranted()) return false;
      final rights = await api.json(AppOp.getEntitlements, scope: scope);
      if (rights['tier'] != 'member') return false;
      final expiry = DateTime.tryParse(rights['expires_at'] as String? ?? '');
      if (expiry == null || !expiry.isAfter(DateTime.now())) return false;
      api.sessions.require(scope);
    } catch (_) {
      return false;
    } // Offline, malformed data, logout: fail closed.
    beginRead(); // No await between the final account check and the native read.
    return true;
  }
}
