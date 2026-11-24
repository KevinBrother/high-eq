import 'package:flutter_test/flutter_test.dart';

const _realAsyncTimeout = Duration(seconds: 5);

/// Runs encrypted file work on the real event loop within a fixed deadline.
///
/// `runAsync` catches callback errors and reports them through
/// `tester.takeException()`. Re-throwing here keeps repository failures visible
/// at the assertion that triggered them.
Future<T> runRealAsync<T>(
  WidgetTester tester,
  Future<T> Function() action,
) async {
  T? value;
  Object? error;
  StackTrace? stackTrace;
  var completed = false;

  await tester.runAsync(() async {
    try {
      value = await action().timeout(_realAsyncTimeout);
      completed = true;
    } catch (caught, trace) {
      error = caught;
      stackTrace = trace;
    }
  });

  if (error != null) Error.throwWithStackTrace(error!, stackTrace!);
  if (!completed) {
    fail('真实异步存储未在 ${_realAsyncTimeout.inSeconds} 秒内完成');
  }
  return value as T;
}

/// Advances real file I/O and widget frames together until [ready] is true.
///
/// Widget work starts in FakeAsync, while encrypted file continuations need the
/// real event loop. `pumpAndSettle` only advances FakeAsync and can spin on an
/// indeterminate progress indicator for its ten-minute default timeout.
Future<void> pumpRealAsyncUntil(
  WidgetTester tester,
  bool Function() ready, {
  required String reason,
}) async {
  final deadline = DateTime.now().add(_realAsyncTimeout);
  while (!ready()) {
    if (!DateTime.now().isBefore(deadline)) {
      fail('$reason（${_realAsyncTimeout.inSeconds} 秒内）');
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }

  // Let the state change that satisfied [ready] finish its next frame without
  // waiting for unrelated animations to settle.
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump(const Duration(milliseconds: 16));
}
