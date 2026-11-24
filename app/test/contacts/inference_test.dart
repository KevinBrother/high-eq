import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/contacts/inference.dart';

Json profile() => {
  'summary': '更倾向先听完再回应',
  'big_five': [
    {'label': '开放性高', 'confidence': 0.5},
  ],
  'conflict_style': {'label': '合作型', 'confidence': 0.6},
  'attachment': null,
};

void main() {
  test('严格 202 回执得到处理中，且 request_id 必须一致', () {
    final result = decodeProfileInferenceResult(202, {
      'request_id': 'request-1',
      'status': 'in_progress',
    }, 'request-1');
    expect(result, isA<ProfileInferenceProcessing>());

    for (final body in [
      {'request_id': 'other', 'status': 'in_progress'},
      {'request_id': 'request-1', 'status': 'done'},
      {'request_id': 'request-1', 'status': 'in_progress', 'extra': true},
    ]) {
      expect(
        decodeProfileInferenceResult(202, body, 'request-1'),
        isA<ProfileInferenceTerminal>(),
      );
    }
  });

  test('严格 safety 回执保留固定提示，畸形 safety 为终结', () {
    final safety = decodeProfileInferenceResult(200, {
      'safety': true,
      'message': profileInferenceSafetyMessage,
    }, 'request-1');
    expect(safety, isA<ProfileInferenceSafety>());

    for (final body in [
      {'safety': false, 'message': profileInferenceSafetyMessage},
      {'safety': true, 'message': ''},
      {'safety': true, 'message': '合同外文本'},
      {'safety': true, 'message': profileInferenceSafetyMessage, 'extra': true},
    ]) {
      expect(
        decodeProfileInferenceResult(200, body, 'request-1'),
        isA<ProfileInferenceTerminal>(),
      );
    }
  });

  test('只有完整 Profile 才视为完成', () {
    final result = decodeProfileInferenceResult(200, profile(), 'request-1');
    expect(result, isA<ProfileInferenceCompleted>());
    expect((result as ProfileInferenceCompleted).profile, profile());

    for (final body in <Json>[
      {...profile(), 'extra': true},
      {...profile(), 'big_five': 'bad'},
      {
        ...profile(),
        'conflict_style': {'label': '', 'confidence': 0.3},
      },
      {
        ...profile(),
        'attachment': {'label': '安全型依恋', 'confidence': 2},
      },
    ]) {
      expect(
        decodeProfileInferenceResult(200, body, 'request-1'),
        isA<ProfileInferenceTerminal>(),
      );
    }
  });

  test('非 200/202 结果是终结，不伪装为完成', () {
    final result = decodeProfileInferenceResult(201, profile(), 'request-1');
    expect(result, isA<ProfileInferenceTerminal>());
    expect((result as ProfileInferenceTerminal).status, 201);
  });
}
