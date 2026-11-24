import 'dart:convert';

class HistoryDeleteTrace {
  HistoryDeleteTrace(this._targetPath, this._log);

  final String _targetPath;
  final void Function(String) _log;
  final _deletions = <({String path, int status, bool ok})>[];

  List<({String path, int status, bool ok})> get deletions =>
      List.unmodifiable(_deletions);

  void record({
    required String method,
    required String path,
    required int status,
    required List<int> body,
  }) {
    var ok = false;
    try {
      if (status == 200) {
        final json = jsonDecode(utf8.decode(body));
        if (json is! Map<String, dynamic>) {
          throw const FormatException('Expected JSON object');
        }
        ok = json['ok'] == true;
      }
    } on FormatException {
      // Decoder errors can contain the source text.
      throw const FormatException('Invalid DELETE acknowledgement JSON object');
    } finally {
      _deletions.add((path: path, status: status, ok: ok));
      if (method == 'DELETE' && path == _targetPath) {
        _log(switch (status) {
          200 when ok =>
            'OBSERVED(page.delete-ack): DELETE returned 200 with ok=true',
          403 => 'OBSERVED(page.delete-http): 403',
          500 => 'OBSERVED(page.delete-http): 500',
          503 => 'OBSERVED(page.delete-http): 503',
          _ => 'OBSERVED(page.delete-http): unacknowledged',
        });
      }
    }
  }
}

class HistoryRead {
  const HistoryRead(
    this.requestOrder,
    this.cursor,
    this.limit,
    this.status,
    this.nextCursor,
    this.ids, {
    int? responseOrder,
  }) : responseOrder = responseOrder ?? requestOrder;

  final int requestOrder, responseOrder;
  final String? cursor, limit, nextCursor;
  final int status;
  final List<String> ids;
}

// Entries are appended when a response has arrived, with request order assigned
// at dispatch. A cursor request must have started after the first response.
bool hasHistoryChain(
  List<HistoryRead> reads, {
  required int firstCount,
  required Set<String> firstIds,
  required String lastId,
}) {
  final cursors = <String, int>{};
  for (final read in reads) {
    if (read.status != 200 || read.limit != '100') continue;
    final next = read.nextCursor;
    if (read.cursor == null &&
        next != null &&
        next.isNotEmpty &&
        read.ids.length == firstCount &&
        read.ids.toSet().length == firstCount &&
        firstIds.every(read.ids.contains) &&
        !read.ids.contains(lastId)) {
      final discovered = read.responseOrder;
      final previous = cursors[next];
      if (previous == null || discovered < previous) cursors[next] = discovered;
    }
    final discovered = cursors[read.cursor];
    if (discovered != null &&
        discovered < read.requestOrder &&
        next == null &&
        read.ids.length == 1 &&
        read.ids.single == lastId) {
      return true;
    }
  }
  return false;
}
