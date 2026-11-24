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
