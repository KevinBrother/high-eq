import 'package:flutter/material.dart';

enum Section {
  practice(
    '/practice',
    '练习',
    '把想说的话，先练一遍。',
    '练习空间',
    '选一关练表达，或先预演一场自己的对话。',
    Icons.chat_bubble_outline_rounded,
  ),
  live(
    '/live',
    '实战',
    '给真实对话，留一点余地。',
    '实战手记',
    '这里将收下你在对话中想记住的瞬间。',
    Icons.bookmark_border_rounded,
  ),
  growth(
    '/growth',
    '成长',
    '回头看，变化就有了形状。',
    '成长记录',
    '未来的练习与回顾，将在这里留下足迹。',
    Icons.spa_outlined,
  ),
  me(
    '/me',
    '我的',
    '按自己的节奏，慢慢来。',
    '个人空间',
    '账号、偏好与授权设置将在这里集中管理。',
    Icons.person_outline_rounded,
  );

  const Section(
    this.path,
    this.label,
    this.headline,
    this.title,
    this.hint,
    this.icon,
  );
  final String path, label, headline, title, hint;
  final IconData icon;
}

class HomeShell extends StatelessWidget {
  final Section section;

  /// Optional page body. When absent, the original four-tab placeholder is
  /// rendered so the shell remains usable while feature pages are rolled out.
  final Widget? content;

  const HomeShell(this.section, {super.key, this.content});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 580),
            child:
                content ??
                ListView(
                  padding: const EdgeInsets.fromLTRB(26, 24, 26, 32),
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.forum_outlined,
                          size: 22,
                          color: colors.primary,
                        ),
                        const SizedBox(width: 9),
                        Text('对话手记', style: theme.textTheme.titleSmall),
                        const Spacer(),
                        Text(
                          '0${section.index + 1} / 04',
                          style: theme.textTheme.labelMedium,
                        ),
                      ],
                    ),
                    const SizedBox(height: 46),
                    Semantics(
                      header: true,
                      child: Text(
                        section.label,
                        style: theme.textTheme.displayMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      section.headline,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 34),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.primaryContainer,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ExcludeSemantics(
                              child: Icon(
                                section.icon,
                                size: 48,
                                color: colors.onPrimaryContainer,
                              ),
                            ),
                            const SizedBox(height: 36),
                            Text(
                              section.title,
                              style: theme.textTheme.headlineSmall?.copyWith(
                                color: colors.onPrimaryContainer,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              section.hint,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                color: colors.onPrimaryContainer,
                                height: 1.55,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.tune),
                      title: const Text('切换练习场景'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.pushNamed(context, '/scene'),
                    ),
                    if (section == Section.live)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.bookmark_add_outlined),
                        title: const Text('我上头了'),
                        subtitle: const Text('记下此刻，稍后再想'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.pushNamed(
                          context,
                          '/marks',
                          arguments: true,
                        ),
                      ),
                    if (section == Section.live || section == Section.growth)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.history),
                        title: const Text('标记历史'),
                        onTap: () => Navigator.pushNamed(context, '/marks'),
                      ),
                    if (section == Section.live || section == Section.growth)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.menu_book_outlined),
                        title: const Text('复盘与踩坑本'),
                        subtitle: const Text('把一次摩擦，变成下一次的准备'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.pushNamed(context, '/reviews'),
                      ),
                    if (section == Section.practice ||
                        section == Section.growth ||
                        section == Section.me)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.radar),
                        title: const Text('本次自评与续答'),
                        onTap: () =>
                            Navigator.pushNamed(context, '/assessment'),
                      ),
                    if (section == Section.live)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.chat_outlined),
                        title: const Text('回复助手'),
                        subtitle: const Text('读懂对方，再组织自己的说法'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.pushNamed(context, '/replies'),
                      ),
                    if (section == Section.practice)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.forum_outlined),
                        title: const Text('对练与预演'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.pushNamed(context, '/training'),
                      ),
                    if (section == Section.me) ...[
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.graphic_eq),
                        title: const Text('语音特征与录音'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.pushNamed(context, '/voice'),
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.workspace_premium_outlined),
                        title: const Text('会员与今日额度'),
                        onTap: () =>
                            Navigator.pushNamed(context, '/membership'),
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.logout),
                        title: const Text('退出账号'),
                        onTap: () => Navigator.pushNamed(context, '/logout'),
                      ),
                    ],
                    if (section == Section.me)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.people_outline),
                        title: const Text('关系人手记'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.pushNamed(context, '/contacts'),
                      ),
                  ],
                ),
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: section.index,
        onDestinationSelected: (i) {
          if (i != section.index) {
            Navigator.pushReplacementNamed(context, Section.values[i].path);
          }
        },
        destinations: [
          for (final tab in Section.values)
            NavigationDestination(icon: Icon(tab.icon), label: tab.label),
        ],
      ),
    );
  }
}

/// A neutral frame while an account-scoped page is being replaced after a
/// logout or identity change. It deliberately contains no repository or data
/// captured from the previous account.
class SessionTransitionPane extends StatelessWidget {
  const SessionTransitionPane({required this.label, super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Semantics(
          liveRegion: true,
          label: label,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              const SizedBox(height: 18),
              Text(
                label,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
