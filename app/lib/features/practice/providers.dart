import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/transport.dart';
import '../contacts/routes.dart';
import 'demo.dart';
import 'repository.dart';

/// The demo practice repository is shared by the practice route and the demo
/// growth plan. Keeping it account-scoped lets a completed level appear in the
/// today plan when the user returns from chat.
final demoPracticeProvider = Provider<DemoPractice>((ref) {
  final api = ref.watch(apiProvider).requireValue;
  if (api.transport is! ExampleTransport) {
    throw StateError('演示练习仅在示例传输下可用');
  }
  final space = ref.watch(contactSpaceProvider);
  return DemoPractice(contacts: space.repo);
}, dependencies: [contactSpaceProvider]);

final practiceRepositoryProvider = Provider<PracticeRepository?>((ref) {
  final scope = ref.watch(accountScopeProvider);
  if (scope == null) return null;
  final api = ref.watch(apiProvider).requireValue;
  if (api.transport is ExampleTransport) {
    return ref.watch(demoPracticeProvider);
  }
  return ApiPractice(api, scope);
}, dependencies: [accountScopeProvider, demoPracticeProvider]);
