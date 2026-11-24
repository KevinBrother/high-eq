import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;

abstract interface class SecretStore {
  Future<String?> read();
  Future<void> replace(String? value);
}

typedef DirectoryWipe = Future<void> Function(Directory directory);
typedef CacheRead = Future<List<int>> Function(File file);
typedef CacheDelete = Future<void> Function(File file);

class Tokens {
  final String account, access, refresh;
  final DateTime expires;
  Tokens(this.account, this.access, this.refresh, this.expires) {
    if ([account, access, refresh].any((s) => s.isEmpty)) {
      throw const FormatException('登录信息不完整');
    }
  }
  factory Tokens.fromJson(Map<String, dynamic> json) => Tokens(
    json['user_id'],
    json['access_token'],
    json['refresh_token'],
    DateTime.parse(json['expires_at']),
  );
  Map<String, dynamic> toJson() => {
    'user_id': account,
    'access_token': access,
    'refresh_token': refresh,
    'expires_at': expires.toUtc().toIso8601String(),
  };
}

enum CacheKind { continuation, draft, recording, queue }

enum _CleanupIntent { pending, absent, setup, explicit, unknown }

typedef GrowthDeletion = ({String contactId, String operationId});

class _CleanupMarker {
  const _CleanupMarker(this.accountTag, this.intent);
  final String accountTag;
  final _CleanupIntent intent;

  _CleanupMarker withIntent(_CleanupIntent next) =>
      _CleanupMarker(accountTag, next);
}

class SessionChanged implements Exception {}

/// The queue has not been classified: its bytes could not be read this round.
/// Unlike unknown contents, this must not authorize network calls or a wipe.
class CleanupEvidenceUnavailable extends FileSystemException {
  const CleanupEvidenceUnavailable([this.checkpointError])
    : super('无法读取待清理的健康队列');

  final Object? checkpointError;
}

/// Capture this handle when scheduling work, never look up the current user at dispatch.
class AccountScope {
  AccountScope._(this.account);
  final String account;
}

/// An in-process exit identity. A scope can never represent a later login of
/// the same account; the generation also fences restore and failed activations.
final class LogoutRound {
  const LogoutRound._(this.scope, this._generation, this._owner);
  final AccountScope scope;
  final int _generation;
  final Object _owner;
}

enum LogoutWithdrawalEvidence { none, explicit, unknown, unavailable }

typedef _CacheOwner = ({String account, SecretKey key});
typedef _StoredCache = ({Tokens? tokens, _CacheOwner cache});

class Sessions {
  static const healthQueueKey = 't28.history.v1';
  final SecretStore _secret;
  final Directory
  _directory; // Dedicated to this backend; never a shared directory.
  final File? _retirementBarrier;
  final Directory? _growthDeletionDirectory;
  final DirectoryWipe _wipe;
  final CacheRead _readCache;
  final CacheDelete _deleteCache;
  final _cipher = AesGcm.with256bits();
  Future<void> _tail = Future.value();
  final Map<AccountScope, Map<String, Future<void>>> _exclusiveTails = {};
  final _identity = ValueNotifier<AccountScope?>(null);
  ValueListenable<AccountScope?> get identity => _identity;
  AccountScope? get _active => _identity.value;
  SecretKey? _key;
  Tokens? _tokens;
  SecretKey? _withdrawalsKey;
  final _withdrawals = <String>{};
  final _persistedWithdrawals = <String>{};
  SecretKey? _unknownWithdrawalsKey;
  final _unknownWithdrawals = <String>{};
  final _persistedUnknownWithdrawals = <String>{};
  int _generation = 0;
  bool _retirementPending = false;
  String? _growthInvalidatedAccount;
  int _growthRevision = 0;
  final _roundOwner = Object();
  static const _cacheReadAttempts = 3;
  static const _cleanupWriteAttempts = 3;
  static const _retryDelay = Duration(milliseconds: 10);
  static const _cleanupMarkerName = '.t28-cleanup.v1';

  /// [retirementBarrier] is dedicated to this vault and lives outside the
  /// cache directory so a purge cannot erase both recovery files.
  Sessions(
    this._secret,
    this._directory, {
    DirectoryWipe? wipeDirectory,
    CacheRead? readCache,
    CacheDelete? deleteCache,
    File? retirementBarrier,
    Directory? growthDeletionDirectory,
  }) : _retirementBarrier = retirementBarrier,
       _growthDeletionDirectory = growthDeletionDirectory,
       _wipe = wipeDirectory ?? _defaultWipeDirectory,
       _readCache = readCache ?? _defaultReadCache,
       _deleteCache = deleteCache ?? _defaultDeleteCache;

  static Future<List<int>> _defaultReadCache(File file) => file.readAsBytes();

  static Future<void> _defaultDeleteCache(File file) => file.delete();

  static Future<void> _defaultWipeDirectory(Directory directory) async {
    if (await directory.exists()) await directory.delete(recursive: true);
    await directory.create(recursive: true);
  }

  AccountScope? get active => _active;
  Tokens require(AccountScope scope) {
    if (!identical(scope, _active)) throw SessionChanged();
    return _tokens!;
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  /// Serializes a complete read-modify-write sequence for one account scope.
  ///
  /// The queue lives on [Sessions], not on a repository instance, so separate
  /// repositories sharing this instance cannot interleave their operations.
  Future<T> runExclusive<T>(
    AccountScope scope,
    String key,
    Future<T> Function() action,
  ) {
    final queues = _exclusiveTails.putIfAbsent(
      scope,
      () => <String, Future<void>>{},
    );
    final previous = queues[key] ?? Future<void>.value();
    final result = previous.then<T>((_) {
      require(scope);
      return action();
    });
    final settled = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    queues[key] = settled;
    return result.whenComplete(() {
      if (identical(queues[key], settled)) {
        queues.remove(key);
        if (queues.isEmpty) _exclusiveTails.remove(scope);
      }
    });
  }

  void _check(int generation) {
    if (_generation != generation) throw SessionChanged();
  }

  Future<T> _transition<T>(Future<T> Function(int generation) action) {
    final generation = ++_generation;
    _tokens = null;
    _key = null;
    _growthInvalidatedAccount = null;
    _growthRevision = 0;
    // Enqueue before notifying listeners, which may synchronously start the
    // next transition. No later transition can overtake this cleanup.
    final result = _serial(() => action(generation));
    _identity.value = null;
    return result;
  }

  Future<void> _wipeDirectory() => _wipe(_directory);

  Future<void> _fenceRetirement() async {
    _retirementPending = true;
    final barrier = _retirementBarrier;
    if (barrier == null) return;
    try {
      await barrier.parent.create(recursive: true);
      // Presence alone blocks restore, even if a write stops partway through.
      await barrier.writeAsString('1', flush: true);
    } on FileSystemException {
      // The cleanup journal and credential update can still fence retirement.
    }
  }

  Future<bool> _retirementNeedsRecovery() async {
    if (_retirementPending) return true;
    final barrier = _retirementBarrier;
    if (barrier == null) return false;
    try {
      await barrier.length();
      return true;
    } on PathNotFoundException {
      return false;
    }
  }

  Future<void> _finishRetirement() async {
    try {
      await _retirementBarrier?.delete();
    } on PathNotFoundException {
      // There is no barrier left to release.
    }
    _retirementPending = false;
  }

  File get _cleanupMarkerFile => File('${_directory.path}/$_cleanupMarkerName');

  Future<String> _accountTag(String account) async {
    final digest = await Sha256().hash(utf8.encode(account));
    return base64UrlEncode(digest.bytes);
  }

  Future<void> _writeCleanupMarker(_CleanupMarker marker) async {
    await _directory.create(recursive: true);
    final target = _cleanupMarkerFile;
    final temp = File('${target.path}.tmp');
    final raw = jsonEncode({
      'account_tag': marker.accountTag,
      'kind': CacheKind.queue.name,
      'id': healthQueueKey,
      'intent': marker.intent.name,
    });
    await temp.writeAsString(raw, flush: true);
    await temp.rename(target.path);
  }

  Future<File> _growthDeletionFile(String account) async {
    final directory = _growthDeletionDirectory;
    if (directory == null) {
      throw StateError('成长删除围栏尚未配置');
    }
    return File('${directory.path}/${await _accountTag(account)}.v1');
  }

  /// An empty journal still fences the old snapshot until a fresh read has
  /// replaced it. Each entry holds only the contact and operation identifiers.
  Future<Map<String, String>?> _readGrowthDeletionFence(String account) async {
    if (_growthDeletionDirectory == null) return null;
    final file = await _growthDeletionFile(account);
    final String raw;
    try {
      raw = await file.readAsString();
    } on PathNotFoundException {
      return null;
    }
    if (raw.trim() == 'confirmed') return {};
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic> ||
        value.entries.any(
          (e) => e.key.isEmpty || e.value is! String || e.value == '',
        )) {
      throw const FormatException('无效的成长删除记录');
    }
    return Map<String, String>.from(value);
  }

  Future<void> _writeGrowthDeletionFence(
    String account,
    Map<String, String> pending,
  ) async {
    final directory = _growthDeletionDirectory;
    if (directory == null) {
      throw StateError('成长删除围栏尚未配置');
    }
    await directory.create(recursive: true);
    final target = await _growthDeletionFile(account);
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(jsonEncode(pending), flush: true);
    await temp.rename(target.path);
  }

  Future<void> _clearGrowthDeletionFence(String account) async {
    if (_growthDeletionDirectory == null) return;
    final target = await _growthDeletionFile(account);
    await _deleteVerified(target, (file) => file.delete());
    await _deleteVerified(File('${target.path}.tmp'), (file) => file.delete());
  }

  Future<bool> _hasGrowthDeletionFence(String account) async {
    try {
      return await _readGrowthDeletionFence(account) != null;
    } on Object {
      // An unreadable journal, including legacy pending records without a
      // contact ID, must continue to fence the old snapshot.
      return true;
    }
  }

  Future<_CleanupMarker?> _readCleanupMarker() async {
    final file = _cleanupMarkerFile;
    if (!await file.exists()) return null;
    final value = jsonDecode(await file.readAsString());
    if (value is! Map) throw const FormatException('无效的清理标记');
    final tag = value['account_tag'];
    final intentName = value['intent'];
    if (tag is! String ||
        tag.isEmpty ||
        value['kind'] != CacheKind.queue.name ||
        value['id'] != healthQueueKey) {
      throw const FormatException('无效的清理标记');
    }
    _CleanupIntent? intent;
    for (final candidate in _CleanupIntent.values) {
      if (candidate.name == intentName) intent = candidate;
    }
    if (intent == null) {
      throw const FormatException('无效的清理标记');
    }
    return _CleanupMarker(tag, intent);
  }

  void _recordCleanupIntent(String account, _CleanupIntent intent) {
    if (intent == _CleanupIntent.explicit) {
      _withdrawals.add(account);
      _unknownWithdrawals.remove(account);
      return;
    }
    if (intent == _CleanupIntent.unknown && !_withdrawals.contains(account)) {
      _unknownWithdrawals.add(account);
    }
  }

  Future<void> _tryWriteCleanupMarker(_CleanupMarker marker) async {
    try {
      await _writeCleanupMarker(marker);
    } on Object {
      // The encrypted outbox write below is the primary durable copy. A marker
      // written before the failure may still recover the exact intent.
      return;
    }
  }

  Future<_StoredCache?> _readStoredCache() async {
    _growthInvalidatedAccount = null;
    final raw = await _secret.read();
    if (raw == null) {
      _persistedWithdrawals.clear();
      _persistedUnknownWithdrawals.clear();
      return null;
    }
    final data = jsonDecode(raw);
    if (data is! Map<String, dynamic>) {
      throw const FormatException('无效的登录信息');
    }
    await _loadWithdrawals(data);
    final growthInvalidated = data['growth_invalidated'];
    if (growthInvalidated != null && growthInvalidated is! bool) {
      throw const FormatException('无效的成长缓存状态');
    }
    final tokenData = data['tokens'];
    final keyData = data['key'];
    final deferred = data['cleanup_queue'];
    if (deferred != null) {
      if (tokenData != null ||
          keyData != null ||
          growthInvalidated != null ||
          deferred is! Map) {
        throw const FormatException('无效的清理队列');
      }
      final account = deferred['account'];
      final key = deferred['key'];
      if (account is! String || account.isEmpty || key is! String) {
        throw const FormatException('无效的清理队列');
      }
      return (
        tokens: null,
        cache: (account: account, key: SecretKey(base64Decode(key))),
      );
    }
    if (tokenData == null && keyData == null) return null;
    if (tokenData is! Map || keyData is! String) {
      throw const FormatException('无效的登录信息');
    }
    final tokens = Tokens.fromJson(tokenData.cast<String, dynamic>());
    _growthInvalidatedAccount = growthInvalidated == true
        ? tokens.account
        : null;
    return (
      tokens: tokens,
      cache: (account: tokens.account, key: SecretKey(base64Decode(keyData))),
    );
  }

  bool get _hasUncommittedIntents =>
      !_persistedWithdrawals.containsAll(_withdrawals) ||
      !_persistedUnknownWithdrawals.containsAll(_unknownWithdrawals);

  _CacheOwner? get _liveCache {
    final account = _active?.account;
    final key = _key;
    return account == null || key == null ? null : (account: account, key: key);
  }

  Future<void> _retireCurrentOrStored(
    _CacheOwner? liveCache, {
    void Function()? onEvidence,
  }) async {
    if (liveCache != null) {
      // An exposed scope already loaded the vault and has no old journal.
      // Capture its cache key before invalidation so a locked vault does not
      // prevent journaling the exit or inspecting the encrypted queue.
      await _retire(liveCache, null, onEvidence: onEvidence);
      return;
    }
    await _retireStored(
      await _readStoredCache(),
      await _readCleanupMarker(),
      onEvidence: onEvidence,
    );
  }

  Future<void> _retireStored(
    _StoredCache? stored,
    _CleanupMarker? marker, {
    void Function()? onEvidence,
  }) => _retire(
    stored?.cache,
    marker,
    deferred: stored != null && stored.tokens == null,
    onEvidence: onEvidence,
  );

  /// Remove credentials before wiping. If reading the queue fails, checkpoint
  /// only its owner and key instead, and leave the ciphertext for recovery.
  Future<void> _retire(
    _CacheOwner? owner,
    _CleanupMarker? marker, {
    bool deferred = false,
    void Function()? onEvidence,
  }) async {
    if (owner != null) {
      await _fenceRetirement();
      final account = owner.account;
      final tag = await _accountTag(account);
      final matching = marker?.accountTag == tag ? marker : null;
      // For a live login, a mismatched journal is a residue of the old
      // activate ordering. A credential-free checkpoint, however, is itself
      // proof of unfinished retirement and does not depend on the journal.
      if (marker == null || matching != null || deferred) {
        final journal = matching ?? _CleanupMarker(tag, _CleanupIntent.pending);
        if (matching == null) await _tryWriteCleanupMarker(journal);
        var intent = journal.intent;
        if (intent == _CleanupIntent.pending ||
            intent == _CleanupIntent.unknown) {
          late final _CleanupIntent evidence;
          try {
            evidence = await _queueIntent(account, owner.key);
          } on CleanupEvidenceUnavailable {
            if (!deferred) {
              try {
                await _persistRaw(
                  null,
                  null,
                  retryWrite: true,
                  deferred: owner,
                );
              } on Object catch (error) {
                // Keep the local recovery fences and suppress network work
                // while the queue evidence remains unavailable.
                throw CleanupEvidenceUnavailable(error);
              }
            }
            rethrow;
          }
          if (intent == _CleanupIntent.pending ||
              evidence == _CleanupIntent.explicit) {
            intent = evidence;
          }
        }
        _recordCleanupIntent(account, intent);
        if (intent != journal.intent) {
          await _tryWriteCleanupMarker(journal.withIntent(intent));
        }
      }
    }
    onEvidence?.call();
    if (owner != null || _hasUncommittedIntents) {
      await _persistRaw(null, null, retryWrite: true);
    }
    await _wipeDirectory();
    await _finishRetirement();
  }

  Future<({SecretKey? key, Set<String> accounts})> _decryptAccountSet(
    Map data, {
    required String keyField,
    required String boxField,
    required String aad,
  }) async {
    final keyRaw = data[keyField];
    final boxRaw = data[boxField];
    if (keyRaw == null && boxRaw == null) {
      return (key: null, accounts: <String>{});
    }
    if (keyRaw is! String || boxRaw is! String) {
      throw const FormatException('无效的撤回意图');
    }
    final key = SecretKey(base64Decode(keyRaw));
    final box = SecretBox.fromConcatenation(
      base64Decode(boxRaw),
      nonceLength: _cipher.nonceLength,
      macLength: _cipher.macAlgorithm.macLength,
    );
    final clear = await _cipher.decrypt(
      box,
      secretKey: key,
      aad: utf8.encode(aad),
    );
    final value = jsonDecode(utf8.decode(clear));
    if (value is! List || value.any((e) => e is! String)) {
      throw const FormatException('无效的撤回意图');
    }
    return (key: key, accounts: value.cast<String>().toSet());
  }

  Future<void> _loadWithdrawals(Map data) async {
    final explicit = await _decryptAccountSet(
      data,
      keyField: 'withdrawals_key',
      boxField: 'withdrawals',
      aad: 'withdrawals:v1',
    );
    final unknown = await _decryptAccountSet(
      data,
      keyField: 'unknown_withdrawals_key',
      boxField: 'unknown_withdrawals',
      aad: 'unknown-withdrawals:v1',
    );
    // Keep an in-memory intent that has not reached secure storage yet. The
    // persisted sets remain authoritative only for deciding whether a retry is
    // needed; they must not erase a newer local safety signal.
    _withdrawals.addAll(explicit.accounts);
    _persistedWithdrawals
      ..clear()
      ..addAll(explicit.accounts);
    if (_withdrawals.isEmpty) {
      _withdrawalsKey = null;
    } else if (explicit.key != null) {
      _withdrawalsKey = explicit.key;
    }
    _unknownWithdrawals.addAll(unknown.accounts);
    _persistedUnknownWithdrawals
      ..clear()
      ..addAll(unknown.accounts);
    if (_unknownWithdrawals.isEmpty) {
      _unknownWithdrawalsKey = null;
    } else if (unknown.key != null) {
      _unknownWithdrawalsKey = unknown.key;
    }
    // An explicit local confirmation is stronger evidence than an earlier
    // unreadable snapshot. Never leave one account in both account sets.
    _unknownWithdrawals.removeAll(_withdrawals);
    _persistedUnknownWithdrawals.removeAll(_persistedWithdrawals);
  }

  Future<T> _retryCacheRead<T>(Future<T> Function() action) async {
    Object? failure;
    StackTrace? stack;
    for (var attempt = 0; attempt < _cacheReadAttempts; attempt++) {
      try {
        return await action();
      } on PathNotFoundException {
        rethrow;
      } on FileSystemException catch (error, trace) {
        failure = error;
        stack = trace;
        if (attempt + 1 < _cacheReadAttempts) {
          await Future<void>.delayed(_retryDelay);
        }
      }
    }
    Error.throwWithStackTrace(failure!, stack!);
  }

  Future<void> _replaceSecret(String? value, {required bool retry}) async {
    final attempts = retry ? _cleanupWriteAttempts : 1;
    Object? failure;
    StackTrace? stack;
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        await _secret.replace(value);
        return;
      } on Object catch (error, trace) {
        failure = error;
        stack = trace;
        // A platform write can commit and then lose its acknowledgement.
        // Compare the exact envelope (including randomized ciphertext), never
        // treat a different snapshot as evidence that this write succeeded.
        try {
          if (await _secret.read() == value) return;
        } on Object {
          // A later attempt or transition will inspect the durable state.
        }
        if (attempt + 1 < attempts) {
          await Future<void>.delayed(_retryDelay);
        }
      }
    }
    Error.throwWithStackTrace(failure!, stack!);
  }

  Future<({SecretKey key, String keyRaw, String boxRaw})> _encryptAccountSet(
    Set<String> accounts,
    SecretKey? currentKey,
    String aad,
  ) async {
    final key = currentKey ?? await _cipher.newSecretKey();
    final values = accounts.toList()..sort();
    final box = await _cipher.encrypt(
      utf8.encode(jsonEncode(values)),
      secretKey: key,
      aad: utf8.encode(aad),
    );
    return (
      key: key,
      keyRaw: base64Encode(await key.extractBytes()),
      boxRaw: base64Encode(box.concatenation()),
    );
  }

  Future<void> _persistRaw(
    Tokens? tokens,
    SecretKey? key, {
    bool retryWrite = false,
    _CacheOwner? deferred,
  }) async {
    assert(deferred == null || (tokens == null && key == null));
    _unknownWithdrawals.removeAll(_withdrawals);
    final data = <String, dynamic>{};
    if (deferred != null) {
      data['cleanup_queue'] = {
        'account': deferred.account,
        'key': base64Encode(await deferred.key.extractBytes()),
      };
    } else if (tokens != null && key != null) {
      data['tokens'] = tokens.toJson();
      data['key'] = base64Encode(await key.extractBytes());
      if (_growthInvalidatedAccount == tokens.account) {
        data['growth_invalidated'] = true;
      }
    }
    SecretKey? nextWithdrawalsKey;
    if (_withdrawals.isNotEmpty) {
      final encoded = await _encryptAccountSet(
        _withdrawals,
        _withdrawalsKey,
        'withdrawals:v1',
      );
      nextWithdrawalsKey = encoded.key;
      data['withdrawals_key'] = encoded.keyRaw;
      data['withdrawals'] = encoded.boxRaw;
    }
    SecretKey? nextUnknownWithdrawalsKey;
    if (_unknownWithdrawals.isNotEmpty) {
      final encoded = await _encryptAccountSet(
        _unknownWithdrawals,
        _unknownWithdrawalsKey,
        'unknown-withdrawals:v1',
      );
      nextUnknownWithdrawalsKey = encoded.key;
      data['unknown_withdrawals_key'] = encoded.keyRaw;
      data['unknown_withdrawals'] = encoded.boxRaw;
    }
    await _replaceSecret(
      data.isEmpty ? null : jsonEncode(data),
      retry: retryWrite,
    );
    _withdrawalsKey = nextWithdrawalsKey;
    _unknownWithdrawalsKey = nextUnknownWithdrawalsKey;
    _persistedWithdrawals
      ..clear()
      ..addAll(_withdrawals);
    _persistedUnknownWithdrawals
      ..clear()
      ..addAll(_unknownWithdrawals);
  }

  Future<void> _persistCurrent() => _persistRaw(_tokens, _key);

  Future<void> restore() => _transition((generation) async {
    final stored = await _readStoredCache();
    final tokens = stored?.tokens;
    final marker = await _readCleanupMarker();
    if (stored == null ||
        tokens == null ||
        (marker != null &&
            marker.accountTag == await _accountTag(tokens.account)) ||
        await _retirementNeedsRecovery()) {
      await _retireStored(stored, marker);
      _growthInvalidatedAccount = null;
      return;
    }
    if (marker != null) {
      // Frozen versions could commit B before deleting A's journal. B was
      // not exposed and A's recoverable outbox was included in that write.
      // Clean the residue before exposing B; a failed wipe can be retried.
      await _wipeDirectory();
    }
    await _directory.create(recursive: true);
    await for (final entry in _directory.list()) {
      if (entry is File &&
          (entry.path.endsWith('.new') ||
              (entry.path.endsWith('.audio') && await _expired(entry)))) {
        await entry.delete();
      }
    }
    final hasFence = await _hasGrowthDeletionFence(tokens.account);
    _check(generation);
    _key = stored.cache.key;
    _tokens = tokens;
    if (hasFence) {
      _growthInvalidatedAccount = tokens.account;
    }
    _identity.value = AccountScope._(tokens.account);
  });

  Future<AccountScope> activate(Tokens tokens) {
    final previous = _liveCache;
    return _transition((generation) async {
      // Do not install a new login while the previous retirement journal can
      // still be present. Retries first converge to a logged-out snapshot.
      await _retireCurrentOrStored(previous);
      final key = await _cipher.newSecretKey();
      final hasFence = await _hasGrowthDeletionFence(tokens.account);
      _check(generation);
      _growthInvalidatedAccount = hasFence ? tokens.account : null;
      await _persistRaw(tokens, key);
      _check(generation);
      _tokens = tokens;
      _key = key;
      return _identity.value = AccountScope._(tokens.account);
    });
  }

  Future<void> rotate(AccountScope scope, Tokens tokens) => _serial(() async {
    require(scope);
    if (tokens.account != scope.account) throw SessionChanged();
    await _persistRaw(tokens, _key!);
    require(scope);
    _tokens = tokens;
  });
  Future<void> clear() {
    final previous = _liveCache;
    return _transition((_) => _retireCurrentOrStored(previous));
  }

  /// Starts the same retirement transaction as an auth rejection. Snapshot
  /// the withdrawal evidence in that transaction, not from a later login.
  ({
    LogoutRound round,
    Future<({Object? error, LogoutWithdrawalEvidence withdrawal})> cleanup,
  })
  beginLogout(AccountScope scope) {
    require(scope);
    final round = LogoutRound._(scope, _generation + 1, _roundOwner);
    final previous = _liveCache;
    final cleanup = _transition((_) async {
      var withdrawal = LogoutWithdrawalEvidence.unavailable;
      try {
        await _retireCurrentOrStored(
          previous,
          onEvidence: () => withdrawal = _logoutEvidence(scope),
        );
        return (error: null, withdrawal: withdrawal);
      } on CleanupEvidenceUnavailable catch (error) {
        return (error: error, withdrawal: LogoutWithdrawalEvidence.unavailable);
      } on Object catch (error) {
        if (withdrawal == LogoutWithdrawalEvidence.unavailable) {
          final known = _logoutEvidence(scope);
          if (known != LogoutWithdrawalEvidence.none) withdrawal = known;
        }
        return (error: error, withdrawal: withdrawal);
      }
    });
    return (round: round, cleanup: cleanup);
  }

  LogoutWithdrawalEvidence _logoutEvidence(AccountScope scope) {
    if (hasWithdrawalIntent(scope)) return LogoutWithdrawalEvidence.explicit;
    if (hasUnknownWithdrawal(scope)) return LogoutWithdrawalEvidence.unknown;
    return LogoutWithdrawalEvidence.none;
  }

  bool isCurrentLogout(LogoutRound round) =>
      identical(round._owner, _roundOwner) &&
      _generation == round._generation &&
      _active == null;

  Future<void> acknowledgeLogoutWithdrawal(LogoutRound round) =>
      _serial(() async {
        if (isCurrentLogout(round)) await _removeWithdrawalIntent(round.scope);
      });

  /// A withdrawal intent is a minimal encrypted outbox entry, separate from
  /// the session and collection queue. It may outlive logout, but it is never
  /// sent using another account's credentials.
  bool hasWithdrawalIntent(AccountScope scope) =>
      _withdrawals.contains(scope.account);

  /// An unknown queue result is not proof of withdrawal. It blocks health
  /// collection until this account's owner explicitly resolves it.
  bool hasUnknownWithdrawal(AccountScope scope) =>
      _unknownWithdrawals.contains(scope.account);

  Future<void> addWithdrawalIntent(AccountScope scope) => _serial(() async {
    require(scope);
    final added = _withdrawals.add(scope.account);
    final resolvedUnknown = _unknownWithdrawals.remove(scope.account);
    // A failed outbox write leaves the intent in memory, but it must not make
    // later retries look durable. Retry the encrypted write until this account
    // is confirmed in the persisted set.
    if (!added &&
        !resolvedUnknown &&
        _persistedWithdrawals.contains(scope.account) &&
        !_persistedUnknownWithdrawals.contains(scope.account)) {
      return;
    }
    await _persistCurrent();
  });

  /// Records the account owner's explicit decision for an unknown queue result.
  ///
  /// [withdraw] promotes the uncertainty to the reportable withdrawal outbox;
  /// false clears only the uncertainty so a later explicit enable may collect
  /// again. In both cases the decision is account-scoped and durable.
  Future<void> resolveUnknownWithdrawal(
    AccountScope scope, {
    required bool withdraw,
  }) {
    if (withdraw) return addWithdrawalIntent(scope);
    return _serial(() async {
      require(scope);
      final removed = _unknownWithdrawals.remove(scope.account);
      if (!removed && !_persistedUnknownWithdrawals.contains(scope.account)) {
        return;
      }
      final previousKey = _unknownWithdrawalsKey;
      if (_unknownWithdrawals.isEmpty) _unknownWithdrawalsKey = null;
      try {
        await _persistCurrent();
      } on Object {
        _unknownWithdrawals.add(scope.account);
        _unknownWithdrawalsKey = previousKey;
        rethrow;
      }
    });
  }

  Future<_CleanupIntent> _queueIntent(String account, SecretKey key) async {
    const kind = CacheKind.queue;
    const id = healthQueueKey;
    final file = await _file(kind, id);
    final List<int> ciphertext;
    try {
      // An actual read distinguishes a missing path from permission or I/O
      // errors; a false existence check is not proof of absence.
      ciphertext = await _retryCacheRead(() => _readCache(file));
    } on PathNotFoundException {
      return _CleanupIntent.absent;
    } on Object {
      throw const CleanupEvidenceUnavailable();
    }
    try {
      final box = SecretBox.fromConcatenation(
        ciphertext,
        nonceLength: _cipher.nonceLength,
        macLength: _cipher.macAlgorithm.macLength,
      );
      final bytes = await _cipher.decrypt(
        box,
        secretKey: key,
        aad: utf8.encode('$account:${kind.name}:$id'),
      );
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map<String, dynamic>) return _CleanupIntent.unknown;
      if (value['mode'] == 'withdraw' && value['withdrawal'] == 'explicit') {
        return _CleanupIntent.explicit;
      }
      // The only known non-withdrawal tombstone is the setup state written
      // before collection starts. Any other readable state is not proof.
      if (value['mode'] == 'withdraw' && value['withdrawal'] == null) {
        return _CleanupIntent.setup;
      }
      return _CleanupIntent.unknown;
    } on Object {
      return _CleanupIntent.unknown;
    }
  }

  Future<void> removeWithdrawalIntent(AccountScope scope) => _serial(() async {
    require(scope);
    await _removeWithdrawalIntent(scope);
  });

  Future<void> _removeWithdrawalIntent(AccountScope scope) async {
    final removedWithdrawal = _withdrawals.remove(scope.account);
    final removedUnknown = _unknownWithdrawals.remove(scope.account);
    if (!removedWithdrawal &&
        !removedUnknown &&
        !_persistedWithdrawals.contains(scope.account) &&
        !_persistedUnknownWithdrawals.contains(scope.account)) {
      return;
    }
    final previousWithdrawalsKey = _withdrawalsKey;
    final previousUnknownKey = _unknownWithdrawalsKey;
    if (_withdrawals.isEmpty) _withdrawalsKey = null;
    if (_unknownWithdrawals.isEmpty) _unknownWithdrawalsKey = null;
    try {
      await _persistCurrent();
    } on Object {
      if (removedWithdrawal) _withdrawals.add(scope.account);
      if (removedUnknown) _unknownWithdrawals.add(scope.account);
      _withdrawalsKey = previousWithdrawalsKey;
      _unknownWithdrawalsKey = previousUnknownKey;
      rethrow;
    }
  }

  Future<bool> _expired(File file) async => !DateTime.now().isBefore(
    (await file.lastModified()).add(const Duration(days: 3)),
  );

  Future<File> _file(CacheKind kind, String id) async {
    final name = await Sha256().hash(utf8.encode('${kind.name}:$id'));
    final suffix = kind == CacheKind.recording ? '.audio' : '';
    return File('${_directory.path}/${base64UrlEncode(name.bytes)}$suffix');
  }

  /// The account journal and login envelope fence an invalidated snapshot
  /// across restarts, even if the ciphertext could not be removed.
  bool growthCacheInvalidated(AccountScope scope) {
    require(scope);
    return _growthInvalidatedAccount == scope.account;
  }

  int growthCacheRevision(AccountScope scope) {
    require(scope);
    return _growthRevision;
  }

  Future<List<int>?> getGrowthCache(AccountScope scope, String id) =>
      _serial(() async {
        require(scope);
        if (_growthInvalidatedAccount == scope.account) return null;
        return _readEncryptedCache(scope, CacheKind.continuation, id);
      });

  Future<bool> putGrowthCache(
    AccountScope scope,
    String id,
    List<int> bytes, {
    required int revision,
    required bool recoverInvalidated,
  }) => _serial(() async {
    require(scope);
    if (revision != _growthRevision) return false;
    final invalidated = _growthInvalidatedAccount == scope.account;
    if (invalidated && !recoverInvalidated) return false;
    final pendingDeletions = invalidated
        ? await _readGrowthDeletionFence(scope.account)
        : null;
    if (pendingDeletions?.isNotEmpty == true) return false;
    await _writeCache(scope, CacheKind.continuation, id, bytes);
    if (recoverInvalidated && invalidated) {
      // The cache must already contain the authoritative snapshot before the
      // durable marker is lifted. A failed write leaves the marker in place.
      require(scope);
      if (revision != _growthRevision) return false;
      if (pendingDeletions != null) {
        await _clearGrowthDeletionFence(scope.account);
      }
      _growthInvalidatedAccount = null;
      try {
        await _persistCurrent();
      } on Object {
        _growthInvalidatedAccount = scope.account;
        rethrow;
      }
    }
    return true;
  });

  void _invalidateGrowth(AccountScope scope, void Function()? onInvalidated) {
    _growthRevision++;
    _growthInvalidatedAccount = scope.account;
    onInvalidated?.call();
  }

  /// Persists an account-scoped pending deletion before the caller may send a
  /// remote DELETE. Unlike the login envelope and encrypted cache, this fence
  /// lives in a separate support directory and survives both storage failures.
  Future<GrowthDeletion> prepareGrowthDeletion(
    AccountScope scope, {
    required String contactId,
    GrowthDeletion? retry,
    void Function()? onInvalidated,
  }) {
    require(scope);
    return _serial(() async {
      require(scope);
      final pending = await _readGrowthDeletionFence(scope.account) ?? {};
      if (contactId.isEmpty ||
          (retry != null && retry.contactId != contactId) ||
          pending[contactId] != retry?.operationId) {
        throw StateError('请先核对该关系人的删除结果');
      }
      final operationId = base64UrlEncode(_cipher.newNonce());
      pending[contactId] = operationId;
      require(scope);
      await _writeGrowthDeletionFence(scope.account, pending);
      require(scope);
      _invalidateGrowth(scope, onInvalidated);
      return (contactId: contactId, operationId: operationId);
    });
  }

  Future<List<GrowthDeletion>> pendingGrowthDeletions(AccountScope scope) =>
      _serial(() async {
        require(scope);
        final pending = await _readGrowthDeletionFence(scope.account);
        require(scope);
        return [
          if (pending != null)
            for (final entry in pending.entries)
              (contactId: entry.key, operationId: entry.value),
        ];
      });

  /// Resolve only the operation for which the caller has deletion evidence or
  /// an explicit decision to abandon after verifying the contact still exists.
  Future<bool> resolveGrowthDeletion(
    AccountScope scope,
    String id, {
    required GrowthDeletion operation,
    void Function()? onInvalidated,
  }) => _serial(() async {
    require(scope);
    final Map<String, String>? pending;
    try {
      pending = await _readGrowthDeletionFence(scope.account);
    } on Object {
      require(scope);
      _invalidateGrowth(scope, onInvalidated);
      rethrow;
    }
    require(scope);
    if (pending == null ||
        pending[operation.contactId] != operation.operationId) {
      return false;
    }
    _invalidateGrowth(scope, onInvalidated);
    pending.remove(operation.contactId);
    await _writeGrowthDeletionFence(scope.account, pending);
    require(scope);
    await _clearGrowthCacheLocked(scope, id);
    return true;
  });

  /// Marks the revision and tombstone synchronously, then removes the exact
  /// cache file without trusting [File.exists]. The callback runs after the
  /// in-memory fence is installed so a reload triggered by it can publish a
  /// fresh authoritative snapshot and recover the tombstone. Persistence and
  /// deletion errors are still reported, even though the in-memory fence stays.
  Future<void> clearGrowthCache(
    AccountScope scope,
    String id, {
    void Function()? onInvalidated,
  }) {
    require(scope);
    _invalidateGrowth(scope, onInvalidated);
    return _serial(() async {
      require(scope);
      await _clearGrowthCacheLocked(scope, id);
    });
  }

  Future<void> _clearGrowthCacheLocked(AccountScope scope, String id) async {
    Object? persistenceError;
    StackTrace? persistenceStack;
    try {
      await _persistCurrent();
    } on Object catch (error, stackTrace) {
      persistenceError = error;
      persistenceStack = stackTrace;
    }

    Object? deletionError;
    StackTrace? deletionStack;
    try {
      await _removeCacheFile(CacheKind.continuation, id);
    } on Object catch (error, stackTrace) {
      deletionError = error;
      deletionStack = stackTrace;
    }

    if (persistenceError != null) {
      Error.throwWithStackTrace(persistenceError, persistenceStack!);
    }
    if (deletionError != null) {
      Error.throwWithStackTrace(deletionError, deletionStack!);
    }
  }

  Future<List<int>?> _readEncryptedCache(
    AccountScope scope,
    CacheKind kind,
    String id,
  ) async {
    final file = await _file(kind, id);
    if (!await file.exists()) return null;
    if (kind == CacheKind.recording && await _expired(file)) {
      await _deleteFile(file);
      return null;
    }
    final box = SecretBox.fromConcatenation(
      await file.readAsBytes(),
      nonceLength: _cipher.nonceLength,
      macLength: _cipher.macAlgorithm.macLength,
    );
    require(scope);
    final bytes = await _cipher.decrypt(
      box,
      secretKey: _key!,
      aad: utf8.encode('${scope.account}:${kind.name}:$id'),
    );
    require(scope);
    return bytes;
  }

  Future<void> _writeCache(
    AccountScope scope,
    CacheKind kind,
    String id,
    List<int> bytes,
  ) async {
    final file = await _file(kind, id);
    require(scope);
    final box = await _cipher.encrypt(
      bytes,
      secretKey: _key!,
      aad: utf8.encode('${scope.account}:${kind.name}:$id'),
    );
    final tmp = File('${file.path}.new');
    await tmp.writeAsBytes(box.concatenation(), flush: true);
    require(scope);
    await tmp.rename(file.path);
  }

  Future<void> _deleteVerified(File file, CacheDelete delete) async {
    try {
      await delete(file);
    } on PathNotFoundException catch (error, stackTrace) {
      try {
        await _readCache(file);
      } on PathNotFoundException {
        // A real missing path is idempotent.
        return;
      } on Object {
        Error.throwWithStackTrace(error, stackTrace);
      }
      // The delete callback claimed absence, but the ciphertext was readable.
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _deleteFile(File file) => _deleteVerified(file, _deleteCache);

  Future<void> _removeCacheFile(CacheKind kind, String id) async {
    final file = await _file(kind, id);
    // Remove a partially written sibling too. Never guard with exists(): an
    // inaccessible file may falsely report absence.
    await _deleteFile(file);
    await _deleteFile(File('${file.path}.new'));
  }

  Future<void> put(
    AccountScope scope,
    CacheKind kind,
    String id,
    List<int> bytes,
  ) => _serial(() async {
    require(scope);
    await _writeCache(scope, kind, id, bytes);
  });
  Future<List<int>?> get(AccountScope scope, CacheKind kind, String id) =>
      _serial(() async {
        require(scope);
        return _readEncryptedCache(scope, kind, id);
      });
  Future<void> remove(AccountScope scope, CacheKind kind, String id) =>
      _serial(() async {
        require(scope);
        await _removeCacheFile(kind, id);
      });
}
