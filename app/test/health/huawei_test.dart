import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/features/health/binding.dart';
import 'package:high_eq/features/health/huawei.dart';
import 'package:high_eq/features/health/platform.dart';
import 'package:high_eq/features/health/windows.dart';

const _authChannel = MethodChannel('com.huawei.hms.flutter.health/health_auth');
const _dataChannel = MethodChannel(
  'com.huawei.hms.flutter.health/data_controller',
);
const _settingChannel = MethodChannel(
  'com.huawei.hms.flutter.health/setting_controller',
);
const _activityChannel = MethodChannel(
  'com.huawei.hms.flutter.health/activity_records',
);
const _platformChannel = MethodChannel('cn.higheq/health-history');

void _mockChannel(
  MethodChannel channel,
  Future<Object?> Function(MethodCall call) handler,
) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, handler);
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
}

class _SyntheticHuaweiSdk implements HuaweiHealthSdk {
  bool authorized = true;
  Set<String> grantable = {...huaweiReadScopes};
  List<HuaweiSample> samples = [];
  List<HuaweiActivityRecord> activityRecords = [];
  Set<String>? requestedScopes;
  int appIdChecks = 0,
      signIns = 0,
      scopeQueries = 0,
      authorizationChecks = 0,
      initializations = 0,
      reads = 0,
      activityReads = 0;
  Completer<void>? appIdCheckStarted;
  Completer<void>? holdAppIdCheck;
  Completer<void>? initStarted;
  Completer<void>? holdInit;
  Completer<void>? signInStarted;
  Completer<void>? holdSignIn;
  Completer<void>? scopeQueryStarted;
  Completer<void>? holdScopeQuery;

  @override
  Future<void> verifyAppId() async {
    appIdChecks++;
    if (appIdCheckStarted?.isCompleted == false) {
      appIdCheckStarted!.complete();
    }
    await holdAppIdCheck?.future;
  }

  @override
  Future<HuaweiAuthResult?> signIn(Set<String> scopes) async {
    signIns++;
    requestedScopes = Set.of(scopes);
    final result = HuaweiAuthResult(scopes.intersection(grantable));
    if (signInStarted?.isCompleted == false) signInStarted!.complete();
    await holdSignIn?.future;
    return result;
  }

  @override
  Future<bool> getHealthAppAuthorization() async {
    authorizationChecks++;
    return authorized;
  }

  @override
  Future<Set<String>> getGrantedScopes() async {
    scopeQueries++;
    if (scopeQueryStarted?.isCompleted == false) scopeQueryStarted!.complete();
    await holdScopeQuery?.future;
    return Set.of(grantable);
  }

  @override
  Future<void> init() async {
    initializations++;
    if (initStarted?.isCompleted == false) initStarted!.complete();
    await holdInit?.future;
  }

  @override
  Future<List<HuaweiSample>> read(int from, int to) async {
    reads++;
    return samples;
  }

  @override
  Future<List<HuaweiActivityRecord>> readActivityRecords(
    int from,
    int to,
  ) async {
    activityReads++;
    return activityRecords;
  }
}

class _SourceHealthPort implements HealthPort {
  _SourceHealthPort(this.nativeSource);

  final String? nativeSource;
  int sourceCalls = 0;

  @override
  Future<String?> source() async {
    sourceCalls++;
    return nativeSource;
  }

  @override
  Future<bool> request({void Function()? onSystemPrompt}) async => false;
  @override
  Future<bool> queryable() async => false;
  @override
  Future<List<List>> read(int from, int to) async => const [];
  @override
  Future<void> stop() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('unapproved Huawei source performs no SDK call', () async {
    final sdk = _SyntheticHuaweiSdk();
    final port = HuaweiHealthPort(sdk, approved: false);

    expect(await port.source(), isNull);
    expect(await port.request(), false);
    expect(await port.queryable(), false);
    expect(await port.read(0, 30000), isEmpty);
    expect(sdk.appIdChecks, 0);
    expect(sdk.signIns, 0);
    expect(sdk.authorizationChecks, 0);
    expect(sdk.initializations, 0);
    expect(sdk.reads, 0);
  });

  test('production selector keeps unapproved Huawei fail-closed', () async {
    final sdk = _SyntheticHuaweiSdk();
    var factoryCalls = 0;
    final platform = _SourceHealthPort('huawei_history');
    final selected = await selectHealthPort(
      platform: platform,
      huaweiApproved: false,
      huaweiSdk: () {
        factoryCalls++;
        return sdk;
      },
    );

    expect(factoryCalls, 0);
    expect(await selected.source(), isNull);
    expect(await selected.request(), false);
    expect(await selected.queryable(), false);
    expect(await selected.read(0, 30000), isEmpty);
    expect(platform.sourceCalls, 1);
    expect((sdk.signIns, sdk.authorizationChecks, sdk.reads), (0, 0, 0));
  });

  test('production selector wires approved Huawei source', () async {
    final sdk = _SyntheticHuaweiSdk();
    var factoryCalls = 0;
    final selected = await selectHealthPort(
      platform: _SourceHealthPort('huawei_history'),
      huaweiApproved: true,
      huaweiSdk: () {
        factoryCalls++;
        return sdk;
      },
    );

    expect(selected, isA<HuaweiHealthPort>());
    expect(await selected.source(), 'huawei_history');
    expect(factoryCalls, 1);
    expect((sdk.signIns, sdk.authorizationChecks, sdk.reads), (0, 0, 0));
  });

  test('production selector preserves supported platform sources', () async {
    var factoryCalls = 0;
    for (final source in ['apple_history', 'health_connect']) {
      final platform = _SourceHealthPort(source);
      final selected = await selectHealthPort(
        platform: platform,
        huaweiApproved: true,
        huaweiSdk: () {
          factoryCalls++;
          return _SyntheticHuaweiSdk();
        },
      );

      expect(identical(selected, platform), true);
      expect(await selected.source(), source);
    }
    expect(factoryCalls, 0);
  });

  test(
    'production selector closes unknown sources without Huawei calls',
    () async {
      var factoryCalls = 0;
      final selected = await selectHealthPort(
        platform: _SourceHealthPort('unknown'),
        huaweiApproved: true,
        huaweiSdk: () {
          factoryCalls++;
          return _SyntheticHuaweiSdk();
        },
      );

      expect(factoryCalls, 0);
      expect(await selected.source(), isNull);
      expect(await selected.queryable(), false);
      expect(await selected.read(0, 30000), isEmpty);
    },
  );

  test(
    'missing read scope is rejected before Health app authorization',
    () async {
      final sdk = _SyntheticHuaweiSdk()..grantable = {huaweiHeartRateReadScope};
      final port = HuaweiHealthPort(sdk, approved: true);

      expect(await port.request(), false);
      expect(await port.queryable(), false);
      expect(await port.read(0, 30000), isEmpty);
      expect(sdk.requestedScopes, huaweiReadScopes);
      expect(sdk.authorizationChecks, 0);
      expect(sdk.initializations, 0);
      expect(sdk.reads, 0);
    },
  );

  test(
    'successful authorization maps only in-range heart and step fields',
    () async {
      final sdk = _SyntheticHuaweiSdk()
        ..samples = [
          HuaweiSample(
            dataType: huaweiHeartRateDataType,
            startTime: 1200,
            endTime: 1200,
            samplingTime: 1200,
            fields: const {huaweiBpmField: 72},
          ),
          HuaweiSample(
            dataType: huaweiStepsDataType,
            startTime: 900,
            endTime: 2100,
            samplingTime: 2100,
            fields: const {huaweiStepsField: 12},
          ),
          HuaweiSample(
            dataType: huaweiHeartRateDataType,
            startTime: 3000,
            endTime: 3000,
            samplingTime: 3000,
            fields: const {huaweiBpmField: 99},
          ),
          HuaweiSample(
            dataType: huaweiStepsDataType,
            startTime: 3000,
            endTime: 4000,
            samplingTime: 4000,
            fields: const {huaweiStepsField: 9},
          ),
          HuaweiSample(
            dataType: 'DT_UNSUPPORTED',
            startTime: 1200,
            endTime: 1200,
            samplingTime: 1200,
            fields: const {'FIELD_UNSUPPORTED': 1},
          ),
        ];
      final port = HuaweiHealthPort(sdk, approved: true);

      expect(await port.request(), true);
      expect(await port.queryable(), true);
      expect(await port.read(1000, 3000), [
        ['heart_rate', 1200, 1200, 72.0],
        ['steps', 900, 2100, 12.0],
      ]);
      expect(sdk.requestedScopes, huaweiReadScopes);
      expect(sdk.initializations, 1);
      expect(sdk.reads, 1);
    },
  );

  test(
    'Huawei activity records mark overlapping health windows as exercise',
    () async {
      final sdk = _SyntheticHuaweiSdk()
        ..samples = [
          HuaweiSample(
            dataType: huaweiHeartRateDataType,
            startTime: 1200,
            endTime: 1200,
            samplingTime: 1200,
            fields: const {huaweiBpmField: 72},
          ),
        ]
        ..activityRecords = [
          HuaweiActivityRecord(startTime: 1000, endTime: 2100),
          HuaweiActivityRecord(startTime: 30000, endTime: 40000),
        ];
      final port = HuaweiHealthPort(sdk, approved: true);
      expect(await port.request(), true);

      final rows = await port.read(0, 30000);
      expect(rows, [
        ['heart_rate', 1200, 1200, 72.0],
        ['exercise', 1000, 2100, 1.0],
      ]);
      expect(
        healthWindows('huawei_history', 0, 30000, rows).single['exercise'],
        true,
      );
      expect(sdk.activityReads, 1);
    },
  );

  test('Health app authorization revocation blocks future reads', () async {
    final sdk = _SyntheticHuaweiSdk();
    final port = HuaweiHealthPort(sdk, approved: true);
    expect(await port.request(), true);
    expect(await port.queryable(), true);

    sdk.authorized = false;
    expect(await port.queryable(), false);
    expect(await port.read(0, 30000), isEmpty);
    expect(sdk.reads, 0);

    sdk.authorized = true;
    expect(await port.queryable(), true);
    expect(sdk.reads, 0);
  });

  test(
    'a restarted port restores granted scopes without another sign-in',
    () async {
      final sdk = _SyntheticHuaweiSdk();
      final original = HuaweiHealthPort(sdk, approved: true);
      expect(await original.request(), true);

      // Production creates a new port after process restart. The signed-in HMS
      // grant persists, but this adapter's in-memory scope set does not.
      final restarted = HuaweiHealthPort(sdk, approved: true);
      expect(await restarted.queryable(), true);
      expect(sdk.signIns, 1);
      expect(sdk.scopeQueries, 1);
    },
  );

  test('stale scope query cannot overwrite a reauthorization', () async {
    final sdk = _SyntheticHuaweiSdk()
      ..grantable = {huaweiHeartRateReadScope}
      ..scopeQueryStarted = Completer<void>()
      ..holdScopeQuery = Completer<void>();
    final port = HuaweiHealthPort(sdk, approved: true);

    final staleQuery = port.queryable();
    await sdk.scopeQueryStarted!.future;
    await port.stop();
    sdk.grantable = {...huaweiReadScopes};
    expect(await port.request(), true);

    sdk.holdScopeQuery!.complete();
    expect(await staleQuery, false);
    expect(await port.queryable(), true);
    expect(sdk.scopeQueries, 2);
  });

  test(
    'stale authorization result cannot overwrite a newer scope query',
    () async {
      final sdk = _SyntheticHuaweiSdk()
        ..grantable = {huaweiHeartRateReadScope}
        ..signInStarted = Completer<void>()
        ..holdSignIn = Completer<void>();
      final port = HuaweiHealthPort(sdk, approved: true);

      final staleRequest = port.request();
      await sdk.signInStarted!.future;
      await port.stop();
      sdk.grantable = {...huaweiReadScopes};
      expect(await port.queryable(), true);

      sdk.holdSignIn!.complete();
      expect(await staleRequest, false);
      expect(await port.queryable(), true);
    },
  );

  test(
    'preflight cancellation never notifies prompt or starts HMS sign-in',
    () async {
      final sdk = _SyntheticHuaweiSdk()
        ..appIdCheckStarted = Completer<void>()
        ..holdAppIdCheck = Completer<void>();
      final port = HuaweiHealthPort(sdk, approved: true);
      var promptStarted = false;

      final request = port.request(onSystemPrompt: () => promptStarted = true);
      await sdk.appIdCheckStarted!.future;
      expect(promptStarted, false);

      await port.stop();
      sdk.holdAppIdCheck!.complete();

      expect(await request, false);
      expect(promptStarted, false);
      expect(sdk.signIns, 0);
    },
  );

  test('system prompt boundary fires only after app id preflight', () async {
    final sdk = _SyntheticHuaweiSdk()
      ..appIdCheckStarted = Completer<void>()
      ..holdAppIdCheck = Completer<void>();
    final port = HuaweiHealthPort(sdk, approved: true);
    var promptStarted = false;

    final request = port.request(onSystemPrompt: () => promptStarted = true);
    await sdk.appIdCheckStarted!.future;
    expect(promptStarted, false);

    sdk.holdAppIdCheck!.complete();
    expect(await request, true);
    expect(promptStarted, true);
    expect(sdk.signIns, 1);
  });

  test('stopping during SDK initialization prevents the HMS read', () async {
    final sdk = _SyntheticHuaweiSdk()
      ..initStarted = Completer<void>()
      ..holdInit = Completer<void>();
    final port = HuaweiHealthPort(sdk, approved: true);
    expect(await port.request(), true);

    final reading = port.read(0, 30000);
    await sdk.initStarted!.future;
    await port.stop();
    sdk.holdInit!.complete();

    expect(await reading, isEmpty);
    expect(sdk.reads, 0);
  });

  test('malformed and negative SDK samples are discarded', () async {
    final sdk = _SyntheticHuaweiSdk()
      ..samples = [
        HuaweiSample(
          dataType: huaweiHeartRateDataType,
          startTime: 1000,
          endTime: 1000,
          samplingTime: 1000,
          fields: const {huaweiBpmField: -1},
        ),
        HuaweiSample(
          dataType: huaweiStepsDataType,
          startTime: 2000,
          endTime: 1000,
          samplingTime: 1000,
          fields: const {huaweiStepsField: 5},
        ),
        HuaweiSample(
          dataType: huaweiHeartRateDataType,
          startTime: 1000,
          endTime: 1000,
          samplingTime: 1000,
          fields: const {},
        ),
      ];
    final port = HuaweiHealthPort(sdk, approved: true);
    expect(await port.request(), true);
    expect(await port.read(0, 30000), isEmpty);
  });

  test(
    'signIn decodes pinned plugin JSON and fails closed when malformed',
    () async {
      var response = jsonEncode({
        'grantedScopes': [
          {'mScopeUri': huaweiHeartRateReadScope},
          {'mScopeUri': huaweiStepReadScope},
          {'mScopeUri': huaweiActivityReadScope},
        ],
      });
      MethodCall? authCall;
      _mockChannel(_authChannel, (call) async {
        authCall = call;
        return response;
      });
      final sdk = MethodChannelHuaweiHealthSdk();

      final result = await sdk.signIn(huaweiReadScopes);
      expect(result?.grantedScopes, huaweiReadScopes);
      expect(authCall?.method, 'signIn');
      final arguments = authCall?.arguments as Map<Object?, Object?>?;
      expect(arguments?['scopes'], containsAll(huaweiReadScopes));

      response = '{not-json';
      final malformed = await sdk.signIn(huaweiReadScopes);
      expect(malformed?.grantedScopes, isEmpty);
    },
  );

  test(
    'read sends pinned ReadOptions maps and parses sample collectors',
    () async {
      MethodCall? readCall;
      _mockChannel(_dataChannel, (call) async {
        readCall = call;
        return {
          'sampleSets': [
            {
              'dataCollector': {
                'dataType': {'name': huaweiHeartRateDataType},
              },
              'samplePoints': [
                {
                  'startTime': 1200,
                  'endTime': 1200,
                  'samplingTime': 1200,
                  'fieldValues': {huaweiBpmField: 72},
                },
              ],
            },
            {
              'dataCollector': {'dataTypeName': huaweiStepsDataType},
              'samplePoints': [
                {
                  'startTime': '900',
                  'endTime': '2100',
                  'fieldValues': {huaweiStepsField: 12},
                },
              ],
            },
          ],
        };
      });

      final samples = await MethodChannelHuaweiHealthSdk().read(1000, 3000);

      expect(readCall?.method, 'read');
      final arguments = readCall?.arguments as Map<Object?, Object?>?;
      expect(arguments?['startTime'], 1000);
      expect(arguments?['endTime'], 3000);
      expect(arguments?['timeUnit'], 'MILLISECONDS');
      final dataTypes = arguments?['dataTypes'] as List<Object?>?;
      expect(dataTypes, hasLength(2));
      final heartType = dataTypes![0] as Map<Object?, Object?>;
      final stepType = dataTypes[1] as Map<Object?, Object?>;
      expect(heartType['name'], huaweiHeartRateDataType);
      expect(heartType['scopeNameRead'], huaweiHeartRateReadScope);
      expect(stepType['name'], huaweiStepsDataType);
      expect(stepType['scopeNameRead'], huaweiStepReadScope);
      final heartField =
          (heartType['fields'] as List<Object?>).single
              as Map<Object?, Object?>;
      final stepField =
          (stepType['fields'] as List<Object?>).single as Map<Object?, Object?>;
      expect(heartField['name'], huaweiBpmField);
      expect(heartField['format'], 2);
      expect(stepField['name'], huaweiStepsField);
      expect(stepField['format'], 1);

      expect(samples, hasLength(2));
      expect(samples[0].dataType, huaweiHeartRateDataType);
      expect(samples[0].startTime, 1200);
      expect(samples[0].samplingTime, 1200);
      expect(samples[0].fields, {huaweiBpmField: 72});
      expect(samples[1].dataType, huaweiStepsDataType);
      expect(samples[1].startTime, 900);
      expect(samples[1].endTime, 2100);
      expect(samples[1].fields, {huaweiStepsField: 12});
    },
  );

  test(
    'readActivityRecords sends pinned options and parses record windows',
    () async {
      MethodCall? readCall;
      _mockChannel(_activityChannel, (call) async {
        readCall = call;
        return [
          {
            'activityRecord': {'startTime': 1000, 'endTime': 2100},
          },
          {
            'activityRecord': {'startTime': 3000, 'endTime': 2500},
          },
          {
            'activityRecord': {'startTime': 'bad', 'endTime': 4000},
          },
          {
            'activityRecord': {'startTime': 5000},
          },
          'invalid record',
        ];
      });

      final records = await MethodChannelHuaweiHealthSdk().readActivityRecords(
        1000,
        3000,
      );

      expect(readCall?.method, 'getActivityRecord');
      final arguments = readCall?.arguments as Map<Object?, Object?>?;
      expect(arguments?['startTime'], 1000);
      expect(arguments?['endTime'], 3000);
      expect(arguments?['timeUnit'], 'MILLISECONDS');
      expect(records, hasLength(1));
      expect(records.single.startTime, 1000);
      expect(records.single.endTime, 2100);
    },
  );

  test(
    'Huawei source rejects a missing release app id before sign-in',
    () async {
      var platformCalls = 0;
      var settingCalls = 0;
      var authCalls = 0;
      _mockChannel(_platformChannel, (call) async {
        platformCalls++;
        expect(call.method, 'huaweiAppId');
        return null;
      });
      _mockChannel(_settingChannel, (call) async {
        settingCalls++;
        fail('missing release app id must not reach AG Connect');
      });
      _mockChannel(_authChannel, (call) async {
        authCalls++;
        return null;
      });
      final port = HuaweiHealthPort(
        MethodChannelHuaweiHealthSdk(),
        approved: true,
      );

      await expectLater(port.source(), throwsA(isA<StateError>()));
      await expectLater(port.request(), throwsA(isA<StateError>()));
      expect(platformCalls, 2);
      expect(settingCalls, 0);
      expect(authCalls, 0);
    },
  );

  test(
    'Huawei read rejects a missing AG Connect app id before sign-in',
    () async {
      var settingCalls = 0;
      var authCalls = 0;
      _mockChannel(_platformChannel, (call) async {
        expect(call.method, 'huaweiAppId');
        return 'expected-app-id';
      });
      _mockChannel(_settingChannel, (call) async {
        settingCalls++;
        expect(call.method, 'getAppId');
        return '';
      });
      _mockChannel(_authChannel, (call) async {
        authCalls++;
        return null;
      });
      final port = HuaweiHealthPort(
        MethodChannelHuaweiHealthSdk(),
        approved: true,
      );

      await expectLater(port.read(0, 30000), throwsA(isA<StateError>()));
      expect(settingCalls, 1);
      expect(authCalls, 0);
    },
  );

  test('Huawei source rejects an AG Connect app id mismatch', () async {
    var settingCalls = 0;
    var authCalls = 0;
    _mockChannel(_platformChannel, (call) async {
      expect(call.method, 'huaweiAppId');
      return 'expected-app-id';
    });
    _mockChannel(_settingChannel, (call) async {
      settingCalls++;
      expect(call.method, 'getAppId');
      return 'different-app-id';
    });
    _mockChannel(_authChannel, (call) async {
      authCalls++;
      return null;
    });
    final port = HuaweiHealthPort(
      MethodChannelHuaweiHealthSdk(),
      approved: true,
    );

    await expectLater(port.source(), throwsA(isA<StateError>()));
    await expectLater(port.read(0, 30000), throwsA(isA<StateError>()));
    expect(settingCalls, 2);
    expect(authCalls, 0);
  });

  test('getGrantedScopes reads non-interactive consent URLs', () async {
    final calls = <MethodCall>[];
    _mockChannel(_settingChannel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'getAppId' => 'app-id',
        'get' => {
          'url2Desc': {
            huaweiHeartRateReadScope: 'Heart rate',
            huaweiStepReadScope: 'Steps',
            huaweiActivityReadScope: 'Workouts',
          },
        },
        _ => fail('unexpected setting method ${call.method}'),
      };
    });

    final scopes = await MethodChannelHuaweiHealthSdk().getGrantedScopes();

    expect(scopes, huaweiReadScopes);
    expect(calls.map((call) => call.method), ['getAppId', 'get']);
    expect(calls.last.arguments, {'lang': 'en-US', 'appId': 'app-id'});
  });

  test('getGrantedScopes fails closed on malformed consent payloads', () async {
    _mockChannel(_settingChannel, (call) async {
      return switch (call.method) {
        'getAppId' => 'app-id',
        'get' => {'url2Desc': null},
        _ => fail('unexpected setting method ${call.method}'),
      };
    });

    await expectLater(
      MethodChannelHuaweiHealthSdk().getGrantedScopes(),
      throwsFormatException,
    );
  });

  test(
    'unapproved and partial grants make no setting or data channel call',
    () async {
      var authCalls = 0;
      var settingCalls = 0;
      var dataCalls = 0;
      _mockChannel(_authChannel, (call) async {
        authCalls++;
        return jsonEncode({
          'grantedScopes': [
            {'mScopeUri': huaweiHeartRateReadScope},
          ],
        });
      });
      _mockChannel(_platformChannel, (call) async {
        expect(call.method, 'huaweiAppId');
        return 'app-id';
      });
      _mockChannel(_settingChannel, (call) async {
        settingCalls++;
        if (call.method == 'getAppId') return 'app-id';
        return true;
      });
      _mockChannel(_dataChannel, (call) async {
        dataCalls++;
        return <String, Object?>{};
      });
      final sdk = MethodChannelHuaweiHealthSdk();

      final unapproved = HuaweiHealthPort(sdk, approved: false);
      expect(await unapproved.source(), isNull);
      expect(await unapproved.request(), false);
      expect(await unapproved.queryable(), false);
      expect(await unapproved.read(0, 30000), isEmpty);
      expect((authCalls, settingCalls, dataCalls), (0, 0, 0));

      final partial = HuaweiHealthPort(sdk, approved: true);
      expect(await partial.request(), false);
      expect(await partial.queryable(), false);
      expect(await partial.read(0, 30000), isEmpty);
      expect((authCalls, settingCalls, dataCalls), (1, 3, 0));
    },
  );
}
