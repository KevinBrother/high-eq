import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/session.dart';
import 'features/auth/login.dart';
import 'features/workspace/shell.dart';

void main() => runApp(const ProviderScope(child: AdminApp()));

class AdminApp extends StatelessWidget {
  const AdminApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '情商训练 · 运营后台',
    debugShowCheckedModeBanner: false,
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff17665c)),
      scaffoldBackgroundColor: const Color(0xfff6f8f6),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        filled: true,
        fillColor: Colors.white,
      ),
    ),
    onGenerateRoute: (settings) => MaterialPageRoute<void>(
      settings: settings,
      builder: (_) => Consumer(
        builder: (context, ref, _) {
          final s = ref.watch(sessionProvider);
          if (s == null) return const LoginPage();
          return Workspace(session: s, path: settings.name ?? '/');
        },
      ),
    ),
  );
}
