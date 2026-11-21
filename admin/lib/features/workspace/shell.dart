import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/api.dart';
import '../../core/session.dart';
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
    void go(int index) {
      final dest = index == 1 ? '/audit' : '/';
      if (dest != widget.path) Navigator.pushReplacementNamed(context, dest);
    }

    final content = switch (widget.path) {
      '/' => _Home(superAdmin: can),
      '/audit' when can => AuditPage(
        key: ObjectKey(widget.session),
        session: widget.session,
      ),
      _ => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(audit ? '当前角色无权查看审计' : '未找到页面'),
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
            if (can && !narrow)
              NavigationRail(
                extended: true,
                selectedIndex: audit ? 1 : 0,
                onDestinationSelected: go,
                destinations: const [
                  NavigationRailDestination(
                    icon: Icon(Icons.dashboard_outlined),
                    label: Text('工作台'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.fact_check_outlined),
                    label: Text('审计记录'),
                  ),
                ],
              ),
            Expanded(child: content),
          ],
        ),
      ),
      bottomNavigationBar: can && narrow
          ? NavigationBar(
              selectedIndex: audit ? 1 : 0,
              onDestinationSelected: go,
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.dashboard_outlined),
                  label: '工作台',
                ),
                NavigationDestination(
                  icon: Icon(Icons.fact_check_outlined),
                  label: '审计记录',
                ),
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
                  superAdmin ? '可查看后台写操作的审计记录。' : '已登录运营后台。当前尚无开放的运营工具。',
                ),
              ),
            ),
          ),
        ),
      ),
    ],
  );
}
