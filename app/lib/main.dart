import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/providers.dart';
import 'core/theme.dart';
import 'features/home/shell.dart';

void main() => runApp(const ProviderScope(child: HighEqApp()));

class HighEqApp extends ConsumerWidget {
  const HighEqApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ready = ref.watch(apiProvider);
    return MaterialApp(
      title: '对话手记',
      debugShowCheckedModeBanner: false,
      theme: appTheme(Brightness.light),
      darkTheme: appTheme(Brightness.dark),
      locale: const Locale('zh', 'CN'),
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: const [Locale('zh', 'CN')],
      builder: (context, child) => ready.when(
        data: (_) => child!,
        loading: () => const Scaffold(body: StatusPanel('正在准备个人空间…')),
        error: (_, _) => Scaffold(
          body: StatusPanel(
            '无法打开本机安全存储，请解锁设备后重试。',
            retry: () => ref.invalidate(apiProvider),
          ),
        ),
      ),
      onGenerateRoute: (settings) {
        final section =
            Section.values.where((s) => s.path == settings.name).firstOrNull ??
            Section.practice;
        return PageRouteBuilder<void>(
          settings: settings,
          pageBuilder: (_, _, _) => HomeShell(section),
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
        );
      },
    );
  }
}
