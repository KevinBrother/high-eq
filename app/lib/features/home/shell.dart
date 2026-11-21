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
  const HomeShell(this.section, {super.key});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 580),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(26, 24, 26, 32),
              children: [
                Row(
                  children: [
                    Icon(Icons.forum_outlined, size: 22, color: colors.primary),
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
                if (section == Section.practice ||
                    section == Section.growth ||
                    section == Section.me)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.radar),
                    title: const Text('本次自评与续答'),
                    onTap: () => Navigator.pushNamed(context, '/assessment'),
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
                    leading: const Icon(Icons.workspace_premium_outlined),
                    title: const Text('会员与今日额度'),
                    onTap: () => Navigator.pushNamed(context, '/membership'),
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
