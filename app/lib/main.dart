import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/api.dart';
import 'core/providers.dart';
import 'core/session.dart';
import 'core/theme.dart';
import 'features/home/shell.dart';
import 'features/replies/share_host.dart';
import 'features/replies/route.dart';
import 'features/practice/lobby.dart';
import 'features/contacts/routes.dart';
import 'features/onboarding/login.dart';
import 'features/onboarding/assessment.dart';
import 'features/onboarding/repository.dart';
import 'features/membership/page.dart';
import 'features/membership/store.dart';

void main() => runApp(const ProviderScope(child: HighEqApp()));

class HighEqApp extends ConsumerStatefulWidget {
  const HighEqApp({super.key});
  @override
  ConsumerState<HighEqApp> createState() => _HighEqAppState();
}

class _HighEqAppState extends ConsumerState<HighEqApp> {
  AccountScope? _navigatorScope;
  Type? _navigatorStatus;
  GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  void _selectNavigator(AccountScope? scope, Widget? status) {
    final statusType = status?.runtimeType;
    if (!identical(scope, _navigatorScope) || statusType != _navigatorStatus) {
      _navigatorScope = scope;
      _navigatorStatus = statusType;
      _navigatorKey = GlobalKey<NavigatorState>();
    }
  }

  @override
  Widget build(BuildContext context) => ref
      .watch(apiProvider)
      .when(
        data: (api) => ShareHost(
          api.sessions,
          (scope, draft, rev, close) => _app(
            api: api,
            scope: scope,
            draft: draft,
            revision: rev,
            close: close,
          ),
          onWarmShare: (scope, draft, discard) =>
              _openWarmShare(api, scope, draft, discard),
          key: ObjectKey(api),
        ),
        loading: () => _app(status: const StatusPanel('正在准备个人空间…')),
        error: (_, _) => _app(
          status: StatusPanel(
            '无法打开本机安全存储，请解锁设备后重试。',
            retry: () => ref.invalidate(apiProvider),
          ),
        ),
      );

  bool _openWarmShare(
    AppApi api,
    AccountScope scope,
    String draft,
    VoidCallback discard,
  ) {
    final navigator = _navigatorKey.currentState;
    if (navigator == null) return false;
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => ReplyRoute(
          api,
          scope,
          draft: draft,
          close: () {
            if (navigator.canPop()) navigator.pop();
            discard();
          },
        ),
      ),
    );
    return true;
  }

  MaterialApp _app({
    AppApi? api,
    AccountScope? scope,
    Widget? status,
    String? draft,
    int revision = 0,
    VoidCallback? close,
  }) {
    _selectNavigator(scope, status);
    return MaterialApp(
      navigatorKey: _navigatorKey,
      key: ValueKey((scope, status?.runtimeType, scope == null ? revision : 0)),
      title: '对话手记',
      debugShowCheckedModeBanner: false,
      theme: appTheme(Brightness.light),
      darkTheme: appTheme(Brightness.dark),
      locale: const Locale('zh', 'CN'),
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: const [Locale('zh', 'CN')],
      initialRoute: '/',
      builder: (_, child) => scope == null
          ? ShareLoginNotice(
              pending: draft != null,
              discard: close,
              child: child!,
            )
          : child!,
      onGenerateRoute: (settings) {
        Widget screen(BuildContext context) {
          if (status != null) return Scaffold(body: status);
          if (scope == null) return LoginPage(api!);
          switch (settings.name) {
            case '/replies':
              return ReplyRoute(api!, scope);
            case '/':
            case '/assessment':
              if (settings.name == '/' && draft != null) {
                return ReplyRoute(
                  api!,
                  scope,
                  draft: draft,
                  close: () {
                    close?.call();
                    Navigator.of(context).pushReplacementNamed('/assessment');
                  },
                );
              }
              return AssessmentPage(
                AssessmentBook(api!, scope),
                startup: settings.name == '/',
              );
            case '/training':
              return const PracticeRoute();
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
}
