import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import '../../core/api.dart';
import '../../core/app_op.g.dart';
import '../../core/consent.dart';
import '../../core/endpoints.g.dart';
import '../../core/session.dart';
import '../../core/transport.dart';
import 'platform.dart';
import 'windows.dart';

class _ExpiredDuringCheck implements Exception {
  const _ExpiredDuringCheck();
}

class _UploadGateClosed implements Exception {
  final bool denied;
  const _UploadGateClosed(this.denied);
}

/// A checked T28 collection boundary with synchronous local invalidation.
class HealthReplayLease {
  const HealthReplayLease({
    required this.collectionFrom,
    required this.isCurrent,
  });

  final int collectionFrom;
  final bool Function() isCurrent;
}

/// One owner per authenticated foreground session. The durable retry queue is a
/// range of slots, NOT cached measurements: HealthKit hides individual grants.
/// Retrying queries the OS again, so withdrawn types cannot leak from a cache.
class HealthSync {
  HealthSync(
    this.api,
    this.scope,
    this.gate,
    this.port, {
    int Function()? clock,
  }) : clock = clock ?? _now {
    api.sessions.identity.addListener(_identityChanged);
  }
  void _identityChanged() {
    if (!identical(api.sessions.active, scope)) close();
  }

  static int _now() => DateTime.now().millisecondsSinceEpoch;
  final AppApi api;
  final AccountScope scope;
  final ConsentGate gate;
  final HealthPort port;
  final int Function() clock;
  static const key = AppApi.healthQueueKey;
  static const _disabled = {'mode': 'off'};
  static const _sources = {'apple_history', 'health_connect', 'huawei_history'};
  static const _withdrawal = 'withdrawal';
  static const _explicitWithdrawal = 'explicit';
  int _epoch = 0;
  final _replayRevision = ValueNotifier(0);
  int _replayCheckSequence = 0;
  int _latestApprovedReplayCheck = 0;
  (Object?, Object?, Object?, Object?, Object?)? _replayState;
  bool _busy = false, _active = true, _restored = false;
  bool _prompting = false, _promptInterrupted = false;
  int? _promptGeneration;
  Timer? _expiry;
  Json? _volatileState;
  final mode = ValueNotifier<String?>(null);

  /// Signals synchronous invalidation of leases held by mounted replay pages.
  ValueListenable<int> get replayChanges => _replayRevision;

  void _invalidateReplay() => _replayRevision.value++;

  Future<void> _mutations = Future.value();
  Future<T> _ordered<T>(Future<T> Function() action) {
    final f = _mutations.then((_) => action());
    _mutations = f.then<void>((_) {}, onError: (Object _) {});
    return f;
  }

  Future<Json> state() async {
    // A real withdrawal outbox entry is authoritative even if this owner has
    // a stale in-memory state. An unknown queue is not proof of withdrawal,
    // but it must keep collection stopped until the account owner decides.
    if (api.sessions.hasWithdrawalIntent(scope)) {
      return {'mode': 'withdraw'};
    }
    if (api.sessions.hasUnknownWithdrawal(scope)) {
      return {'mode': 'unknown'};
    }
    final volatile = _volatileState;
    if (volatile != null) return Map.of(volatile);
    final bytes = await api.sessions.get(scope, CacheKind.queue, key);
    return bytes == null
        ? Map.of(_disabled)
        : jsonDecode(utf8.decode(bytes)) as Json;
  }

  /// Read-only collection boundary for local replay. This deliberately does
  /// not tick, save, upload, request permission, or start collection. Every
  /// call re-runs the same consent/grant, membership, foreground, and source
  /// checks used by collection, so a replay read cannot outlive a regrant.
  Future<int?> replayCollectionFrom() async =>
      (await replayLease())?.collectionFrom;

  Future<HealthReplayLease?> replayLease() async {
    if (!_active || _busy || !_restored) return null;
    final gen = _epoch;
    final revision = _replayRevision.value;
    final check = ++_replayCheckSequence;
    try {
      final s = await state();
      _check(gen);
      final paidUntil = s['paid_until'];
      final grant = s['grant'];
      final boundary = s['collection_from'];
      if (s['mode'] != 'on' ||
          paidUntil is! int ||
          paidUntil <= clock() ||
          grant is! String ||
          boundary is! int ||
          !_sources.contains(s['source'])) {
        return null;
      }

      var allowed = false;
      var denied = false;
      DateTime? expiry;
      final granted = await gate.readIfAllowed(
        scope,
        CollectionPurpose.health,
        systemGranted: port.queryable,
        acceptsGrant: (record) =>
            record['version'] == '2026-11' && record['updated_at'] == grant,
        onDenied: () => denied = true,
        onExpiry: (value) => expiry = value,
        beginRead: () {
          _check(gen);
          if (!_active || _busy || !_restored || clock() >= paidUntil) {
            throw StateError('健康回放授权不可用');
          }
          api.sessions.require(scope);
          allowed = true;
        },
      );
      _check(gen);
      // A delayed denial must not invalidate a newer approved replay.
      if (denied &&
          revision == _replayRevision.value &&
          check > _latestApprovedReplayCheck) {
        _invalidateReplay();
      }
      final expires = expiry;
      if (!granted ||
          !allowed ||
          denied ||
          expires == null ||
          !_active ||
          _busy ||
          !_restored ||
          clock() >= paidUntil) {
        return null;
      }

      // A concurrent tick may have paused collection or advanced the boundary
      // while the gate query was in flight. Only return the exact state that
      // passed the gate; the replay port validates this again after every
      // asynchronous native read.
      final after = await state();
      _check(gen);
      bool isCurrent() =>
          _active &&
          _restored &&
          gen == _epoch &&
          revision == _replayRevision.value &&
          identical(api.sessions.active, scope) &&
          !api.sessions.hasWithdrawalIntent(scope) &&
          !api.sessions.hasUnknownWithdrawal(scope) &&
          clock() < paidUntil &&
          expires.isAfter(DateTime.now());
      if (after['mode'] != 'on' ||
          after['grant'] != grant ||
          after['collection_from'] != boundary ||
          after['paid_until'] != paidUntil ||
          after['source'] != s['source'] ||
          _busy ||
          !isCurrent()) {
        return null;
      }
      _latestApprovedReplayCheck = max(_latestApprovedReplayCheck, check);
      return HealthReplayLease(
        collectionFrom: ceilSlot(boundary),
        isCurrent: isCurrent,
      );
    } on Object {
      return null;
    }
  }

  Future<void> _save(Json s) async {
    final snapshot = Map<String, dynamic>.of(s);
    final savingMode = snapshot['mode'] as String;
    final replayState = (
      savingMode,
      snapshot['grant'],
      snapshot['collection_from'],
      snapshot['source'],
      snapshot['paid_until'],
    );
    _volatileState = snapshot;
    if (replayState != _replayState) {
      _replayState = replayState;
      _invalidateReplay();
    }
    mode.value = savingMode;
    try {
      await api.sessions.put(
        scope,
        CacheKind.queue,
        key,
        utf8.encode(jsonEncode(snapshot)),
      );
      if (identical(_volatileState, snapshot)) _volatileState = null;
    } on Object {
      // Keep the in-memory state authoritative until a later durable save.
      rethrow;
    }
  }

  MobileEndpoints get _wire => MobileEndpoints(api);
  void _check(int gen) {
    api.sessions.require(scope);
    if (gen != _epoch) throw StateError('操作已停止');
  }

  Future<bool> member() async {
    final r = await _wire.getEntitlements(scope: scope);
    return r['tier'] == 'member' &&
        (DateTime.tryParse(
              r['expires_at'] as String? ?? '',
            )?.isAfter(DateTime.now()) ??
            false);
  }

  Future<Json> _consent(bool yes) => _wire.setConsent(
    scope: scope,
    purpose: 'health',
    body: {'granted': yes, 'version': '2026-11'},
  );
  // A grant request may have failed before it reached T05. Absence already
  // satisfies withdrawal; otherwise revoke the actual current policy version.
  Future<void> _syncWithdrawal(int gen) async {
    String? cursor;
    final seen = <String>{};
    do {
      final page = await _wire.listConsents(scope: scope, cursor: cursor);
      _check(gen);
      for (final row in page['items'] as List) {
        if (row['purpose'] != 'health') continue;
        if (row['granted'] == true) {
          final record = await _wire.setConsent(
            scope: scope,
            purpose: 'health',
            body: {'granted': false, 'version': row['version'] as String},
          );
          if (record['purpose'] != 'health' || record['granted'] != false) {
            throw const FormatException();
          }
        } else if (row['granted'] != false) {
          throw const FormatException();
        }
        return;
      }
      cursor = page['next_cursor'] as String?;
      if (cursor != null && !seen.add(cursor)) throw const FormatException();
    } while (cursor != null);
  }

  Future<void> _flushWithdrawal(int gen) async {
    await _syncWithdrawal(gen);
    _check(gen);
    await api.sessions.removeWithdrawalIntent(scope);
    _check(gen);
  }

  bool _isExplicitWithdrawal(Json state) =>
      state['mode'] == 'withdraw' && state[_withdrawal] == _explicitWithdrawal;

  Future<void> _ensureWithdrawalIntent(int gen) async {
    // Sessions.addWithdrawalIntent retries an in-memory intent that has not
    // yet reached the encrypted outbox; only a confirmed write is a no-op.
    await api.sessions.addWithdrawalIntent(scope);
    _check(gen);
  }

  // Called only for an explicit confirmation, never on page load/resume.
  Future<void> enable() {
    final gen = ++_epoch;
    _invalidateReplay();
    return _ordered(() async {
      if (api.sessions.hasUnknownWithdrawal(scope)) {
        throw StateError('请先确认上次健康授权状态');
      }
      if (!await member()) throw StateError('仅有效会员可开启');
      _check(gen);
      final source = await port.source();
      _check(gen);
      if (!_sources.contains(source)) {
        throw StateError('此设备没有可用通道');
      }
      final before = await state();
      if (before['mode'] == 'withdraw' &&
          (api.sessions.hasWithdrawalIntent(scope) ||
              _isExplicitWithdrawal(before))) {
        await _ensureWithdrawalIntent(gen);
        await _flushWithdrawal(gen);
      }
      _check(gen);
      // A crash or denial during setup leaves a local tombstone; it is not a
      // server withdrawal unless an explicit withdrawal intent already exists.
      await _save({'mode': 'withdraw'});
      _check(gen);
      final record = await _consent(true);
      _check(gen);
      final stamp = record['updated_at'];
      if (record['purpose'] != 'health' ||
          record['granted'] != true ||
          stamp is! String) {
        throw const FormatException();
      }
      Future<bool>? prompt;
      DateTime? paidUntil;
      await gate.readIfAllowed(
        scope,
        CollectionPurpose.health,
        systemGranted: () async => true,
        acceptsGrant: (r) =>
            r['version'] == '2026-11' && r['updated_at'] == stamp,
        onExpiry: (expiry) => paidUntil = expiry,
        beginRead: () {
          _check(gen);
          prompt = port
              .request(
                onSystemPrompt: () {
                  _check(gen);
                  if (!_active) throw StateError('应用已离开前台');
                  _prompting = true;
                  _promptGeneration = gen;
                  _promptInterrupted = false;
                },
              )
              .whenComplete(() {
                if (_promptGeneration == gen) {
                  _prompting = false;
                  _promptGeneration = null;
                }
              });
        },
      );
      if (await prompt != true) throw StateError('未开启健康访问');
      _check(gen);
      final promptInterrupted = _promptInterrupted;
      _promptInterrupted = false;
      if (paidUntil?.isAfter(DateTime.now()) != true) {
        throw StateError('会员资格已过期');
      }
      // A system permission sheet can make the app briefly inactive. Keep the
      // granted result only as a pending gate; a resumed foreground tick must
      // re-check every condition before establishing a collection boundary.
      if (promptInterrupted || !_active) {
        await _save({
          'mode': 'pending',
          'paid_until': paidUntil!.millisecondsSinceEpoch,
          'grant': stamp,
          'source': source,
        });
        _check(gen);
        return;
      }
      // The durable server stamp is not a collection boundary: consent can
      // predate membership, a foreground session, or a re-enable after a gap.
      // Define the boundary only after every gate and the OS prompt succeeded.
      final collectionFrom = ceilSlot(clock());
      await _save({
        'mode': 'on',
        'paid_until': paidUntil!.millisecondsSinceEpoch,
        'grant': stamp,
        'source': source,
        'collection_from': collectionFrom,
        'cursor': collectionFrom,
      });
      _check(gen);
      _restored = true;
    });
  }

  void _halt() {
    _epoch++;
    _invalidateReplay();
    _prompting = false;
    _promptGeneration = null;
    _promptInterrupted = false;
    _expiry?.cancel();
    unawaited(port.stop().catchError((_) {}));
  }

  Future<void> _withdraw(int gen) async {
    Object? failure;
    try {
      await _ensureWithdrawalIntent(gen);
    } catch (error) {
      failure = error;
    }
    try {
      await _save({'mode': 'withdraw', _withdrawal: _explicitWithdrawal});
    } catch (error) {
      failure ??= error;
    }
    if (failure != null) throw failure;
    _check(gen);
    await _flushWithdrawal(gen);
    _check(gen);
    await _save(Map.of(_disabled));
  }

  Future<void> withdraw() {
    _halt();
    final gen = _epoch;
    // Seal synchronously. If the encrypted write fails, state() still reports
    // withdrawal and tick() cannot fall back to the old on-disk 'on' state.
    _volatileState = {'mode': 'withdraw'};
    mode.value = 'withdraw';
    return _ordered(() => _withdraw(gen));
  }

  /// Resolves an unknown queue only after the account owner chooses. Keeping
  /// the local off state is memory-only: writing it to the unreadable queue
  /// would destroy the evidence needed to keep a later logout fail-closed.
  Future<void> resolveUnknown({required bool withdraw}) {
    _halt();
    final gen = _epoch;
    _volatileState = withdraw ? {'mode': 'withdraw'} : Map.of(_disabled);
    mode.value = withdraw ? 'withdraw' : 'off';
    return _ordered(() async {
      await api.sessions.resolveUnknownWithdrawal(scope, withdraw: withdraw);
      _check(gen);
      if (withdraw) await _withdraw(gen);
    });
  }

  void suspend() {
    _active = false;
    _restored = false;
    _halt();
  }

  void inactive() {
    _active = false;
    _restored = false;
    // An OS permission sheet commonly reports inactive while its result is
    // still valid. Stop collection, but keep that one prompt operation alive.
    if (!_prompting || _promptGeneration != _epoch) {
      _halt();
      return;
    }
    // Even if focus returns before the vendor result, that result belongs to
    // the interrupted foreground session. It may only seed pending state.
    _promptInterrupted = true;
  }

  void close() {
    api.sessions.identity.removeListener(_identityChanged);
    _active = false;
    _halt();
    // A closed owner must not keep an in-memory collection state after the
    // account is cleared. The encrypted withdrawal outbox belongs to Sessions.
    _volatileState = null;
    mode.value = null;
  }

  void resume() {
    _active = true;
  }

  Future<void> tick() async {
    if (_busy || !_active) return;
    _busy = true;
    final gen = _epoch;
    try {
      await _mutations;
      _check(gen);
      final s = await state();
      _check(gen);
      if (s['mode'] == 'unknown') {
        // Unknown is not consent or withdrawal. Stop every local operation and
        // wait for the owner's explicit choice from the settings page.
        _halt();
        return;
      }
      if (s['mode'] == 'withdraw') {
        if (api.sessions.hasWithdrawalIntent(scope) ||
            _isExplicitWithdrawal(s)) {
          await withdraw();
        } else {
          // The setup tombstone is not a user withdrawal. It only prevents a
          // crash/denial during setup from being mistaken for collection.
          _halt();
          await _save(Map.of(_disabled));
        }
        return;
      }
      if (s['mode'] == 'pending') {
        await _activatePending(gen, s);
        return;
      }
      if (s['mode'] != 'on') return;
      final collectionPaidUntil = s['paid_until'] as int;
      if (collectionPaidUntil <= clock()) {
        await _stopForGate(true);
        return;
      }
      if (!await port.queryable()) {
        _check(gen);
        await withdraw();
        return;
      }
      _check(gen);
      // A foreground resume is the only reliable boundary after an OS grant
      // may have been revoked and re-granted while we were not observing it.
      // Re-establish the boundary only after a complete gate passes, then
      // return without reading. A network failure must not advance it early.
      if (!_restored) {
        var rereadAllowed = false;
        var denied = false;
        final allowed = await gate.readIfAllowed(
          scope,
          CollectionPurpose.health,
          systemGranted: port.queryable,
          acceptsGrant: (r) =>
              r['version'] == '2026-11' && r['updated_at'] == s['grant'],
          onDenied: () => denied = true,
          onExpiry: (expires) => _trackExpiry(gen, s, expires),
          beginRead: () {
            _check(gen);
            rereadAllowed = true;
          },
        );
        if (!allowed || !rereadAllowed) {
          _check(gen);
          await _stopForGate(denied);
          return;
        }
        _check(gen);
        final boundary = ceilSlot(clock());
        s['collection_from'] = boundary;
        s.remove('pending_end');
        s['cursor'] = max(s['cursor'] as int? ?? 0, boundary);
        await _save(s);
        _check(gen);
        _restored = true;
        return;
      }
      _check(gen);
      final collectionFrom = s['collection_from'];
      if (collectionFrom is! int) {
        // States from a pre-boundary build must be explicitly re-enabled, never
        // interpreted using the server consent timestamp.
        await _stopForGate(true);
        return;
      }
      final cursor = s['cursor'] as int;
      final from = max(
        max(cursor, collectionFrom),
        floorSlot(clock() - 86400000),
      );
      if ((s['pending_end'] as int? ?? from + 1) <= from) {
        s.remove('pending_end');
      }
      final end = min(
        (s['pending_end'] as int?) ?? floorSlot(clock() - 300000),
        from + 600000,
      );
      var denied = false;
      Future<bool> guarded(void Function() begin) async {
        try {
          return await gate.readIfAllowed(
            scope,
            CollectionPurpose.health,
            systemGranted: port.queryable,
            forHealthUpload: true,
            acceptsGrant: (r) =>
                r['version'] == '2026-11' && r['updated_at'] == s['grant'],
            onDenied: () => denied = true,
            onExpiry: (expires) => _trackExpiry(gen, s, expires),
            beginRead: () {
              _check(gen);
              // The entitlement request may have returned a renewal response
              // after the old paid-through boundary passed. Never start a
              // native read (or send its summary) using that renewed view.
              if (clock() >= collectionPaidUntil) {
                throw const _ExpiredDuringCheck();
              }
              begin();
            },
          );
        } on _ExpiredDuringCheck {
          denied = true;
          return false;
        }
      }

      if (end <= from) return;
      // Persist just the retry bounds before the first native sample is read.
      s['pending_end'] = end;
      await _save(s);
      _check(gen);
      Future<List<List>>? reading;
      if (!await guarded(() {
        reading = port.read(from, end);
      })) {
        _check(gen);
        await _stopForGate(denied);
        return;
      }
      final rows = await reading!;
      _check(gen);
      for (final window in healthWindows(
        s['source'],
        from,
        end,
        rows,
        collectionFrom: collectionFrom,
      )) {
        late Tokens gateTokens;
        void checkGateTokens() {
          // Sessions replaces this immutable snapshot on every rotation.
          if (!identical(gateTokens, api.sessions.require(scope))) {
            throw const _UploadGateClosed(false);
          }
        }

        try {
          await api
              .bytesGuarded(
                AppOp.uploadWindow,
                scope: scope,
                body: window,
                preserveSessionOnUnconfirmedRefresh: true,
                beforeSend: () async {
                  _check(gen);
                  gateTokens = api.sessions.require(scope);
                  final allowed = await guarded(() {});
                  // A gate query can refresh internally. Its membership reply
                  // must not be combined with a pre-rotation consent snapshot.
                  checkGateTokens();
                  if (!allowed) throw _UploadGateClosed(denied);
                  // Membership was checked over the network after the first
                  // OS check. Do not send if permission changed in that gap.
                  final bool queryable;
                  try {
                    queryable = await port.queryable();
                  } on Object {
                    throw const _UploadGateClosed(false);
                  }
                  if (!queryable) throw const _UploadGateClosed(true);
                },
                checkBeforeSend: () {
                  _check(gen);
                  checkGateTokens();
                  if (!_active) throw StateError('操作已停止');
                  if (clock() >=
                      min(collectionPaidUntil, s['paid_until'] as int)) {
                    throw const _UploadGateClosed(true);
                  }
                },
              )
              .drain<void>();
        } on _UploadGateClosed catch (e) {
          _check(gen);
          await _stopForGate(e.denied);
          return;
        } on ApiFailure catch (e) {
          if (e.status == 403) {
            _check(gen);
            await _stopForGate(true);
            return;
          }
          if (e.status == 409) {
            // 409 means the immutable slot exists with different content; it
            // is isolated and accounted, not reported as a delivered window.
            if (e.retryable == true) rethrow;
            s['skipped_conflicts'] = (s['skipped_conflicts'] as int? ?? 0) + 1;
          } else if (e.status >= 400 &&
              e.status < 500 &&
              e.status != 401 &&
              e.retryable != true) {
            _check(gen);
            await _stopForGate(true);
            return;
          } else {
            rethrow;
          }
        }
        _check(gen);
        s['cursor'] =
            DateTime.parse(window['starts_at']).millisecondsSinceEpoch + slotMs;
        await _save(s);
        _check(gen);
      }
      s['cursor'] = end;
      s.remove('pending_end');
      await _save(s);
    } finally {
      _busy = false;
    }
  }

  Future<void> _activatePending(int gen, Json s) async {
    final paidUntil = s['paid_until'];
    final grant = s['grant'];
    final storedSource = s['source'];
    if (paidUntil is! int ||
        paidUntil <= clock() ||
        grant is! String ||
        storedSource is! String) {
      _check(gen);
      await _stopForGate(true);
      return;
    }

    String? source;
    try {
      source = await port.source();
    } on Object {
      source = null;
    }
    _check(gen);
    if (!_sources.contains(source) || source != storedSource) {
      await _stopForGate(true);
      return;
    }

    var queryable = false;
    try {
      queryable = await port.queryable();
    } on Object {
      queryable = false;
    }
    _check(gen);
    if (!queryable) {
      await _stopForGate(true);
      return;
    }

    var boundaryAllowed = false;
    var denied = false;
    DateTime? expires;
    final allowed = await gate.readIfAllowed(
      scope,
      CollectionPurpose.health,
      systemGranted: port.queryable,
      acceptsGrant: (r) =>
          r['version'] == '2026-11' && r['updated_at'] == grant,
      onDenied: () => denied = true,
      onExpiry: (value) {
        expires = value;
        _trackExpiry(gen, s, value);
      },
      beginRead: () {
        _check(gen);
        if (!_active) throw StateError('应用已离开前台');
        boundaryAllowed = true;
      },
    );
    if (!allowed || !boundaryAllowed) {
      _check(gen);
      await _stopForGate(denied);
      return;
    }
    if (expires?.isAfter(DateTime.now()) != true) {
      _check(gen);
      await _stopForGate(true);
      return;
    }

    _check(gen);
    final boundary = ceilSlot(clock());
    s['mode'] = 'on';
    s['paid_until'] = expires!.millisecondsSinceEpoch;
    s['collection_from'] = boundary;
    s.remove('pending_end');
    s['cursor'] = boundary;
    await _save(s);
    _check(gen);
    _restored = true;
  }

  Future<void> _stopForGate(bool denied) {
    _halt();
    if (denied) return _save({'mode': 'paused'});
    // Network uncertainty: hold only the already-journaled bounds. A future
    // retry must pass every gate and query the platform again.
    return Future.value();
  }

  void _trackExpiry(int gen, Json s, DateTime expires) {
    _check(gen);
    s['paid_until'] = expires.millisecondsSinceEpoch;
    _expiry?.cancel();
    _expiry = Timer(expires.difference(DateTime.now()), () {
      if (gen == _epoch) {
        unawaited(_stopForGate(true).catchError((_) {}));
      }
    });
  }
}
