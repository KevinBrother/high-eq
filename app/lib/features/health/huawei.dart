import 'dart:convert';

import 'package:flutter/services.dart';

import 'platform.dart';

const huaweiHeartRateReadScope =
    'https://www.huawei.com/healthkit/heartrate.read';
const huaweiStepReadScope = 'https://www.huawei.com/healthkit/step.read';
const huaweiActivityReadScope =
    'https://www.huawei.com/healthkit/activityrecord.read';
const huaweiReadScopes = <String>{
  huaweiHeartRateReadScope,
  huaweiStepReadScope,
  huaweiActivityReadScope,
};

const huaweiHeartRateDataType = 'com.huawei.instantaneous.heart_rate';
const huaweiStepsDataType = 'com.huawei.continuous.steps.delta';
const huaweiBpmField = 'bpm';
const huaweiStepsField = 'steps_delta';

const _huaweiHeartRateWriteScope =
    'https://www.huawei.com/healthkit/heartrate.write';
const _huaweiStepWriteScope = 'https://www.huawei.com/healthkit/step.write';

class HuaweiAuthResult {
  HuaweiAuthResult(Iterable<String> grantedScopes)
    : grantedScopes = Set.unmodifiable(grantedScopes);

  final Set<String> grantedScopes;
}

class HuaweiSample {
  const HuaweiSample({
    required this.dataType,
    required this.startTime,
    required this.endTime,
    this.samplingTime,
    required this.fields,
  });

  final String dataType;
  final int startTime;
  final int endTime;
  final int? samplingTime;
  final Map<String, num> fields;
}

class HuaweiActivityRecord {
  const HuaweiActivityRecord({required this.startTime, required this.endTime});

  final int startTime;
  final int endTime;
}

/// Narrow seam over the pinned Huawei SDK. Keeping this interface independent
/// from plugin classes lets the authorization and mapping contract be tested
/// without loading HMS or requesting a real health grant.
abstract interface class HuaweiHealthSdk {
  Future<void> verifyAppId();
  Future<HuaweiAuthResult?> signIn(Set<String> scopes);
  Future<Set<String>> getGrantedScopes();
  Future<bool> getHealthAppAuthorization();
  Future<void> init();
  Future<List<HuaweiSample>> read(int from, int to);
  Future<List<HuaweiActivityRecord>> readActivityRecords(int from, int to);
}

/// Read-only Huawei history adapter. Production binding elects it only when the
/// native release source is `huawei_history` and the compile-time approval flag
/// is set; qualification, signing and HMS device acceptance remain external.
class HuaweiHealthPort implements HealthPort {
  HuaweiHealthPort(this.sdk, {required this.approved});

  final HuaweiHealthSdk sdk;
  final bool approved;
  Set<String>? _grantedScopes;
  int _generation = 0;
  int _authRevision = 0;

  bool get _hasReadScopes =>
      _grantedScopes != null &&
      huaweiReadScopes.every(_grantedScopes!.contains);

  @override
  Future<String?> source() async {
    if (!approved) return null;
    await sdk.verifyAppId();
    return 'huawei_history';
  }

  @override
  Future<bool> request({void Function()? onSystemPrompt}) async {
    if (!approved) return false;
    final revision = ++_authRevision;
    await sdk.verifyAppId();
    if (revision != _authRevision) return false;
    onSystemPrompt?.call();
    if (revision != _authRevision) return false;
    final result = await sdk.signIn(huaweiReadScopes);
    if (revision != _authRevision) return false;
    _grantedScopes = Set.unmodifiable(result?.grantedScopes ?? const {});
    if (!_hasReadScopes) return false;
    final authorized = await sdk.getHealthAppAuthorization();
    if (revision != _authRevision) return false;
    return authorized;
  }

  @override
  Future<bool> queryable() async {
    if (!approved) return false;
    // Authorization responses can arrive after stop(), revocation or a newer
    // interactive grant. Only the latest operation may write the scope cache;
    // otherwise an old denial could make the next tick withdraw server consent.
    final revision = ++_authRevision;
    await sdk.verifyAppId();
    if (revision != _authRevision) return false;
    final knownScopes = _grantedScopes;
    if (knownScopes != null && !_hasReadScopes) return false;
    final authorized = await sdk.getHealthAppAuthorization();
    if (revision != _authRevision) return false;
    if (!authorized) return false;
    // Scope grants survive process restarts but this adapter does not. Query
    // the public, non-interactive consent list before deciding that a cold
    // process was revoked; an empty in-memory set is unknown, not a denial.
    final scopes = await sdk.getGrantedScopes();
    if (revision != _authRevision) return false;
    _grantedScopes = Set.unmodifiable(scopes);
    return _hasReadScopes;
  }

  @override
  Future<List<List>> read(int from, int to) async {
    final generation = _generation;
    if (to <= from || !await queryable() || generation != _generation) {
      return [];
    }
    await sdk.init();
    if (generation != _generation) return [];
    // Permission can be revoked while initialization is suspended. Recheck
    // immediately before the read so stop() and an OS withdrawal both close
    // the window before HMS receives a data request.
    if (!await queryable() || generation != _generation) return [];
    final samples = await sdk.read(from, to);
    if (generation != _generation) return [];
    // The activity query is a second native read. Recheck access after the
    // first read so a revocation or stop during it closes this boundary too.
    if (!await queryable() || generation != _generation) return [];
    final activities = await sdk.readActivityRecords(from, to);
    if (generation != _generation) return [];
    final rows = <List>[];
    for (final sample in samples) {
      switch (sample.dataType) {
        case huaweiHeartRateDataType:
          final at = sample.samplingTime ?? sample.startTime;
          final bpm = sample.fields[huaweiBpmField];
          if (at < from || at >= to || bpm == null || !_valid(bpm)) continue;
          rows.add(['heart_rate', at, at, bpm.toDouble()]);
        case huaweiStepsDataType:
          final steps = sample.fields[huaweiStepsField];
          if (sample.endTime <= sample.startTime ||
              sample.startTime >= to ||
              sample.endTime <= from ||
              steps == null ||
              !_valid(steps)) {
            continue;
          }
          rows.add([
            'steps',
            sample.startTime,
            sample.endTime,
            steps.toDouble(),
          ]);
      }
    }
    for (final activity in activities) {
      if (activity.endTime <= activity.startTime ||
          activity.startTime >= to ||
          activity.endTime <= from) {
        continue;
      }
      rows.add(['exercise', activity.startTime, activity.endTime, 1.0]);
    }
    return rows;
  }

  static bool _valid(num value) => value.isFinite && value >= 0;

  @override
  Future<void> stop() async {
    _authRevision++;
    _generation++;
  }
}

/// Wrapper for the pinned public plugin channels. Production binding can elect
/// it only behind the compile-time approval gate; the wrapper alone does not
/// establish project qualification or device acceptance.
class MethodChannelHuaweiHealthSdk implements HuaweiHealthSdk {
  static const _platform = MethodChannel('cn.higheq/health-history');
  static const _auth = MethodChannel(
    'com.huawei.hms.flutter.health/health_auth',
  );
  static const _data = MethodChannel(
    'com.huawei.hms.flutter.health/data_controller',
  );
  static const _activity = MethodChannel(
    'com.huawei.hms.flutter.health/activity_records',
  );
  static const _setting = MethodChannel(
    'com.huawei.hms.flutter.health/setting_controller',
  );

  @override
  Future<void> verifyAppId() async {
    final expectedRaw = await _platform.invokeMethod<Object?>('huaweiAppId');
    final expected = expectedRaw is String ? expectedRaw.trim() : '';
    if (expected.isEmpty) {
      throw StateError('HUAWEI restricted release app id is not configured');
    }
    Object? actualRaw;
    try {
      actualRaw = await _setting.invokeMethod<Object?>('getAppId');
    } on PlatformException catch (error) {
      throw StateError(
        'HUAWEI AG Connect app id is unavailable (${error.code})',
      );
    }
    final actual = actualRaw is String ? actualRaw.trim() : '';
    if (actual.isEmpty) {
      throw StateError('HUAWEI AG Connect app id is unavailable');
    }
    if (actual != expected) {
      throw StateError('HUAWEI AG Connect app id does not match this release');
    }
  }

  @override
  Future<HuaweiAuthResult?> signIn(Set<String> scopes) async {
    final raw = await _auth.invokeMethod<Object?>('signIn', {
      'scopes': scopes.toList(growable: false),
    });
    if (raw == null) return null;
    final payload = _object(raw);
    if (payload == null) return HuaweiAuthResult(const {});
    return HuaweiAuthResult(
      _scopes(
        payload['grantedScopes'] ?? payload['scopes'] ?? payload['scope'],
      ),
    );
  }

  @override
  Future<Set<String>> getGrantedScopes() async {
    final appId = await _setting.invokeMethod<String>('getAppId');
    if (appId == null || appId.isEmpty) {
      throw StateError('HUAWEI Health app id is unavailable');
    }
    final raw = await _setting.invokeMethod<Object?>('get', {
      'lang': 'en-US',
      'appId': appId,
    });
    final payload = _object(raw);
    final url2Desc = payload?['url2Desc'];
    if (url2Desc is! Map) {
      throw const FormatException('Invalid HUAWEI scope response');
    }
    return _scopes(url2Desc);
  }

  @override
  Future<bool> getHealthAppAuthorization() async =>
      await _setting.invokeMethod<bool>('getHealthAppAuthorization') == true;

  @override
  Future<void> init() => _data.invokeMethod<void>('init');

  @override
  Future<List<HuaweiSample>> read(int from, int to) async {
    final raw = await _data.invokeMethod<Object?>('read', {
      'startTime': from,
      'endTime': to,
      'timeUnit': 'MILLISECONDS',
      'dataTypes': [
        _dataType(
          name: huaweiHeartRateDataType,
          scopeRead: huaweiHeartRateReadScope,
          scopeWrite: _huaweiHeartRateWriteScope,
          fields: [_field(name: huaweiBpmField, format: 2)],
        ),
        _dataType(
          name: huaweiStepsDataType,
          scopeRead: huaweiStepReadScope,
          scopeWrite: _huaweiStepWriteScope,
          fields: [_field(name: huaweiStepsField, format: 1)],
        ),
      ],
    });
    final reply = _object(raw);
    if (reply == null) return [];
    final sets = reply['sampleSets'];
    if (sets is! List) return [];
    final samples = <HuaweiSample>[];
    for (final rawSet in sets) {
      if (rawSet is! Map) continue;
      final points = rawSet['samplePoints'];
      if (points is! List) continue;
      final collector = _map(rawSet['dataCollector']);
      final setType =
          _dataTypeName(rawSet['dataType']) ??
          _string(rawSet['dataTypeName']) ??
          _string(collector?['dataTypeName']) ??
          _dataTypeName(collector?['dataType']);
      for (final rawPoint in points) {
        if (rawPoint is! Map) continue;
        final pointCollector = _map(rawPoint['dataCollector']);
        final type =
            _dataTypeName(rawPoint['dataType']) ??
            _string(rawPoint['dataTypeName']) ??
            _string(pointCollector?['dataTypeName']) ??
            _dataTypeName(pointCollector?['dataType']) ??
            setType;
        final samplingTime = _time(rawPoint['samplingTime']);
        final start = _time(rawPoint['startTime']) ?? samplingTime;
        final end = _time(rawPoint['endTime']) ?? start;
        if (type == null || start == null || end == null) continue;
        final fields = <String, num>{};
        final rawFields =
            rawPoint['fieldValues'] ?? rawPoint['platformFieldValues'];
        if (rawFields is Map) {
          for (final entry in rawFields.entries) {
            final value = _number(
              entry.value is Map ? entry.value['value'] : entry.value,
            );
            if (entry.key is String && value != null) {
              fields[entry.key as String] = value;
            }
          }
        }
        samples.add(
          HuaweiSample(
            dataType: type,
            startTime: start,
            endTime: end,
            samplingTime: samplingTime,
            fields: fields,
          ),
        );
      }
    }
    return samples;
  }

  @override
  Future<List<HuaweiActivityRecord>> readActivityRecords(
    int from,
    int to,
  ) async {
    final raw = await _activity.invokeMethod<Object?>('getActivityRecord', {
      'startTime': from,
      'endTime': to,
      'timeUnit': 'MILLISECONDS',
    });
    if (raw is! List) return const [];
    final records = <HuaweiActivityRecord>[];
    for (final entry in raw) {
      final wrapper = _map(entry);
      final activity = _map(wrapper?['activityRecord']);
      final start = _time(activity?['startTime']);
      final end = _time(activity?['endTime']);
      if (start == null || end == null || end <= start) continue;
      records.add(HuaweiActivityRecord(startTime: start, endTime: end));
    }
    return records;
  }

  static Map<String, Object> _dataType({
    required String name,
    required String scopeRead,
    required String scopeWrite,
    required List<Map<String, Object>> fields,
  }) {
    return {
      'name': name,
      'fieldList': fields.toString(),
      'isPolymerizedFlag': false,
      'isSelfDefined': false,
      'scopeNameRead': scopeRead,
      'scopeNameWrite': scopeWrite,
      'fields': fields,
    };
  }

  static Map<String, Object> _field({
    required String name,
    required int format,
  }) {
    return {'name': name, 'format': format, 'isOptional': false};
  }

  static Map? _map(Object? value) => value is Map ? value : null;

  static Map? _object(Object? value) {
    if (value is Map) return value;
    if (value is! String) return null;
    try {
      final decoded = jsonDecode(value);
      return decoded is Map ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  static String? _string(Object? value) => value is String ? value : null;

  static String? _dataTypeName(Object? value) {
    if (value is String) return value;
    final map = _map(value);
    return map == null ? null : _string(map['name']);
  }

  static Set<String> _scopes(Object? value) {
    if (value is String) return {value};
    if (value is Map) {
      return {
        for (final scope in value.keys)
          if (scope is String) scope,
      };
    }
    if (value is! List) return const {};
    final scopes = <String>{};
    for (final entry in value) {
      if (entry is String) {
        scopes.add(entry);
        continue;
      }
      final map = _map(entry);
      final scope = map?['mScopeUri'];
      if (scope is String) scopes.add(scope);
    }
    return scopes;
  }

  static int? _time(Object? value) {
    if (value is num) return value.toInt();
    if (value is! String) return null;
    return int.tryParse(value) ??
        DateTime.tryParse(value)?.millisecondsSinceEpoch;
  }

  static num? _number(Object? value) {
    if (value is num) return value;
    if (value is String) return num.tryParse(value);
    return null;
  }
}
