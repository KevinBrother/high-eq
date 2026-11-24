import 'history_trace.dart';

void main() {
  const first = HistoryRead(1, null, '100', 200, 'page-b', ['legacy', 'full']);
  const duplicate = HistoryRead(2, null, '100', 200, 'page-b', [
    'legacy',
    'full',
  ]);
  const last = HistoryRead(3, 'page-b', '100', 200, null, ['single']);
  const reads = [first, duplicate, last];

  void check(List<HistoryRead> trace, bool expected, String label) {
    final actual = hasHistoryChain(
      trace,
      firstCount: 2,
      firstIds: {'legacy', 'full'},
      lastId: 'single',
    );
    if (actual != expected) throw StateError(label);
  }

  check(
    reads,
    true,
    'a duplicate first-page read must preserve the valid chain',
  );
  check([last, first], false, 'a second-page request cannot predate discovery');
  check(
    [
      const HistoryRead(1, null, '100', 200, 'page-b', [
        'legacy',
        'full',
      ], responseOrder: 4),
      last,
    ],
    false,
    'an in-flight first page has not revealed the cursor yet',
  );
  check(
    [
      first,
      const HistoryRead(2, 'wrong', '100', 200, null, ['single']),
    ],
    false,
    'the request must use the first response cursor',
  );
  check(
    [
      first,
      const HistoryRead(2, 'page-b', '100', 200, null, ['foreign']),
    ],
    false,
    'the second page must carry the actual surviving fixture ID',
  );
  check(
    [
      first,
      const HistoryRead(2, 'page-b', '100', 503, null, ['single']),
    ],
    false,
    'a 503 must never prove pagination',
  );
  check(
    [
      first,
      const HistoryRead(2, 'page-b', '100', 200, 'extra', ['single']),
    ],
    false,
    'the second page must be terminal',
  );
  // ignore: avoid_print
  print('PASS(history.cursor-regression)');
}
