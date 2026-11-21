import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/api.dart';

class FlowSurface extends StatelessWidget {
  const FlowSurface(
    this.kicker,
    this.title,
    this.children, {
    super.key,
    this.busy = false,
    this.message,
  });
  final String kicker, title;
  final List<Widget> children;
  final bool busy;
  final String? message;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: LayoutBuilder(
              builder: (context, bounds) => Column(
                children: [
                  if (message case final text?)
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: bounds.maxHeight * .28,
                      ),
                      child: Material(
                        color: theme.colorScheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(12),
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          child: Semantics(
                            liveRegion: true,
                            child: Text(
                              text,
                              style: TextStyle(
                                color: theme.colorScheme.onSecondaryContainer,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  SizedBox(
                    height: 3,
                    child: busy ? const LinearProgressIndicator() : null,
                  ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
                      children: [
                        Text(
                          kicker,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Semantics(
                          header: true,
                          child: Text(
                            title,
                            style: theme.textTheme.headlineMedium,
                          ),
                        ),
                        const SizedBox(height: 20),
                        IgnorePointer(
                          ignoring: busy,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: children,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String friendlyError(Object e) {
  if (e is ApiFailure) {
    return switch (e.status) {
      401 => '登录凭证无效或已过期，请重新验证。',
      403 => '没有获得所需授权，请重新确认。',
      409 => '账号或记录有冲突，请核对后再试。',
      429 => '操作过于频繁，请稍后再试。',
      _ => '服务暂不可用，请重试。',
    };
  }
  if (e is PlatformException && e.code == 'pending') {
    return '购买正在等待批准。请不要重复购买，批准后可在此恢复购买。';
  }
  if (e is PlatformException && e.code == 'cancelled') return '已取消，未更改账号或权益。';
  if (e is MissingPluginException ||
      e is PlatformException && e.code == 'unavailable') {
    return '当前构建未配置该渠道，请使用其他方式或稍后重试。';
  }
  return '暂时无法完成，请检查连接后重试。';
}
