import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart' hide within;
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/endpoints.g.dart';
import 'package:high_eq/core/providers.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/home/shell.dart';
import 'package:high_eq/features/onboarding/login.dart';
import 'package:high_eq/features/onboarding/repository.dart';
import 'package:high_eq/features/privacy/export_namespace.dart';
import 'package:high_eq/features/privacy/page.dart';
import 'package:high_eq/main.dart';

import '../../test/privacy/account_journey_test.dart' show currentPage, within;
import '../../test/privacy/export_test_support.dart'
    show reportPrivacyExportPresented;
import '../t26/transport.dart';
import '../t27/history_journey_support.dart' show JourneyFrames, MemorySecret;

const _bridge = MethodChannel('cn.higheq/mobile-commerce');
const _paths = MethodChannel('plugins.flutter.io/path_provider');
const _opening = '正在打开系统面板…';
const _presenting = '请在系统面板中完成保存或分享。';
const _completed = '系统已完成保存或分享。';

class _ExportBinding extends LiveTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

String _input(String key) {
  final value = Platform.environment['T35_EXPORT_$key'];
  if (value == null || value.isEmpty) {
    throw StateError('Missing T35 export input. Run export_journey.py.');
  }
  return value;
}

void main() {
  _ExportBinding().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;

  testWidgets(
    'T35 formal account export over real HTTP',
    (tester) async {
      final origin = Uri.parse(_input('ORIGIN'));
      expect(
        origin.scheme == 'http' &&
            origin.host == '127.0.0.1' &&
            origin.hasPort &&
            origin.userInfo.isEmpty &&
            origin.path.isEmpty &&
            !origin.hasQuery &&
            !origin.hasFragment,
        isTrue,
        reason: 'expected a disposable IPv4 loopback origin',
      );
      final scratch = Directory(_input('SCRATCH'));
      final staging = Directory('${scratch.path}/staging')..createSync();
      final sessions = Sessions(
        MemorySecret(),
        Directory('${scratch.path}/sessions'),
      );
      await sessions.restore();
      final transport = HttpTransport(t26LoopbackClient());
      addTearDown(transport.close);
      final api = AppApi(origin, transport, sessions);

      final frames = JourneyFrames(tester);
      final messenger = tester.binding.defaultBinaryMessenger;
      // Supply the host directory for real staging; the export method channel
      // below is the only substitute for any part of download/validation/share.
      messenger.setMockMethodCallHandler(_paths, (call) async {
        expect(call.method, 'getTemporaryDirectory');
        expect(call.arguments, isNull);
        return staging.path;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(_paths, null));
      addTearDown(() => messenger.setMockMethodCallHandler(_bridge, null));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [apiProvider.overrideWith((_) => api)],
          child: const HighEqApp(),
        ),
      );

      final a = _input('ACCOUNT_A');
      final b = _input('ACCOUNT_B');
      expect(a != b, isTrue, reason: 'expected two different accounts');
      final namespaceA = await privacyExportAccountDirectory(staging, a);
      final namespaceB = await privacyExportAccountDirectory(staging, b);
      expect(namespaceA.path != namespaceB.path, isTrue);

      Future<void> exportAccount(
        String label,
        String account,
        Directory namespace,
      ) async {
        frames.stage = 'page.account-$label';
        debugPrintSynchronously('BEGIN(${frames.stage})');
        final key = label.toUpperCase();
        // Consume a one-use development ticket through the real login route.
        final token = Tokens.fromJson(
          await MobileEndpoints(api).login(
            body: {
              'credential': {
                'provider': 'apple',
                'proof': _input('TICKET_$key'),
              },
              'age_confirmed': true,
              'privacy_version': policyVersion,
              'terms_version': policyVersion,
            },
          ),
        );
        final scope = await sessions.activate(token);
        expect(
          scope.account == account,
          isTrue,
          reason: 'login account mismatch',
        );

        final practice = currentPage<HomeShell>('/practice');
        final navigation = within(practice, find.byType(NavigationBar));
        await frames.tap(
          within(
            navigation,
            find.byWidgetPredicate(
              (widget) =>
                  widget is NavigationDestination && widget.label == '我的',
            ),
          ),
        );
        final me = currentPage<HomeShell>('/me');
        final tile = within(me, find.byKey(const Key('me-privacy')));
        await frames.show(tile, within: me);
        await frames.tap(tile);
        final privacy = currentPage<PrivacyPage>('/privacy');
        await frames.appeared(
          within(privacy, find.text('隐私与个人数据')),
          'formal privacy page',
        );
        await frames.until(
          () =>
              within(privacy, find.text('账号 $account')).evaluate().length == 1,
          'privacy page of the signed-in account',
        );
        final export = within(privacy, find.byKey(const Key('privacy-export')));
        final waiting = within(privacy, find.text(_presenting));
        final completed = within(privacy, find.text(_completed));
        await frames.show(export, within: privacy);

        final receiver = _SyntheticReceiver(
          staging,
          namespace,
          File('${scratch.path}/accepted-$label.zip'),
        );
        messenger.setMockMethodCallHandler(_bridge, receiver.receive);
        try {
          expect(staging.listSync(), isEmpty);
          expect(receiver.delivered, isFalse);
          await frames.tap(export);
          await frames.until(
            () => receiver.delivered,
            'private ZIP at system receiver',
          );
          await frames.appeared(
            within(privacy, find.text(_opening)),
            'formal page waiting for the system to present',
          );
          expect(waiting, findsNothing);
          expect(completed, findsNothing);
          receiver.requireHeldZIP();

          await receiver.present(messenger);
          // Receiver I/O and platform messages may complete after a pump.
          await frames.appeared(
            waiting,
            'formal page while the system holds the ZIP',
          );
          expect(waiting, findsOneWidget);
          expect(completed, findsNothing);
          receiver.requireHeldZIP();
          receiver.finish();
          await frames.appeared(
            completed,
            'formal completion after receiver acknowledgment',
          );
          expect(waiting, findsNothing);
          expect(
            staging.listSync(),
            isEmpty,
            reason: 'delivery must remove staged ZIP and owner sidecar',
          );
        } finally {
          receiver.finish();
        }
        debugPrintSynchronously('PASS(${frames.stage})');
      }

      await exportAccount('a', a, namespaceA);
      frames.stage = 'page.account-b';
      await sessions.clear();
      await frames.appeared(
        currentPage<LoginPage>('/'),
        'signed-out page before account B',
      );
      expect(sessions.active, isNull);
      expect(find.byType(PrivacyPage, skipOffstage: false), findsNothing);
      await exportAccount('b', b, namespaceB);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({TargetPlatform.iOS}),
  );
}

class _SyntheticReceiver {
  _SyntheticReceiver(this.staging, this.namespace, this.accepted);

  final Directory staging;
  final Directory namespace;
  final File accepted;
  final _receipt = Completer<void>();
  final _calls = <String>[];
  File? _artifact;
  int? _requestId;
  bool get delivered => _artifact != null;

  Future<Object?> receive(MethodCall call) async {
    _calls.add(call.method);
    if (call.method == 'cleanupStatus') {
      expect(_calls, List.filled(_calls.length, 'cleanupStatus'));
      expect(_calls.length, lessThanOrEqualTo(2));
      expect(call.arguments, isNull);
      return {'state': 'ok', 'removed': 0, 'failed': 0};
    }
    expect(_calls, ['cleanupStatus', 'cleanupStatus', 'shareExport']);
    final args = call.arguments as Map;
    expect(args.keys, unorderedEquals(['path', 'mimeType', 'requestId']));
    expect(args['mimeType'], 'application/zip');
    final requestId = args['requestId'] as int;
    expect(requestId, isPositive);
    final file = File(args['path'] as String);
    expect(file.parent.path == namespace.path, isTrue);
    expect(
      RegExp(
        r'^high-eq-export-[0-9]+(?:-[0-9]+)?\.zip$',
      ).hasMatch(file.uri.pathSegments.last),
      isTrue,
    );
    _requirePublished(file);
    expect(accepted.existsSync(), isFalse);
    // This private test copy lets Go compare the actual delivered bytes with
    // the wire response and parse the complete archive independently.
    file.copySync(accepted.path);
    _requestId = requestId;
    _artifact = file;
    await _receipt.future;
    return null;
  }

  void _requirePublished(File file) {
    expect(
      FileSystemEntity.typeSync(namespace.path, followLinks: false),
      FileSystemEntityType.directory,
    );
    final sidecar = File('${file.path}.owner');
    expect(
      FileSystemEntity.typeSync(file.path, followLinks: false),
      FileSystemEntityType.file,
    );
    expect(
      FileSystemEntity.typeSync(sidecar.path, followLinks: false),
      FileSystemEntityType.file,
    );
    expect(file.lengthSync(), greaterThan(0));
    final owner = jsonDecode(sidecar.readAsStringSync()) as Map;
    expect(owner['format'], 'high-eq-privacy-export-owner-v1');
    expect(owner['device'], isA<int>());
    expect(owner['inode'], isA<int>());
    final entries = staging.listSync(recursive: true, followLinks: false);
    final expected = {
      namespace.parent.path,
      namespace.path,
      file.path,
      sidecar.path,
    };
    expect(
      entries.length == expected.length &&
          entries.every((entry) => expected.contains(entry.path)),
      isTrue,
    );
  }

  Future<void> present(TestDefaultBinaryMessenger messenger) {
    requireHeldZIP();
    return reportPrivacyExportPresented(messenger, _requestId!);
  }

  void requireHeldZIP() {
    expect(_receipt.isCompleted, isFalse);
    _requirePublished(_artifact!);
  }

  void finish() {
    if (!_receipt.isCompleted) _receipt.complete();
  }
}
