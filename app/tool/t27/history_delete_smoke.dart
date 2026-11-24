import 'dart:convert';

import 'history_trace.dart';

void main() {
  const path = '/v1/contacts/synthetic-contact';
  const privateBody = 'synthetic-private-body';

  for (final (description, body) in [
    ('invalid JSON', utf8.encode(privateBody)),
    ('non-object JSON', utf8.encode('["$privateBody"]')),
    ('invalid UTF-8', [0xff, ...utf8.encode(privateBody)]),
  ]) {
    final lines = <String>[];
    final trace = HistoryDeleteTrace(path, lines.add);
    Object? failure;
    try {
      trace.record(method: 'DELETE', path: path, status: 200, body: body);
    } catch (error) {
      failure = error;
    }

    if (lines.length != 1 ||
        lines.single != 'OBSERVED(page.delete-http): unacknowledged') {
      throw StateError('$description must emit one unacknowledged receipt');
    }
    if (trace.deletions.length != 1 ||
        trace.deletions.single != (path: path, status: 200, ok: false)) {
      throw StateError('$description must record the observed 200');
    }
    if (failure is! FormatException ||
        failure.source != null ||
        failure.toString().contains(path) ||
        failure.toString().contains(privateBody)) {
      throw StateError('$description must fail without exposing request data');
    }
  }

  // ignore: avoid_print
  print('PASS(history.delete-regression)');
}
