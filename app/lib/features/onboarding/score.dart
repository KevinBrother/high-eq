import '../../core/transport.dart';

const abilities = {'SEA': '自我觉察', 'OEA': '读懂别人', 'UOE': '自我激励', 'ROE': '自我管理'};
const descriptions = [
  '你觉得自己在这方面常遇到困难，可以从这里开始练。',
  '你觉得自己有时能做到，但还不太稳定。',
  '你认为自己在多数日常场景中能应对。',
  '你认为自己在压力下也能基本稳住。',
  '你对自己在这方面的表现比较有信心。',
];
int scoreLevel(double p) {
  if (!p.isFinite || p < 0 || p > 100) throw const FormatException();
  return p < 40
      ? 1
      : p < 60
      ? 2
      : p < 75
      ? 3
      : p < 90
      ? 4
      : 5;
}

Json demoScore(List<int> answers, DateTime now) {
  if (answers.length != 16 || answers.any((v) => v < 1 || v > 7)) {
    throw const FormatException();
  }
  Json score(List<int> a) {
    final mean = a.reduce((a, b) => a + b) / a.length;
    final p = (mean - 1) / 6 * 100;
    return {
      'mean': mean,
      'percent': p,
      'level': 'L${scoreLevel(p)}',
      'display': p.round(),
    };
  }

  final dims = abilities.keys.toList();
  return {
    'completed_at': now.toUtc().toIso8601String(),
    'next_eligible_at': now
        .toUtc()
        .add(const Duration(days: 28))
        .toIso8601String(),
    'dimensions': {
      for (var i = 0; i < 4; i++)
        dims[i]: score(answers.sublist(i * 4, i * 4 + 4)),
    },
    'total': score(answers),
  };
}
