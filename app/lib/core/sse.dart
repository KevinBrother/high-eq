import 'dart:convert';
import 'transport.dart';

enum ReplyEventKind {
  fragment,
  replySaved,
  safety,
  moderationUnavailable,
  inProgress,
}

class ReplyEvent {
  final ReplyEventKind kind;
  final Json data;
  const ReplyEvent(this.kind, this.data);
}

/// SSE is line framed, not packet framed. EOF before a terminal frame means
/// history must be fetched (not exit, success, or an automatic second send).
Stream<ReplyEvent> decodeReply(
  Stream<List<int>> bytes,
  String messageId,
) async* {
  var name = '';
  var data = <String>[];
  await for (final line
      in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (data.isNotEmpty) {
        final payload = jsonDecode(data.join('\n')) as Json;
        final kind = switch (name) {
          'fragment' when payload['text'] is String => ReplyEventKind.fragment,
          'reply_saved'
              when payload['message_id'] is String &&
                  payload['settlement'] is Map =>
            ReplyEventKind.replySaved,
          'safety'
              when payload['safety'] == true && payload['message'] is String =>
            ReplyEventKind.safety,
          'moderation_unavailable'
              when payload['code'] == name &&
                  payload['retryable'] == true &&
                  payload['message'] is String =>
            ReplyEventKind.moderationUnavailable,
          'in_progress' => ReplyEventKind.inProgress,
          _ => throw const FormatException('回复格式异常'),
        };
        if ({
              ReplyEventKind.fragment,
              ReplyEventKind.replySaved,
              ReplyEventKind.inProgress,
            }.contains(kind) &&
            payload['client_message_id'] != messageId) {
          throw const FormatException('回复标识不匹配');
        }
        yield ReplyEvent(kind, payload);
        if (kind != ReplyEventKind.fragment) return;
      }
      name = '';
      data = [];
      continue;
    }
    final colon = line.indexOf(':');
    if (colon < 0) continue;
    var value = line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (line.substring(0, colon)) {
      case 'event':
        name = value;
      case 'data':
        data.add(value);
    }
  }
  throw const FormatException('连接已中断，请从会话历史恢复');
}
