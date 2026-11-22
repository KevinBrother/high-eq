import 'dart:convert';
import 'dart:typed_data';

import '../../core/session.dart';
import '../../core/transport.dart';
import 'features.dart';

class VoiceRecording {
  final String id;
  final DateTime startsAt;
  final int durationSeconds;

  const VoiceRecording({
    required this.id,
    required this.startsAt,
    required this.durationSeconds,
  });

  DateTime get expiresAt => startsAt.add(const Duration(days: 3));
}

/// Account-scoped encrypted persistence for pending statistics and recordings.
/// Only the statistics wire object is stored in the queue; PCM never enters it.
class VoiceWindowStore {
  static const queueIndexId = 'voice.window-index';
  static const recordingIndexId = 'voice.recording-index';
  static const voiceRevokedId = 'voice.revoked';
  static const retentionRevokedId = 'voice.retention-revoked';
  static const _recordingMutationKey = 'voice.recordings';

  final Sessions sessions;
  final AccountScope scope;

  VoiceWindowStore(this.sessions, this.scope);

  String _windowId(DateTime startsAt) =>
      'voice.window:${startsAt.toUtc().toIso8601String()}';

  String recordingId(DateTime startsAt) =>
      'voice.recording:${startsAt.toUtc().toIso8601String()}';

  Future<void> enqueue(VoiceWindow window) async {
    final id = _windowId(window.startsAt);
    await sessions.put(
      scope,
      CacheKind.queue,
      id,
      utf8.encode(jsonEncode(window.toWire())),
    );
    final ids = await _readIds(CacheKind.queue, queueIndexId);
    if (!ids.contains(id)) {
      ids.add(id);
      await _writeIds(CacheKind.queue, queueIndexId, ids);
    }
  }

  Future<List<VoiceWindow>> pending() async {
    final ids = await _readIds(CacheKind.queue, queueIndexId);
    final result = <VoiceWindow>[];
    final keep = <String>[];
    for (final id in ids) {
      final raw = await sessions.get(scope, CacheKind.queue, id);
      if (raw == null) continue;
      try {
        result.add(VoiceWindow.fromWire(jsonDecode(utf8.decode(raw)) as Json));
        keep.add(id);
      } on Object {
        await sessions.remove(scope, CacheKind.queue, id);
      }
    }
    if (keep.length != ids.length) {
      await _writeIds(CacheKind.queue, queueIndexId, keep);
    }
    return result;
  }

  Future<void> removePending(DateTime startsAt) async {
    final id = _windowId(startsAt);
    await sessions.remove(scope, CacheKind.queue, id);
    final ids = await _readIds(CacheKind.queue, queueIndexId);
    ids.remove(id);
    await _writeIds(CacheKind.queue, queueIndexId, ids);
  }

  /// Must be called before the server revoke request so a failed network call
  /// can never leave locally queued windows eligible for later upload.
  Future<void> clearPending() async {
    final ids = await _readIds(CacheKind.queue, queueIndexId);
    for (final id in ids) {
      await sessions.remove(scope, CacheKind.queue, id);
    }
    await sessions.remove(scope, CacheKind.queue, queueIndexId);
  }

  Future<int> pendingCount() async => (await pending()).length;

  Future<void> saveRecording(DateTime startsAt, Uint8List pcm) {
    return sessions.runExclusive(scope, _recordingMutationKey, () async {
      final id = recordingId(startsAt);
      await sessions.put(scope, CacheKind.recording, id, pcm);
      final rows = await _readRecordingRows();
      rows.removeWhere((row) => row['id'] == id);
      rows.add({
        'id': id,
        'starts_at': startsAt.toUtc().toIso8601String(),
        'duration_seconds': 30,
      });
      rows.sort(
        (a, b) =>
            (b['starts_at'] as String).compareTo(a['starts_at'] as String),
      );
      await _writeRecordingRows(rows);
    });
  }

  Future<List<VoiceRecording>> recordings({DateTime? now}) => sessions
      .runExclusive(scope, _recordingMutationKey, () => _recordings(now: now));

  Future<List<VoiceRecording>> _recordings({DateTime? now}) async {
    final at = (now ?? DateTime.now()).toUtc();
    final rows = await _readRecordingRows();
    final result = <VoiceRecording>[];
    final keep = <Json>[];
    for (final row in rows) {
      final parsed = _recording(row);
      if (parsed == null || !at.isBefore(parsed.expiresAt)) {
        if (parsed != null) {
          await sessions.remove(scope, CacheKind.recording, parsed.id);
        }
        continue;
      }
      result.add(parsed);
      keep.add(row);
    }
    if (keep.length != rows.length) await _writeRecordingRows(keep);
    result.sort((a, b) => b.startsAt.compareTo(a.startsAt));
    return result;
  }

  Future<Uint8List?> readRecording(String id, {DateTime? now}) {
    return sessions.runExclusive(scope, _recordingMutationKey, () async {
      final at = (now ?? DateTime.now()).toUtc();
      final rows = await _readRecordingRows();
      final row = rows.where((item) => item['id'] == id).firstOrNull;
      final parsed = row == null ? null : _recording(row);
      if (parsed == null || !at.isBefore(parsed.expiresAt)) {
        if (parsed != null) await _deleteRecording(parsed.id);
        return null;
      }
      final raw = await sessions.get(scope, CacheKind.recording, id);
      return raw == null ? null : Uint8List.fromList(raw);
    });
  }

  Future<void> deleteRecording(String id) =>
      sessions.runExclusive(scope, _recordingMutationKey, () {
        return _deleteRecording(id);
      });

  Future<void> _deleteRecording(String id) async {
    await sessions.remove(scope, CacheKind.recording, id);
    final rows = await _readRecordingRows();
    rows.removeWhere((row) => row['id'] == id);
    await _writeRecordingRows(rows);
  }

  Future<void> deleteAllRecordings() {
    return sessions.runExclusive(scope, _recordingMutationKey, () async {
      final rows = await _readRecordingRows();
      for (final row in rows) {
        final id = row['id'];
        if (id is String) {
          await sessions.remove(scope, CacheKind.recording, id);
        }
      }
      await sessions.remove(scope, CacheKind.draft, recordingIndexId);
    });
  }

  Future<void> purgeExpired({DateTime? now}) =>
      sessions.runExclusive(scope, _recordingMutationKey, () async {
        await _recordings(now: now);
      });

  Future<void> setVoiceRevoked(bool value) => _setFlag(voiceRevokedId, value);

  Future<bool> voiceRevoked() => _readFlag(voiceRevokedId);

  Future<void> setRetentionRevoked(bool value) =>
      _setFlag(retentionRevokedId, value);

  Future<bool> retentionRevoked() => _readFlag(retentionRevokedId);

  Future<void> _setFlag(String id, bool value) async {
    if (value) {
      await sessions.put(scope, CacheKind.draft, id, utf8.encode('1'));
    } else {
      await sessions.remove(scope, CacheKind.draft, id);
    }
  }

  Future<bool> _readFlag(String id) async {
    final raw = await sessions.get(scope, CacheKind.draft, id);
    return raw != null && utf8.decode(raw) == '1';
  }

  Future<List<String>> _readIds(CacheKind kind, String id) async {
    final raw = await sessions.get(scope, kind, id);
    if (raw == null) return [];
    try {
      final value = jsonDecode(utf8.decode(raw));
      if (value is! List) return [];
      return value.whereType<String>().toList();
    } on Object {
      return [];
    }
  }

  Future<void> _writeIds(CacheKind kind, String id, List<String> ids) async {
    if (ids.isEmpty) {
      await sessions.remove(scope, kind, id);
      return;
    }
    await sessions.put(scope, kind, id, utf8.encode(jsonEncode(ids)));
  }

  Future<List<Json>> _readRecordingRows() async {
    final raw = await sessions.get(scope, CacheKind.draft, recordingIndexId);
    if (raw == null) return [];
    try {
      final value = jsonDecode(utf8.decode(raw));
      if (value is! List) return [];
      return value.whereType<Json>().toList();
    } on Object {
      return [];
    }
  }

  Future<void> _writeRecordingRows(List<Json> rows) async {
    if (rows.isEmpty) {
      await sessions.remove(scope, CacheKind.draft, recordingIndexId);
      return;
    }
    await sessions.put(
      scope,
      CacheKind.draft,
      recordingIndexId,
      utf8.encode(jsonEncode(rows)),
    );
  }

  VoiceRecording? _recording(Json row) {
    final id = row['id'];
    final start = row['starts_at'];
    final duration = row['duration_seconds'];
    if (id is! String || start is! String || duration is! int) return null;
    final parsed = DateTime.tryParse(start)?.toUtc();
    if (parsed == null || duration != 30) return null;
    return VoiceRecording(id: id, startsAt: parsed, durationSeconds: duration);
  }
}
