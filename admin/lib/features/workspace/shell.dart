import 'package:flutter/material.dart';
import '../operations/prompts.dart';
import '../operations/metrics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/api.dart';
import '../../core/session.dart';
import '../models/model_page.dart';
import '../audit/audit_page.dart';

class Workspace extends ConsumerStatefulWidget {
  const Workspace({super.key, required this.session, required this.path});
  final Session session;
  final String path;
  @override
  ConsumerState<Workspace> createState() => _Workspace();
}

class _Workspace extends ConsumerState<Workspace> {
  bool leaving = false;
  Future<void> logout() async {
    if (leaving) return;
    setState(() => leaving = true);
    try {
      await ref.read(apiProvider).logout(widget.session.token);
      if (mounted) ref.read(sessionProvider.notifier).clear();
    } catch (e) {
      if (!mounted) return;
      if (e is ApiFailure && e.status == 401) {
        ref.read(sessionProvider.notifier).clear();
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('退出未确认，请检查网络后重试')));
      }
    } finally {
      if (mounted) setState(() => leaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final audit = widget.path == '/audit', can = widget.session.canAudit;
    final narrow = MediaQuery.sizeOf(context).width < 700;
    final destinations = [
      ('/', '工作台', Icons.dashboard_outlined),
      ('/prompts', '模板管理', Icons.edit_note),
      ('/metrics', '监控看板', Icons.bar_chart),
      if (can) ('/audit', '审计记录', Icons.fact_check_outlined),
      if (can) ('/models', '模型与路由', Icons.alt_route),
    ];
    final index = destinations.indexWhere((d) => d.$1 == widget.path);
    void go(int index) {
      final dest = destinations[index].$1;
      if (dest != widget.path) Navigator.pushReplacementNamed(context, dest);
    }

    final content = switch (widget.path) {
      '/' => _Home(superAdmin: can),
      '/prompts' => PromptPage(
        key: ObjectKey(widget.session),
        session: widget.session,
      ),
      '/metrics' => MetricsPage(
        key: ObjectKey(widget.session),
        session: widget.session,
      ),
      '/models' when can => ModelPage(
        key: ObjectKey(widget.session),
        session: widget.session,
      ),
      '/audit' when can => AuditPage(
        key: ObjectKey(widget.session),
        session: widget.session,
      ),
      _ => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              audit
                  ? '当前角色无权查看审计'
                  : widget.path == '/models'
                  ? '当前角色无权管理模型'
                  : '未找到页面',
            ),
            TextButton(onPressed: () => go(0), child: const Text('返回工作台')),
          ],
        ),
      ),
    };
    return Scaffold(
      appBar: AppBar(
        title: const Text('情商训练  /  运营后台'),
        actions: [
          if (!narrow) Text(can ? '超级管理员' : '运营人员'),
          IconButton(
            tooltip: '退出登录',
            onPressed: leaving ? null : logout,
            icon: const Icon(Icons.logout),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: SafeArea(
        child: Row(
          children: [
            if (!narrow)
              NavigationRail(
                extended: true,
                selectedIndex: index < 0 ? null : index,
                onDestinationSelected: go,
                destinations: [
                  for (final d in destinations)
                    NavigationRailDestination(
                      icon: Icon(d.$3),
                      label: Text(d.$2),
                    ),
                ],
              ),
            Expanded(child: content),
          ],
        ),
      ),
      bottomNavigationBar: narrow
          ? NavigationBar(
              selectedIndex: index < 0 ? 0 : index,
              onDestinationSelected: go,
              destinations: [
                for (final d in destinations)
                  NavigationDestination(icon: Icon(d.$3), label: d.$2),
              ],
            )
          : null,
    );
  }
}

class _Home extends StatelessWidget {
  const _Home({required this.superAdmin});
  final bool superAdmin;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(28),
    children: [
      Text('工作台', style: Theme.of(context).textTheme.headlineMedium),
      const SizedBox(height: 28),
      Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Card(
            child: ListTile(
              contentPadding: const EdgeInsets.all(20),
              leading: const Icon(Icons.verified_user_outlined),
              title: Text(superAdmin ? '超级管理员' : '运营人员'),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  superAdmin
                      ? '管理模板、监控调用，并核查模型配置与操作审计。'
                      : '在模板管理中配置版本，在监控看板中核对调用与评分。',
                ),
              ),
            ),
          ),
        ),
      ),
    ],
  );
}
