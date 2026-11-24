import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/api.dart';
import 'core/providers.dart';
import 'core/session.dart';
import 'core/theme.dart';
import 'features/growth/growth_page.dart';
import 'features/growth/practice_home.dart';
import 'features/home/shell.dart';
import 'features/replies/share_host.dart';
import 'features/replies/route.dart';
import 'features/marks/page.dart';
import 'features/reviews/page.dart';
import 'features/health/binding.dart';
import 'features/health/page.dart';
import 'features/practice/lobby.dart';
import 'features/contacts/routes.dart';
import 'features/onboarding/login.dart';
import 'features/onboarding/account_entry.dart';
import 'features/privacy/account_access.dart';
import 'features/privacy/page.dart';
import 'features/privacy/store.dart';
import 'features/onboarding/assessment.dart';
import 'features/onboarding/repository.dart';
import 'features/membership/page.dart';
import 'features/membership/store.dart';
import 'features/voice/page.dart';
import 'features/voice/retention_janitor.dart';

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
  LogoutResult? _logoutResult;
  ClosureSubmission? _closureSubmission;
  AccountScope? _unconfirmedClosureScope;

  void _selectNavigator(AccountScope? scope, Widget? status) {
    final statusType = status?.runtimeType;
    if (!identical(scope, _navigatorScope) || statusType != _navigatorStatus) {
      if (scope != null) {
        _logoutResult = null;
        _closureSubmission = null;
        _unconfirmedClosureScope = null;
      }
      _navigatorScope = scope;
      _navigatorStatus = statusType;
      _navigatorKey = GlobalKey<NavigatorState>();
    }
  }

  Future<void> _logout(AppApi api, AccountScope scope) async {
    try {
      final result = await api.logoutWithResult(
        scope,
        allowHealthWithdrawal: AccountAccess.of(api, scope).isOrdinary,
      );
      if (!mounted || !api.sessions.isCurrentLogout(result.round)) return;
      setState(() => _logoutResult = result);
    } on Object {
      // A logout that never started has no round that can be shown safely.
    }
  }

  @override
  Widget build(BuildContext context) => ref
      .watch(apiProvider)
      .when(
        data: (api) => VoiceRetentionJanitorHost(
          key: ObjectKey(api),
          sessions: api.sessions,
          child: ShareHost(
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
    final store = PrivacyStore(api, scope);
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => _accountEntry(
          store,
          onActive: (_) => ReplyRoute(
            api,
            scope,
            draft: draft,
            close: () {
              if (navigator.canPop()) navigator.pop();
              discard();
            },
          ),
          onRecovered: () {
            discard();
            navigator.pushNamedAndRemoveUntil('/assessment', (_) => false);
          },
        ),
      ),
    );
    return true;
  }

  void _closureSubmitted(PrivacyStore store, ClosureSubmission submission) {
    if (!mounted || !store.api.sessions.isCurrentLogout(submission.round)) {
      return;
    }
    setState(() => _closureSubmission = submission);
  }

  void _setClosureUnconfirmed(PrivacyStore store, bool unconfirmed) {
    if (!mounted) return;
    final scope = store.scope;
    final sessions = store.api.sessions;
    if (unconfirmed) {
      if (!identical(sessions.active, scope) &&
          !sessions.isCurrentUnauthorizedRetirement(scope)) {
        return;
      }
    } else if (!identical(_unconfirmedClosureScope, scope)) {
      return;
    }
    setState(() => _unconfirmedClosureScope = unconfirmed ? scope : null);
  }

  AccountEntryPage _accountEntry(
    PrivacyStore store, {
    required WidgetBuilder onActive,
    required VoidCallback onRecovered,
  }) => AccountEntryPage(
    store,
    onActive: onActive,
    onClosureSubmitted: (submission) => _closureSubmitted(store, submission),
    onClosureUnconfirmed: (value) => _setClosureUnconfirmed(store, value),
    onClosureCancelled: onRecovered,
    onExit: () => _logout(store.api, store.scope),
  );

  String? _closureNotice(BuildContext context, Sessions? sessions) {
    if (sessions == null) return null;
    final unconfirmed = _unconfirmedClosureScope;
    if (unconfirmed != null &&
        sessions.isCurrentUnauthorizedRetirement(unconfirmed)) {
      return '未收到注销确认。请重新登录核对账号状态。';
    }
    final submission = _closureSubmission;
    if (submission == null || !sessions.isCurrentLogout(submission.round)) {
      return null;
    }
    final local = submission.deadline.toLocal();
    final locale = MaterialLocalizations.of(context);
    final date = locale.formatMediumDate(local);
    final time = locale.formatTimeOfDay(TimeOfDay.fromDateTime(local));
    final cleanup = submission.localCleanupConfirmed
        ? ''
        : ' 本机清理待确认，下次登录前会重试。';
    return '注销申请已提交。请在 $date $time 前重新登录并主动撤销，以恢复账号。$cleanup';
  }

  Widget _app({
    AppApi? api,
    AccountScope? scope,
    Widget? status,
    String? draft,
    int revision = 0,
    VoidCallback? close,
  }) {
    _selectNavigator(scope, status);
    final app = MaterialApp(
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
      builder: (context, child) => scope == null
          ? ShareLoginNotice(
              pending: draft != null,
              discard: close,
              result: _logoutResult,
              dismissResult: () => setState(() => _logoutResult = null),
              closureNotice: _closureNotice(context, api?.sessions),
              dismissClosureNotice: () => setState(() {
                _closureSubmission = null;
                _unconfirmedClosureScope = null;
              }),
              child: child!,
            )
          : HealthForeground(
              scope,
              child!,
              admission: AccountAccess.of(api!, scope),
            ),
      onGenerateRoute: (settings) {
        final privacy = scope == null ? null : PrivacyStore(api!, scope);

        void recover(BuildContext context) {
          if (draft != null) close?.call();
          Navigator.of(
            context,
          ).pushNamedAndRemoveUntil('/assessment', (_) => false);
        }

        Widget ordinaryScreen(BuildContext context) {
          final admitted = scope!;
          switch (settings.name) {
            case '/replies':
              return ReplyRoute(api!, admitted);
            case '/':
            case '/assessment':
              if (settings.name == '/' && draft != null) {
                return ReplyRoute(
                  api!,
                  admitted,
                  draft: draft,
                  close: () {
                    close?.call();
                    Navigator.of(context).pushReplacementNamed('/assessment');
                  },
                );
              }
              return AssessmentPage(
                AssessmentBook(api!, admitted),
                startup: settings.name == '/',
              );
            case '/practice':
              return const PracticeHomeRoute();
            case '/growth':
              return const GrowthRoute();
            case '/training':
              return const PracticeRoute();
            case '/marks':
              return MarksPage(
                MarkBook(api!, admitted),
                quick: settings.arguments == true,
              );
            case '/reviews':
              return ReviewPage(ApiReviews(api!, admitted));
            case '/marks/review':
              return ReviewPage(
                ApiReviews(api!, admitted),
                prefill: ReviewPrefill.tryFromRoute(settings.arguments),
              );
            case '/membership':
              return MemberPage(MemberStore(api!, admitted));
            case '/voice':
              return Consumer(
                builder: (context, ref, _) => ref
                    .watch(consentProvider)
                    .when(
                      data: (gate) => VoicePage.forAccount(
                        api: api!,
                        scope: admitted,
                        gate: gate,
                      ),
                      loading: () => const Scaffold(
                        body: Center(child: CircularProgressIndicator()),
                      ),
                      error: (_, _) => Scaffold(
                        body: StatusPanel(
                          '无法确认语音授权，请稍后重试。',
                          retry: () => ref.invalidate(consentProvider),
                        ),
                      ),
                    ),
              );
            case '/health':
              return HealthPage(admitted);
            case '/logout':
              return Scaffold(
                body: Center(
                  child: AlertDialog(
                    title: const Text('退出当前账号？'),
                    content: const Text(
                      '本机会立即清除续答、草稿和健康待发数据，并结束当前登录。'
                      '清理、健康撤回和服务端登出会分别显示结果。',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () async {
                          Navigator.pop(context);
                          await _logout(api!, admitted);
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

        Widget screen(BuildContext context) {
          if (status != null) return Scaffold(body: status);
          if (privacy == null) {
            return LoginPage(api!);
          }
          if (settings.name == '/privacy') {
            return PrivacyPage(
              privacy,
              onClosureSubmitted: (value) => _closureSubmitted(privacy, value),
              onClosureUnconfirmed: (value) =>
                  _setClosureUnconfirmed(privacy, value),
              onClosureCancelled: () => recover(context),
              onExit: () => _logout(privacy.api, privacy.scope),
            );
          }
          return _accountEntry(
            privacy,
            onActive: ordinaryScreen,
            onRecovered: () => recover(context),
          );
        }

        return MaterialPageRoute<void>(settings: settings, builder: screen);
      },
    );
    if (scope == null) return app;
    // Replacing the login lease replaces the navigator and its repositories.
    // Routes in this tree always resolve dependencies for the same lease.
    return ProviderScope(
      key: ObjectKey(scope),
      overrides: [accountScopeProvider.overrideWithValue(scope)],
      child: app,
    );
  }
}
