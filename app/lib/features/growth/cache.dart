import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/session.dart';

/// Owns the growth snapshot generation for one account.
///
/// A clear invalidates reads before it touches encrypted storage. This keeps
/// an older in-flight load from restoring a snapshot that predates a contact
/// deletion, even if the storage removal itself is slow or fails.
final class GrowthCache {
  GrowthCache(this.sessions, this.scope);

  static const _cacheId = 'growth.snapshot.v1';

  final Sessions sessions;
  final AccountScope scope;
  final _invalidations = ValueNotifier<int>(0);

  int _generation = 0;
  bool _trusted = true;
  bool _disposed = false;

  int get generation => _generation;
  int get invalidationRevision => sessions.growthCacheRevision(scope);
  ValueListenable<int> get invalidations => _invalidations;

  /// Makes reads already in flight stale without discarding the last snapshot.
  void invalidateReads() {
    _generation++;
  }

  Future<List<int>?> read() async {
    if (!_trusted) return null;
    final generation = _generation;
    final bytes = await sessions.getGrowthCache(scope, _cacheId);
    if (!_trusted || generation != _generation) return null;
    return bytes;
  }

  /// Writes a load result only when no clear or newer mutation intervened.
  Future<bool> writeIfCurrent(
    int generation,
    List<int> bytes, {
    required int invalidationRevision,
  }) async {
    if (generation != _generation) return false;
    final written = await sessions.putGrowthCache(
      scope,
      _cacheId,
      bytes,
      revision: invalidationRevision,
      recoverInvalidated: true,
    );
    if (written && generation == _generation) _trusted = true;
    return written && generation == _generation;
  }

  Future<void> write(List<int> bytes) async {
    final generation = _generation;
    final written = await sessions.putGrowthCache(
      scope,
      _cacheId,
      bytes,
      revision: invalidationRevision,
      recoverInvalidated: false,
    );
    if (!written) throw const GrowthCacheInvalidated();
    if (generation == _generation) _trusted = true;
  }

  void Function() _localInvalidator() {
    var notified = false;
    return () {
      if (notified) return;
      notified = true;
      _generation++;
      _trusted = false;
      if (!_disposed) _invalidations.value++;
    };
  }

  /// Must succeed before the contact deletion request is sent.
  Future<GrowthDeletion> prepareDeletion(
    String contactId, {
    GrowthDeletion? retry,
  }) => sessions.prepareGrowthDeletion(
    scope,
    contactId: contactId,
    retry: retry,
    onInvalidated: _localInvalidator(),
  );

  Future<List<GrowthDeletion>> pendingDeletions() =>
      sessions.pendingGrowthDeletions(scope);

  Future<bool> resolveDeletion(GrowthDeletion operation) =>
      sessions.resolveGrowthDeletion(
        scope,
        _cacheId,
        operation: operation,
        onInvalidated: _localInvalidator(),
      );

  Future<void> clear() async {
    final invalidate = _localInvalidator();

    try {
      await sessions.clearGrowthCache(
        scope,
        _cacheId,
        onInvalidated: invalidate,
      );
    } finally {
      // Session transitions can reject the clear before the session callback
      // runs. Local memory must still be discarded from the retained pages.
      invalidate();
    }
  }

  void dispose() {
    _disposed = true;
    _invalidations.dispose();
  }
}

class GrowthCacheInvalidated implements Exception {
  const GrowthCacheInvalidated();

  @override
  String toString() => '成长缓存已在删除后失效';
}

/// Shared by the growth route and contact deletion so both observe the same
/// generation. It is rebuilt from the account scope, never the current login
/// lookup at dispatch time.
final growthCacheProvider = Provider<GrowthCache?>((ref) {
  final api = ref.watch(apiProvider).requireValue;
  final scope = ref.watch(accountScopeProvider);
  if (scope == null) return null;
  final cache = GrowthCache(api.sessions, scope);
  ref.onDispose(cache.dispose);
  return cache;
}, dependencies: [accountScopeProvider]);
