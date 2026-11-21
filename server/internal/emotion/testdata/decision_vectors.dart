import 'dart:convert';
import 'dart:io';

/// T32B tests pass their real classifier; no Flutter binding, device, network
/// or duplicate classifier is required. `jsonText` may also come from an asset.
void verifyDecisions(
  String jsonText,
  String Function(Map<String, dynamic> frame) classify,
) {
  for (final row
      in (jsonDecode(jsonText) as List).cast<Map<String, dynamic>>()) {
    final actual = classify(row['input'] as Map<String, dynamic>);
    if (actual != row['want']) {
      throw StateError('${row['name']}: expected ${row['want']}, got $actual');
    }
  }
}

// Standalone wire-format smoke check, NOT a claim of a Dart implementation.
void main() {
  final dir = File.fromUri(Platform.script).parent;
  final decisions =
      jsonDecode(File('${dir.path}/decisions.json').readAsStringSync()) as List;
  for (final row in decisions) {
    final frame = row['input'] as Map<String, dynamic>;
    DateTime.parse(frame['starts_at'] as String);
    if (frame['means'] is! Map ||
        frame['thresholds'] is! Map ||
        !{
          'self_fluctuation',
          'conversation_rhythm',
          'none',
        }.contains(row['want'])) {
      throw FormatException('Invalid decision vector: ${row['name']}');
    }
  }
  final progress =
      jsonDecode(File('${dir.path}/progress.json').readAsStringSync()) as List;
  for (final row in progress) {
    DateTime.parse(row['now'] as String);
    if (row['windows'] is! List ||
        row['want']['hrv']['ready_for_alert'] != false) {
      throw FormatException('Invalid progress vector: ${row['name']}');
    }
  }
  print(
    'Decoded ${decisions.length} decisions and ${progress.length} progress vectors.',
  );
}
