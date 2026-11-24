import '../../core/session.dart';
import '../growth/cache.dart';
import 'repository.dart';

enum DeletionCheck { absent, present, abandoned, superseded }

class DeletionNotSent implements Exception {
  const DeletionNotSent();
}

class DeletionCacheUnconfirmed implements Exception {
  const DeletionCacheUnconfirmed();
}

abstract interface class ContactDeletion {
  Future<List<GrowthDeletion>> pending();
  Future<void> remove(String contactId, {GrowthDeletion? retry});
  Future<DeletionCheck> check(GrowthDeletion operation, {bool abandon = false});
}

/// Coordinates write confirmation and explicit read-only recovery for one
/// signed-in account. Different contacts keep independent pending records.
final class ApiContactDeletion implements ContactDeletion {
  ApiContactDeletion(this._repo, this._cache);

  final ApiContacts _repo;
  final GrowthCache _cache;

  @override
  Future<List<GrowthDeletion>> pending() => _cache.pendingDeletions();

  @override
  Future<void> remove(String contactId, {GrowthDeletion? retry}) =>
      _forContact(contactId, () async {
        if (retry != null) {
          if (retry.contactId != contactId ||
              !(await pending()).contains(retry)) {
            throw const DeletionNotSent();
          }
          // A retry is always user initiated. The original operation may have
          // completed since the first check, so look again before sending it.
          if (!await _repo.contactExists(contactId)) {
            await _confirm(retry);
            return;
          }
        }
        final GrowthDeletion operation;
        try {
          operation = await _cache.prepareDeletion(contactId, retry: retry);
        } on SessionChanged {
          rethrow;
        } on Object {
          throw const DeletionNotSent();
        }
        await _repo.remove(contactId);
        await _confirm(operation);
      });

  @override
  Future<DeletionCheck> check(
    GrowthDeletion operation, {
    bool abandon = false,
  }) => _forContact(operation.contactId, () async {
    if (!(await pending()).contains(operation)) {
      return DeletionCheck.superseded;
    }
    if (!await _repo.contactExists(operation.contactId)) {
      return await _confirm(operation)
          ? DeletionCheck.absent
          : DeletionCheck.superseded;
    }
    if (!abandon) return DeletionCheck.present;
    return await _cache.resolveDeletion(operation)
        ? DeletionCheck.abandoned
        : DeletionCheck.superseded;
  });

  Future<bool> _confirm(GrowthDeletion operation) async {
    try {
      return await _cache.resolveDeletion(operation);
    } on SessionChanged {
      rethrow;
    } on Object {
      throw const DeletionCacheUnconfirmed();
    }
  }

  Future<T> _forContact<T>(String id, Future<T> Function() action) => _cache
      .sessions
      .runExclusive(_cache.scope, 'contact-deletion:$id', action);
}
