import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/api.dart';
import 'core/providers.dart';
import 'core/session.dart';
import 'core/theme.dart';
import 'features/home/shell.dart';
import 'features/contacts/routes.dart';
import 'features/onboarding/login.dart';
import 'features/onboarding/assessment.dart';
import 'features/onboarding/repository.dart';
import 'features/membership/page.dart';
import 'features/membership/store.dart';

void main() => runApp(const ProviderScope(child: HighEqApp()));

class HighEqApp extends ConsumerWidget {
  const HighEqApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(apiProvider)
      .when(
        data: (api) => ValueListenableBuilder<AccountScope?>(
          valueListenable: api.sessions.identity,
          builder: (_, scope, _) => _app(api: api, scope: scope),
        ),
        loading: () => _app(status: const StatusPanel('正在准备个人空间…')),
        error: (_, _) => _app(
          status: StatusPanel(
            '无法打开本机安全存储，请解锁设备后重试。',
            retry: () => ref.invalidate(apiProvider),
          ),
        ),
      );
  MaterialApp _app({AppApi? api, AccountScope? scope, Widget? status}) =>
      MaterialApp(
        key: ObjectKey(scope ?? status?.runtimeType),
        title: '对话手记',
        debugShowCheckedModeBanner: false,
        theme: appTheme(Brightness.light),
        darkTheme: appTheme(Brightness.dark),
        locale: const Locale('zh', 'CN'),
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: const [Locale('zh', 'CN')],
        initialRoute: '/',
        onGenerateRoute: (settings) {
          Widget screen(BuildContext context) {
            if (status != null) return Scaffold(body: status);
            if (scope == null) return LoginPage(api!);
            switch (settings.name) {
              case '/':
              case '/assessment':
                return AssessmentPage(
                  AssessmentBook(api!, scope),
                  startup: settings.name == '/',
                );
              case '/membership':
                return MemberPage(MemberStore(api!, scope));
              case '/logout':
                return Scaffold(
                  body: Center(
                    child: AlertDialog(
                      title: const Text('退出当前账号？'),
                      content: const Text('本机续答和草稿会被清除。'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('取消'),
                        ),
                        FilledButton(
                          onPressed: () async {
                            try {
                              await api!.logout(scope);
                            } catch (_) {
                              /* local session already invalidated */
                            }
                          },
                          child: const Text('确认退出'),
                        ),
                      ],
                    ),
                  ),
                );
              case '/contacts':
              case '/scene':
                return ContactRoute(sceneOnly: settings.name == '/scene');
              default:
                return HomeShell(
                  Section.values
                          .where((s) => s.path == settings.name)
                          .firstOrNull ??
                      Section.practice,
                );
            }
          }

          return MaterialPageRoute<void>(settings: settings, builder: screen);
        },
      );
}
