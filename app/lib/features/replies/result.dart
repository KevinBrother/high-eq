import '../../core/transport.dart';

sealed class ReplyResult {}

class Processing extends ReplyResult {}

class NoResult extends ReplyResult {
  NoResult({this.terminal = false});
  final bool terminal;
}

class Crisis extends ReplyResult {}

typedef Suggestion = ({String style, String text, String reason});

class Approved extends ReplyResult {
  Approved(this.id, this.feeling, this.need, this.suggestions);
  final String id, feeling, need;
  final List<Suggestion> suggestions;
}

final _uuid = RegExp(r'^[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$');
bool _exact(Map value, List<String> keys) =>
    value.length == keys.length && keys.every(value.containsKey);
bool _text(Object? v) => v is String && v.trim().isNotEmpty;
// The server owns moderation. Never salvage individual fields from an envelope.
ReplyResult decodeReplyResult(int status, Json value, String requestId) {
  if (status == 202 &&
      _exact(value, ['request_id', 'status']) &&
      value['request_id'] == requestId &&
      value['status'] == 'in_progress') {
    return Processing();
  }
  if (status != 200) return NoResult();
  if (_exact(value, ['safety', 'message']) &&
      value['safety'] == true &&
      _text(value['message'])) {
    return Crisis();
  }
  if (!_exact(value, [
        'id',
        'possible_feeling',
        'possible_need',
        'suggestions',
      ]) ||
      value['id'] is! String ||
      !_uuid.hasMatch(value['id']) ||
      !_text(value['possible_feeling']) ||
      !_text(value['possible_need'])) {
    return NoResult();
  }
  final items = value['suggestions'];
  if (items is! List || items.length < 2 || items.length > 3) return NoResult();
  final suggestions = <Suggestion>[], styles = <String>{};
  for (final item in items) {
    if (item is! Json ||
        !_exact(item, ['style', 'text', 'reason']) ||
        !item.values.every(_text) ||
        !styles.add((item['style'] as String).trim().toLowerCase())) {
      return NoResult();
    }
    suggestions.add((
      style: item['style'],
      text: item['text'],
      reason: item['reason'],
    ));
  }
  return Approved(
    value['id'],
    value['possible_feeling'],
    value['possible_need'],
    List.unmodifiable(suggestions),
  );
}
