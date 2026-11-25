import 'dart:async';

import '../../core/api.dart';
import '../../core/app_op.g.dart';
import '../../core/endpoints.g.dart';
import '../../core/session.dart';
import '../../core/transport.dart';
import 'account_access.dart';
import 'records_contract.g.dart';
import 'store.dart';

const ownedDataListUnavailableMessage = '暂时无法连接，请检查网络后重试。';
const ownedDataDeleteUnavailableMessage = '删除请求未完成，请检查网络后重试。';
const ownedDataSessionLostMessage = '登录状态已失效，请返回并重新登录。';
const ownedDataInvalidPageMessage = '记录列表格式异常，已停止显示不可信内容。';
const privacyResourceNotFoundMessage = '资源不存在或不属于当前账号';
const privacyDeletionUnconfirmedMessage = '未收到有效的删除确认。请核对记录后再试。';

enum OwnedDataKind {
  assessments('assessments', '测评', '删除该测评、由它生成的计划、评分副本及相关日志；成长参考会按现有规则重算。'),
  sessions(
    'sessions',
    '对练',
    '删除该对练或单项练习、消息、评分、成长副本、练习工作数据、进度及相关 AI/画像日志；成长参考会重算。匿名每日用量统计保留。',
  ),
  reviews('reviews', '复盘', '删除复盘正文、评分、成长副本及相关日志；关联手动标记和情绪事件保留，引用会置空。删除后不可恢复。'),
  replies('replies', '回复', '删除回复、反馈、结果回执及相关日志；防重复请求记录会保留且不含回复正文。匿名每日用量统计保留。'),
  contacts(
    'contacts',
    '关系人',
    '会级联删除该关系人关联的对练、复盘、回复、消息、评分、画像证据、手动标记和情绪事件。影响范围最大，删除后不可恢复。',
  ),
  manualMarks('manual_marks', '手动标记', '删除该手动标记及请求别名；复盘中的引用会置空但正文保留。删除后不可恢复。'),
  signalEvents('signal_events', '情绪事件', '删除该情绪事件及画像证据；复盘引用置空，统计基线会重算。手动标记保留。'),
  signalWindows(
    'signal_windows',
    '健康/语音窗口',
    '仅删除这一个 30 秒窗口并重算统计基线；不会删除情绪事件、手动标记、本机录音或会话。',
  );

  const OwnedDataKind(this.wireName, this.label, this.impact);

  final String wireName;
  final String label;
  final String impact;

  bool get usesStableId => this != signalWindows;

  static OwnedDataKind? fromWireName(String value) {
    for (final kind in values) {
      if (kind.wireName == value) return kind;
    }
    return null;
  }
}

class OwnedDataPage {
  OwnedDataPage({
    required List<OwnedDataRecord> items,
    required this.nextCursor,
  }) : items = List.unmodifiable(items);

  final List<OwnedDataRecord> items;
  final String? nextCursor;
}

class OwnedDataRecord {
  const OwnedDataRecord._({
    required this.kind,
    required this.label,
    required this.recordedAt,
    required this.recordedAtIso,
    required this.id,
    required this.channel,
  });

  final OwnedDataKind kind;
  final String label;
  final DateTime? recordedAt;

  /// Kept verbatim so a 30-second window can be deleted without changing its
  /// server-side instant through local formatting.
  final String? recordedAtIso;
  final String? id;
  final String? channel;

  bool get isWindow => kind == OwnedDataKind.signalWindows;

  String get stableKey => isWindow
      ? '${kind.wireName}:$recordedAtIso:$channel'
      : '${kind.wireName}:$id';

  String get shortReference {
    final value = id;
    if (value != null) return '#${value.substring(value.length - 8)}';
    return channel == 'voice' ? '语音窗口' : '健康窗口';
  }

  factory OwnedDataRecord.fromJson(
    Json json, {
    required OwnedDataKind expectedKind,
  }) {
    final kindValue = json['kind'];
    if (kindValue is! String) {
      throw const FormatException('记录类型缺失');
    }
    final kind = OwnedDataKind.fromWireName(kindValue);
    if (kind == null || kind != expectedKind) {
      throw const FormatException('记录类型与列表不一致');
    }
    final label = json['label'];
    if (label is! String || !ownedDataLabelPattern.hasMatch(label)) {
      throw const FormatException('记录标签异常');
    }
    if (json.length != 4 || !json.containsKey('recorded_at')) {
      throw const FormatException('记录字段异常');
    }
    final rawRecordedAt = json['recorded_at'];
    if (kind == OwnedDataKind.contacts) {
      if (rawRecordedAt != null) throw const FormatException('关系人记录时间异常');
    } else {
      final pattern = kind.usesStableId
          ? ownedDataTimePattern
          : ownedDataWindowTimePattern;
      if (rawRecordedAt is! String || !pattern.hasMatch(rawRecordedAt)) {
        throw const FormatException('记录时间格式异常');
      }
    }

    final rawId = json['id'];
    final rawChannel = json['channel'];
    if (kind.usesStableId) {
      if (rawId is! String || !ownedDataIdPattern.hasMatch(rawId)) {
        throw const FormatException('记录定位键异常');
      }
    } else if (rawChannel != 'health' && rawChannel != 'voice') {
      throw const FormatException('窗口渠道异常');
    }

    return OwnedDataRecord._(
      kind: kind,
      label: label,
      recordedAt: rawRecordedAt == null
          ? null
          : DateTime.parse(rawRecordedAt as String),
      recordedAtIso: rawRecordedAt as String?,
      id: rawId as String?,
      channel: rawChannel as String?,
    );
  }
}

class OwnedDataRecordsFailure implements Exception {
  const OwnedDataRecordsFailure(
    this.message, {
    this.status,
    this.code,
    this.retryable = true,
    this.cause,
  });

  final String message;
  final int? status;
  final String? code;
  final bool retryable;
  final Object? cause;

  @override
  String toString() => message;
}

/// Binds every request to the exact account scope captured at page entry.
/// A normal re-login or background account switch invalidates this adapter.
class OwnedDataRecordsAdapter {
  OwnedDataRecordsAdapter(this.store) : scope = store.scope;

  final PrivacyStore store;
  final AccountScope scope;

  MobileEndpoints get _wire => MobileEndpoints(store.api);

  bool get isCurrentSession =>
      identical(store.scope, scope) &&
      identical(store.api.sessions.active, scope);

  void _requireCurrentSession() {
    if (!isCurrentSession) throw SessionChanged();
  }

  Future<OwnedDataPage> loadPage({
    required OwnedDataKind kind,
    String? cursor,
    int limit = 20,
  }) async {
    if (limit < 1 || limit > 100) {
      throw ArgumentError.value(limit, 'limit', 'must be between 1 and 100');
    }
    if (cursor != null &&
        (cursor.isEmpty || cursor.runes.length > ownedDataCursorLimit)) {
      throw ArgumentError.value(cursor, 'cursor', 'invalid page cursor');
    }
    _requireCurrentSession();
    try {
      final json = await _wire.listDataRecords(
        scope: scope,
        kind: kind.wireName,
        cursor: cursor,
        limit: limit,
      );
      _requireCurrentSession();
      return _parsePage(json, kind);
    } on SessionChanged {
      rethrow;
    } on ApiFailure catch (error) {
      throw _failure(error, deleting: false);
    } on FormatException catch (error) {
      throw OwnedDataRecordsFailure(
        ownedDataInvalidPageMessage,
        retryable: false,
        cause: error,
      );
    } catch (error) {
      throw OwnedDataRecordsFailure(
        ownedDataListUnavailableMessage,
        retryable: true,
        cause: error,
      );
    }
  }

  Future<void> delete(
    OwnedDataRecord record, {
    PrivacyAccount? verifiedAdmission,
  }) async {
    _requireCurrentSession();
    final admission = store.admission;
    var expected = verifiedAdmission;
    var firstSend = true;
    Future<void> checkBeforeSend() async {
      if (firstSend && expected != null) {
        firstSend = false;
        return;
      }
      expected = await admission.refresh();
      firstSend = false;
    }

    try {
      final receipt = await store.api.jsonGuarded(
        record.isWindow ? AppOp.deleteWindow : AppOp.deleteSource,
        scope: scope,
        path: record.isWindow
            ? const {}
            : {'kind': record.kind.wireName, 'id': record.id!},
        query: record.isWindow
            ? {'starts_at': record.recordedAtIso!, 'channel': record.channel!}
            : const {},
        beforeSend: checkBeforeSend,
        checkBeforeSend: () => admission.requireOrdinary(expected),
      );
      if (receipt.length != 1 || receipt['ok'] != true) {
        throw const FormatException('删除回执异常');
      }
      _requireCurrentSession();
    } on SessionChanged {
      rethrow;
    } on ApiFailure catch (error) {
      throw _failure(error, deleting: true);
    } on FormatException catch (error) {
      throw OwnedDataRecordsFailure(
        privacyDeletionUnconfirmedMessage,
        retryable: false,
        cause: error,
      );
    } catch (error) {
      throw OwnedDataRecordsFailure(
        ownedDataDeleteUnavailableMessage,
        retryable: true,
        cause: error,
      );
    }
  }

  OwnedDataPage _parsePage(Json json, OwnedDataKind expectedKind) {
    final rawItems = json['items'];
    if (rawItems is! List ||
        json.length != 2 ||
        !json.containsKey('next_cursor')) {
      throw const FormatException('记录分页字段异常');
    }
    final rawNext = json['next_cursor'];
    if (rawNext != null && rawNext is! String) {
      throw const FormatException('记录分页游标异常');
    }
    if (rawNext is String &&
        (rawNext.isEmpty || rawNext.runes.length > ownedDataCursorLimit)) {
      throw const FormatException('记录分页游标异常');
    }
    final items = <OwnedDataRecord>[];
    for (final value in rawItems) {
      if (value is! Json) throw const FormatException('记录格式异常');
      items.add(OwnedDataRecord.fromJson(value, expectedKind: expectedKind));
    }
    return OwnedDataPage(items: items, nextCursor: rawNext as String?);
  }

  OwnedDataRecordsFailure _failure(ApiFailure error, {required bool deleting}) {
    if (error.status == 404 && deleting) {
      return OwnedDataRecordsFailure(
        privacyResourceNotFoundMessage,
        status: error.status,
        code: error.code,
        retryable: false,
        cause: error,
      );
    }
    final message = switch (error.status) {
      400 => '记录类型或分页参数无效，请返回后重试。',
      401 => ownedDataSessionLostMessage,
      403 => '没有获得所需授权，请重新确认后再试。',
      404 => privacyResourceNotFoundMessage,
      429 => '操作过于频繁，请稍后再试。',
      503 => '服务暂时不可用，请稍后重试。',
      _ =>
        deleting
            ? ownedDataDeleteUnavailableMessage
            : ownedDataListUnavailableMessage,
    };
    return OwnedDataRecordsFailure(
      message,
      status: error.status,
      code: error.code,
      retryable:
          error.retryable ?? (error.status != 400 && error.status != 401),
      cause: error,
    );
  }
}
