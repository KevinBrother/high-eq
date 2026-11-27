import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/features/growth/models.dart';
import 'package:high_eq/features/growth/practice_home.dart';
import 'package:high_eq/features/growth/repository.dart';
import 'package:high_eq/features/practice/providers.dart';

import 'support/fakes.dart';

// Handoff fixture: synthetic transport only, not the real service. The first
// card is in today's plan; the third card is deliberately outside it.
const _firstCard = KnowledgeCardData(
  id: testCardId,
  title: '事实和评价要分开',
  body: '“你总是迟到”是评价；“这周有两次会议你晚到了十分钟”是事实。',
  scene: 'work',
);

const _secondCard = KnowledgeCardData(
  id: 'card-secondary',
  title: '先确认，再给建议',
  body: '先问对方需要倾听还是一起想办法，再决定要不要给建议。',
  scene: 'partner',
);

const _thirdCard = KnowledgeCardData(
  id: 'card-outside-plan',
  title: '拒绝也可以留余地',
  body: '先说明这次做不到，再给出你愿意承担的部分和下一次可以的时间。',
  scene: 'family',
);

void main() {
  testWidgets('知识卡区前两张可打开阅读且不触发完成请求', (tester) async {
    final repository = _CardByIdRepository(
      snapshot: sampleSnapshot(
        cards: const [_firstCard, _secondCard, _thirdCard],
      ),
    );
    await _pumpPracticeRoute(tester, repository);

    for (final card in const [_firstCard, _secondCard]) {
      await _scrollTo(tester, find.text(card.title));
      await tester.tap(find.text(card.title));
      await tester.pumpAndSettle();

      expect(find.text(card.body), findsOneWidget);
      expect(find.text('读完了，记为完成'), findsNothing);

      await _closeCardSheet(tester);
    }

    expect(repository.cardCalls, 2);
    expect(repository.completeCalls, 0);
  });

  testWidgets('知识卡区展开后可选读第三张，关闭后保持展开且可收起', (tester) async {
    final repository = _CardByIdRepository(
      snapshot: sampleSnapshot(
        cards: const [_firstCard, _secondCard, _thirdCard],
      ),
    );
    await _pumpPracticeRoute(tester, repository);

    expect(
      repository.snapshot.plan.items
          .where((item) => item.contentId == _thirdCard.id),
      isEmpty,
      reason: '第三张卡不应是今日计划项',
    );

    await _scrollTo(tester, find.text('查看全部'));
    expect(find.text(_thirdCard.title), findsNothing);
    expect(find.text('查看全部'), findsOneWidget);
    expect(find.text('收起'), findsNothing);

    await tester.tap(find.text('查看全部'));
    await tester.pumpAndSettle();
    expect(find.text('查看全部'), findsNothing);
    expect(find.text('收起'), findsOneWidget);
    for (final card in const [_firstCard, _secondCard, _thirdCard]) {
      expect(find.text(card.title), findsOneWidget);
    }

    await _scrollTo(tester, find.text(_thirdCard.title));
    final browseOffset = _scrollPosition(tester);
    await tester.tap(find.text(_thirdCard.title));
    await tester.pumpAndSettle();

    expect(find.text(_thirdCard.body), findsOneWidget);
    expect(find.text('读完了，记为完成'), findsNothing);

    await _closeCardSheet(tester);
    expect(find.text(_thirdCard.title), findsOneWidget);
    expect(find.text('收起'), findsOneWidget);
    expect(_scrollPosition(tester), closeTo(browseOffset, 0.1));

    await _scrollTo(tester, find.text('收起'));
    await tester.tap(find.text('收起'));
    await tester.pumpAndSettle();
    expect(find.text(_thirdCard.title), findsNothing);
    expect(find.text('查看全部'), findsOneWidget);

    expect(repository.cardCalls, 1);
    expect(repository.completeCalls, 0);
  });

  testWidgets('0、1、2 张知识卡不出现查看全部或收起', (tester) async {
    for (final count in [0, 1, 2]) {
      final cards = const [_firstCard, _secondCard].take(count).toList();
      final repository = _CardByIdRepository(
        snapshot: sampleSnapshot(cards: cards),
      );
      await _pumpPracticeRoute(tester, repository);

      await _scrollTo(
        tester,
        count == 0
            ? find.text('今天暂无知识卡')
            : find.text('一张卡只练一个沟通动作，读完就能用。'),
      );
      expect(find.text('查看全部'), findsNothing, reason: '$count 张时不应有多余操作');
      expect(find.text('收起'), findsNothing, reason: '$count 张时不应有多余操作');

      if (count == 0) {
        expect(find.text('今天暂无知识卡'), findsOneWidget);
      } else {
        for (final card in cards) {
          expect(find.text(card.title), findsOneWidget);
        }
      }
    }
  });

  testWidgets('知识卡区展开后成长档案仍可从首页直达', (tester) async {
    final repository = _CardByIdRepository(
      snapshot: sampleSnapshot(
        cards: const [_firstCard, _secondCard, _thirdCard],
      ),
    );
    await _pumpPracticeRoute(tester, repository);

    await _scrollTo(tester, find.text('查看全部'));
    await tester.tap(find.text('查看全部'));
    await tester.pumpAndSettle();
    await _scrollTo(tester, find.text('成长档案'));
    await tester.tap(find.text('成长档案'));
    await tester.pumpAndSettle();

    expect(find.text('成长档案占位'), findsOneWidget);
  });
}

class _CardByIdRepository extends FakeGrowthRepository {
  _CardByIdRepository({required super.snapshot});

  static const _cards = <String, KnowledgeCardData>{
    testCardId: _firstCard,
    'card-secondary': _secondCard,
    'card-outside-plan': _thirdCard,
  };

  @override
  Future<KnowledgeCardData> card(String id) async {
    cardCalls++;
    final card = _cards[id];
    if (card == null) throw StateError('unexpected card: $id');
    return card;
  }
}

Future<void> _pumpPracticeRoute(
  WidgetTester tester,
  GrowthRepository repository,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        growthRepositoryProvider.overrideWithValue(repository),
        practiceRepositoryProvider.overrideWithValue(null),
      ],
      child: MaterialApp(
        home: const PracticeHomeRoute(),
        routes: {
          '/growth': (_) =>
              Scaffold(appBar: AppBar(), body: const Text('成长档案占位')),
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _closeCardSheet(WidgetTester tester) async {
  expect(find.byType(CardSheet), findsOneWidget);
  // Tap the scrim above the 86%-height sheet, the same dismissal a user has.
  await tester.tapAt(const Offset(5, 5));
  await tester.pumpAndSettle();
  expect(find.byType(CardSheet), findsNothing);
}

double _scrollPosition(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable).first).position.pixels;

Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    320,
    scrollable: find.byType(Scrollable).first,
    maxScrolls: 30,
  );
  expect(target, findsOneWidget);
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}
