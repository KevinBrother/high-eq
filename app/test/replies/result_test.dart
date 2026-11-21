import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/features/replies/result.dart';

void main() {
  const id = '85b72033-9f07-4bbc-8567-fc31f26508ab';
  const first = {'style': '直接', 'text': '合成建议', 'reason': '说明理由'};
  final normal = {
    'id': id,
    'possible_feeling': '可能着急',
    'possible_need': '确认时间',
    'suggestions': [
      first,
      {...first, 'style': '先确认'},
    ],
  };
  test('only a complete final HTTP 200 may become cards', () {
    expect(decodeReplyResult(200, normal, id), isA<Approved>());
    for (final bad in [
      {...normal, 'safety': true},
      {...normal, 'possible_need': '  '},
      {
        ...normal,
        'suggestions': [first],
      },
      {
        ...normal,
        'suggestions': [first, first],
      },
      {
        ...normal,
        'suggestions': [
          first,
          {'style': '确认', 'text': '部分输出'},
        ],
      },
    ]) {
      expect(decodeReplyResult(200, bad, id), isA<NoResult>());
    }
    expect(decodeReplyResult(202, normal, id), isA<NoResult>());
    expect(
      decodeReplyResult(202, {'status': 'in_progress', 'request_id': id}, id),
      isA<Processing>(),
    );
    expect(
      decodeReplyResult(202, {
        'status': 'in_progress',
        'request_id': 'other',
      }, id),
      isA<NoResult>(),
    );
    expect(
      decodeReplyResult(200, {'safety': true, 'message': '合成提示'}, id),
      isA<Crisis>(),
    );
  });
}
