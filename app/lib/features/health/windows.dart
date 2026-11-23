import 'dart:math';
import '../../core/transport.dart';

const slotMs = 30000;
int floorSlot(int ms) => ms ~/ slotMs * slotMs;
int ceilSlot(int ms) => floorSlot(ms + slotMs - 1);

class _Stat {
  double sum = 0, peak = 0, weight = 0;
  int count = 0;
  final seconds = <int>{};
  void add(double value, int from, int to, double w) {
    sum += value * w;
    weight += w;
    peak = max(peak, value);
    count++;
    for (var s = from ~/ 1000; s <= (to - 1) ~/ 1000; s++) {
      seconds.add(s);
    }
  }

  Json wire(bool discrete) => {
    'mean': min(peak, sum / weight),
    'maximum': peak,
    'sample_count': count,
    if (!discrete) 'valid_seconds': seconds.length,
  };
}

/// Native records: [kind, UTC ms, exclusive end ms (same for point), value].
/// Never interpolate a sparse heart sample across an unobserved interval.
List<Json> healthWindows(
  String source,
  int from,
  int to,
  List<List> rows, {
  int? collectionFrom,
}) {
  if (!{'apple_history', 'health_connect', 'huawei_history'}.contains(source) ||
      from != floorSlot(from) ||
      to != floorSlot(to) ||
      to - from > 600000) {
    throw const FormatException('无效的健康窗口');
  }
  final stepsCutoff = collectionFrom ?? from;
  final windows = <Json>[];
  for (var slot = from; slot < to; slot += slotMs) {
    final stats = <String, _Stat>{};
    var exercise = false;
    for (final row in rows) {
      final [String kind, int start, int end, num n] = row;
      if (!n.isFinite || n < 0 || end < start) continue;
      final point = kind == 'heart_rate' || kind == 'hrv';
      // A steps total carries one count for its whole interval. If any part of
      // it predates this collection interval, discard the whole summary rather
      // than assigning a proportional share to the authorized side. Exercise
      // is a state interval and may start earlier while still marking a later
      // overlapping window.
      if ((kind == 'steps' || kind == 'phone_steps') && start < stepsCutoff) {
        continue;
      }
      final a = max(start, slot),
          b = min(point ? start + 1 : end, slot + slotMs);
      if (a >= b) continue;
      if (kind == 'exercise') {
        exercise = true;
        continue;
      }
      if (!point && kind != 'steps' && kind != 'phone_steps') continue;
      final key = point
          ? kind
          : kind == 'phone_steps'
          ? 'phone'
          : 'cadence';
      (stats[key] ??= _Stat()).add(
        point ? n.toDouble() : n * 60000 / (end - start),
        a,
        b,
        point ? 1 : (b - a).toDouble(),
      );
    }
    final phone = stats.remove('phone');
    if (phone != null) stats['cadence'] = phone;
    if (stats.isNotEmpty) {
      windows.add({
        'channel': 'health',
        'starts_at': DateTime.fromMillisecondsSinceEpoch(
          slot,
          isUtc: true,
        ).toIso8601String(),
        'duration_seconds': 30,
        'source': source,
        'exercise': exercise,
        for (final e in stats.entries) e.key: e.value.wire(e.key == 'hrv'),
      });
    }
  }
  return windows;
}
