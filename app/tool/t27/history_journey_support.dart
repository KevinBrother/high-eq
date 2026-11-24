import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'history_trace.dart';

class JourneyFrames {
  JourneyFrames(this.tester);

  final WidgetTester tester;
  String stage = 'page.fixture';
  static const _limit = Duration(seconds: 25);
  static const _gestureLimit = Duration(seconds: 10);
  static const _frame = Duration(milliseconds: 16);

  Future<void> phase(String name, Future<void> Function() action) async {
    stage = 'page.$name';
    debugPrintSynchronously('BEGIN($stage)');
    final clock = Stopwatch()..start();
    try {
      await action();
      final exception = tester.takeException();
      if (exception != null) throw TestFailure('Flutter exception: $exception');
      debugPrintSynchronously(
        'OBSERVED($stage.duration): ${clock.elapsedMilliseconds}ms',
      );
      debugPrintSynchronously('PASS($stage)');
    } catch (error) {
      final texts = find
          .byType(Text)
          .evaluate()
          .map((e) => (e.widget as Text).data)
          .whereType<String>()
          .where((s) => s.isNotEmpty)
          .take(20);
      debugPrintSynchronously(
        'FAIL($stage) after ${clock.elapsedMilliseconds}ms: $error; '
        'rendered: ${texts.join(' | ')}',
      );
      rethrow;
    }
  }

  Future<void> frame() async {
    await tester.pump(_frame);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 8)),
    );
  }

  Future<void> until(
    bool Function() done,
    String waitingFor, {
    Duration limit = _limit,
  }) async {
    final clock = Stopwatch()..start();
    while (!done()) {
      if (clock.elapsed >= limit) {
        throw TestFailure(
          'Timed out in $stage after ${limit.inSeconds}s waiting for '
          '$waitingFor',
        );
      }
      await frame();
    }
  }

  // Launch I/O in a real zone and yield back immediately. Pending widget-zone
  // callbacks can now finish between real I/O turns, including queued cache ops.
  Future<T> real<T>(Future<T> Function() action, String waitingFor) async {
    ({T value})? completed;
    ({Object error, StackTrace stack})? failed;
    await tester.runAsync(() async {
      unawaited(() async {
        try {
          completed = (value: await action().timeout(_limit));
        } catch (error, stack) {
          failed = (error: error, stack: stack);
        }
      }());
    });
    await until(() => completed != null || failed != null, waitingFor);
    if (failed case final result?) {
      Error.throwWithStackTrace(result.error, result.stack);
    }
    return completed!.value;
  }

  Future<void> appeared(
    Finder target,
    String description, {
    Duration limit = _limit,
  }) => until(() => target.evaluate().isNotEmpty, description, limit: limit);

  List<Element> _onCurrentRoute(Finder target) {
    final matches = <Element>[];
    for (final element in target.evaluate()) {
      final route = ModalRoute.of(element);
      if (route != null && route.isActive && route.isCurrent) {
        matches.add(element);
      }
    }
    return matches;
  }

  Finder _exact(Element element) => find.byElementPredicate(
    (candidate) => identical(candidate, element),
    description: 'exact current-route element',
  );

  Future<Finder> _uniqueElement(
    List<Element> Function() candidates,
    String description, {
    Duration limit = _gestureLimit,
  }) async {
    final clock = Stopwatch()..start();
    while (true) {
      final matches = candidates();
      if (matches.length > 1) {
        throw TestFailure(
          'Ambiguous $description in $stage: ${matches.length} matches on '
          'the current route; refusing to choose one arbitrarily',
        );
      }
      if (matches.length == 1) return _exact(matches.single);
      if (clock.elapsed >= limit) {
        throw TestFailure(
          'Timed out in $stage after ${limit.inSeconds}s waiting for '
          '$description on the current route',
        );
      }
      await frame();
    }
  }

  Future<Finder> _current(
    Finder target,
    String description, {
    Duration limit = _gestureLimit,
  }) =>
      _uniqueElement(() => _onCurrentRoute(target), description, limit: limit);

  bool _isEditorScroller(Element element) {
    var insideEditor = false;
    element.visitAncestorElements((ancestor) {
      if (ancestor.widget is EditableText) {
        insideEditor = true;
        return false;
      }
      return true;
    });
    return insideEditor;
  }

  List<Element> _verticalHistoryScrollables(Element scope) {
    final matches = <Element>[];
    final scrollables = find.descendant(
      of: _exact(scope),
      matching: find.byType(Scrollable),
    );
    for (final element in scrollables.evaluate()) {
      final widget = element.widget;
      if (widget is! Scrollable) continue;
      final vertical =
          widget.axisDirection == AxisDirection.up ||
          widget.axisDirection == AxisDirection.down;
      if (vertical && !_isEditorScroller(element)) matches.add(element);
    }
    return matches;
  }

  Future<void> show(
    Finder target, {
    required Finder within,
    bool scrollBack = false,
  }) async {
    final scope = await _current(within, 'current route scope $within');
    final scopeElement = scope.evaluate().single;
    final scrollable = await _uniqueElement(
      () => _verticalHistoryScrollables(scopeElement),
      'vertical history scrollable in current $within',
    );
    final clock = Stopwatch()..start();
    final delta = Offset(0, scrollBack ? 400 : -400);
    while (true) {
      final matches = _onCurrentRoute(target);
      if (matches.length > 1) {
        throw TestFailure(
          'Ambiguous target $target in $stage: ${matches.length} matches on '
          'the current route; refusing to choose one arbitrarily',
        );
      }
      if (matches.length == 1) {
        final exact = _exact(matches.single);
        await tester.ensureVisible(exact);
        await frame();
        return;
      }
      if (clock.elapsed >= _limit) {
        throw TestFailure('Could not scroll to $target in $stage');
      }
      await tester.drag(scrollable, delta);
      await frame();
    }
  }

  Future<void> tap(Finder target) async {
    var exact = await _current(target, 'control $target');
    await tester.ensureVisible(exact);
    await frame();
    exact = await _current(target, 'control $target after scrolling');
    final visible = exact.hitTestable();
    await appeared(
      visible,
      'hittable control $target on the current route',
      limit: _gestureLimit,
    );
    await tester.tap(visible);
    await frame();
  }

  Future<void> backTo(Finder parent, Finder child) async {
    // Simulate platform Back. pageBack() requires a platform-specific button.
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.navigation.name,
      SystemChannels.navigation.codec.encodeMethodCall(
        const MethodCall('popRoute'),
      ),
      null,
    );
    await until(
      () => parent.evaluate().isNotEmpty && child.evaluate().isEmpty,
      'parent route $parent after platform Back',
    );
  }
}

class MemorySecret implements SecretStore {
  String? _value;

  @override
  Future<String?> read() async => _value;

  @override
  Future<void> replace(String? value) async => _value = value;
}

/// Mirrors the production provider's stable cache and support ownership.
///
/// A fresh [Sessions] from the same storage root restores the same account and
/// reads the same account-scoped fences. The root is supplied by the journey
/// fixture and lives for the complete run, unlike the deleted encryption key.
class JourneyStorage {
  JourneyStorage(this.root) : secret = MemorySecret();

  static const backend = 't27-history';

  final Directory root;
  final MemorySecret secret;

  Directory get cacheDirectory =>
      Directory('${root.path}/cache/accounts/$backend');

  Directory get supportDirectory => Directory('${root.path}/support');

  File get retirementBarrier =>
      File('${supportDirectory.path}/session-retirement/$backend.v1');

  Directory get growthDeletionDirectory =>
      Directory('${supportDirectory.path}/growth-deletion/$backend');

  Sessions open() => Sessions(
    secret,
    cacheDirectory,
    retirementBarrier: retirementBarrier,
    growthDeletionDirectory: growthDeletionDirectory,
  );
}

class _RealHttpOverrides extends HttpOverrides {}

class JourneyWire implements Transport {
  JourneyWire(this.origin)
    : _http = HttpTransport(
        HttpOverrides.runWithHttpOverrides(
          () => IOClient(HttpClient()..findProxy = (_) => 'DIRECT'),
          _RealHttpOverrides(),
        ),
      );

  final Uri origin;
  final HttpTransport _http;
  final _reads = <HistoryRead>[];
  final _deletions = <({String path, int status, bool ok})>[];
  int _event = 0;
  bool historyUnavailable = false;

  int mark() => _event;

  List<HistoryRead> readsAfter(int mark) =>
      _reads.where((read) => read.requestOrder > mark).toList();

  List<({String path, int status, bool ok})> get deletions =>
      List.unmodifiable(_deletions);

  String historyReceipt(int mark) {
    final counts = <String, int>{};
    for (final read in readsAfter(mark)) {
      final key =
          '${read.cursor ?? "first"} → ${read.nextCursor ?? "end"} '
          'status=${read.status} limit=${read.limit} rows=${read.ids.length}';
      counts.update(key, (count) => count + 1, ifAbsent: () => 1);
    }
    return counts.entries.map((row) => '${row.key} ×${row.value}').join(', ');
  }

  @override
  Future<http.StreamedResponse> send(AppOp op, http.Request request) async {
    if (request.url.origin != origin.origin) {
      throw StateError('journey request left the disposable HTTP origin');
    }
    final history = op == AppOp.listSessions;
    final order = ++_event;
    final cursor = request.url.queryParameters['cursor'];
    final limit = request.url.queryParameters['limit'];
    if (history && historyUnavailable) {
      request.headers['x-t27-history-outage'] = '1';
    }

    // Receive the full response in a real zone. Return I/O failures as values
    // across the zone boundary and let the production API decode the actual bytes.
    final result = await Zone.root.run(() async {
      try {
        final response = await _http.send(op, request);
        return (
          response: response,
          body: await response.stream.toBytes(),
          failure: null,
        );
      } catch (error, stack) {
        return (
          response: null,
          body: null,
          failure: (error: error, stack: stack),
        );
      }
    });
    if (result.failure case final failure?) {
      Error.throwWithStackTrace(failure.error, failure.stack);
    }
    final response = result.response!;
    final body = result.body!;
    final status = response.statusCode;
    final json = status == 200 && (history || op == AppOp.deleteContact)
        ? jsonDecode(utf8.decode(body)) as Map<String, dynamic>
        : const <String, dynamic>{};
    if (history) {
      final items = json['items'] as List? ?? const [];
      _reads.add(
        HistoryRead(
          order,
          cursor,
          limit,
          status,
          json['next_cursor'] as String?,
          [for (final item in items) item['session_id'] as String],
          responseOrder: ++_event,
        ),
      );
    } else if (op == AppOp.deleteContact) {
      _deletions.add((
        path: request.url.path,
        status: status,
        ok: json['ok'] == true,
      ));
    }
    return http.StreamedResponse(
      Stream.value(body),
      status,
      headers: response.headers,
      request: response.request,
    );
  }

  @override
  void close() => _http.close();
}
