import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/api.dart';
import '../../core/session.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});
  @override
  ConsumerState<LoginPage> createState() => _Login();
}

class _Login extends ConsumerState<LoginPage> {
  final name = TextEditingController(), pw = TextEditingController();
  final form = GlobalKey<FormState>();
  bool busy = false, hide = true;
  String? error;
  @override
  void dispose() {
    name.dispose();
    pw.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy || !form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final s = await ref.read(apiProvider).login(name.text.trim(), pw.text);
      if (mounted) {
        ref.read(sessionProvider.notifier).enter(s);
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = e is ApiFailure ? e.message : '登录失败，请重试');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 408),
            child: Form(
              key: form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Icon(
                      Icons.shield_outlined,
                      size: 38,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    '情商训练  /  运营后台',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '管理员登录',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 10),
                  const Text('使用独立的后台账号登录，不支持 App 用户凭据。'),
                  const SizedBox(height: 32),
                  TextFormField(
                    controller: name,
                    decoration: const InputDecoration(labelText: '管理员账号'),
                    textInputAction: TextInputAction.next,
                    validator: (s) =>
                        s == null || s.trim().isEmpty ? '请输入账号' : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: pw,
                    obscureText: hide,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: '密码',
                      suffixIcon: IconButton(
                        tooltip: hide ? '显示密码' : '隐藏密码',
                        onPressed: () => setState(() => hide = !hide),
                        icon: Icon(
                          hide
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                      ),
                    ),
                    validator: (s) => s == null || s.isEmpty ? '请输入密码' : null,
                    onFieldSubmitted: (_) => submit(),
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: busy ? null : submit,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(busy ? '正在登录…' : '登录'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
