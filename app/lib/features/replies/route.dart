import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/api.dart';
import '../../core/session.dart';
import '../contacts/routes.dart';
import 'page.dart';
import 'repository.dart';

class ReplyRoute extends ConsumerWidget {
  const ReplyRoute(this.api, this.scope, {super.key, this.draft, this.close});
  final AppApi api;
  final AccountScope scope;
  final String? draft;
  final VoidCallback? close;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final space = ref.watch(contactSpaceProvider);
    final repo = ReplyService(api, scope, book: space.repo);
    return ReplyPage(repo, demo: space.demo, sharedText: draft, close: close);
  }
}
