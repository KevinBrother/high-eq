import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/api.dart';
import '../../core/endpoints.g.dart';
import '../../core/session.dart';
import '../../core/transport.dart';
import 'repository.dart';
import 'surface.dart';

const vendorChannel = MethodChannel('cn.higheq/mobile-commerce');

class LoginPage extends StatefulWidget {
  const LoginPage(this.api, {super.key});
  final AppApi api;
  @override
  State<LoginPage> createState() => _LoginState();
}

class _LoginState extends State<LoginPage> {
  bool privacy = false,
      accepted = false,
      age = false,
      busy = false,
      refused = false;
  String? message, issuedTo;
  int seconds = 0;
  Timer? timer;
  final phone = TextEditingController(), code = TextEditingController();
  bool get demo => widget.api.transport is ExampleTransport;
  String get number {
    final p = phone.text.trim();
    return RegExp(r'^1\d{10}$').hasMatch(p) ? '+86$p' : p;
  }

  @override
  void dispose() {
    timer?.cancel();
    phone.dispose();
    code.dispose();
    super.dispose();
  }

  Future<void> act(String method) async {
    if (busy || !privacy || !age) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final wire = MobileEndpoints(widget.api);
      final mobile = number;
      if ((method == 'phone' || method == 'sms') &&
          !RegExp(r'^\+[1-9]\d{6,14}$').hasMatch(mobile)) {
        setState(() => message = '请输入含国家代码的手机号。');
        return;
      }
      if (method == 'sms') {
        await wire.requestCode(body: {'phone': mobile});
        if (!mounted) return;
        issuedTo = mobile;
        seconds = 60;
        timer?.cancel();
        timer = Timer.periodic(const Duration(seconds: 1), (t) {
          if (--seconds <= 0) t.cancel();
          setState(() {});
        });
        message = demo ? '模拟验证码：000000（未发送短信）' : '验证码已发送。';
        return;
      }
      if (method == 'phone' &&
          (issuedTo != mobile ||
              !RegExp(r'^\d{6}$').hasMatch(code.text) ||
              (demo && code.text != '000000'))) {
        message = '请先获取并填写此号码的六位验证码。';
        return;
      }
      final proof = method == 'phone'
          ? code.text
          : demo
          ? 'contract-only'
          : await vendorChannel.invokeMethod<String>('authorize', {
              'provider': method,
            });
      if (!mounted || proof == null || proof.isEmpty) return;
      final response = await wire.login(
        body: {
          'credential': {
            'provider': method,
            'proof': proof,
            if (method == 'phone') 'phone': mobile,
          },
          'age_confirmed': true,
          'privacy_version': policyVersion,
          'terms_version': policyVersion,
        },
      );
      if (mounted) {
        await widget.api.sessions.activate(Tokens.fromJson(response));
      }
    } catch (e) {
      message = friendlyError(e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!privacy) {
      return Scaffold(
        body: Center(
          child: AlertDialog(
            scrollable: true,
            title: Text(refused ? '尚未进入对话手记' : '隐私政策与用户协议'),
            content: refused
                ? const Text('未同意，不会登录或开始测评。你可以关闭应用。')
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        '我们使用手机号或第三方登录标识管理账号，保存至注销。购买记录用于恢复权益，注销后脱敏保留。自评另行征求同意；这里不会申请手表或麦克风权限。',
                      ),
                      TextButton(
                        onPressed: () => showDialog<void>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            scrollable: true,
                            title: const Text('使用说明 · 2026-11'),
                            content: const Text(
                              '本服务面向已满 14 周岁的用户，用于沟通练习，不作医疗诊断。答卷用于雷达图与训练计划，加密保存至注销。未提交的答卷在本机加密续答，退出账号时清除。手表和语音均为可选；本流程不会读取健康数据或录音。可申请导出、删除个人数据或注销账号。\n\n当前为开发版本，运营主体、隐私联系人和正式协议需在上线前核定。请勿输入私人资料。',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx),
                                child: const Text('返回'),
                              ),
                            ],
                          ),
                        ),
                        child: const Text('查看使用与隐私说明'),
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: accepted,
                        onChanged: (v) => setState(() => accepted = v!),
                        title: const Text('我已阅读并同意'),
                      ),
                    ],
                  ),
            actions: refused
                ? [
                    TextButton(
                      onPressed: () => SystemNavigator.pop(),
                      child: const Text('退出'),
                    ),
                  ]
                : [
                    TextButton(
                      onPressed: () => setState(() => refused = true),
                      child: const Text('不同意'),
                    ),
                    FilledButton(
                      onPressed: accepted
                          ? () => setState(() {
                              privacy = true;
                              if (demo) phone.text = '+8613800000000';
                            })
                          : null,
                      child: const Text('同意并继续'),
                    ),
                  ],
          ),
        ),
      );
    }
    return FlowSurface(
      demo ? '契约模拟 · 无需私人账号' : '账号 · 01',
      '先为自己留一个空间',
      busy: busy,
      message: message,
      [
        const Text('只有已满 14 周岁才可使用本服务。'),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: age,
          onChanged: (v) => setState(() => age = v!),
          title: const Text('我已满 14 周岁'),
        ),
        TextField(
          controller: phone,
          readOnly: demo,
          enabled: age,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(labelText: '手机号'),
        ),
        TextButton(
          onPressed: age && seconds == 0 ? () => act('sms') : null,
          child: Text(seconds > 0 ? '${seconds}s 后可重发' : '获取验证码'),
        ),
        TextField(
          controller: code,
          enabled: age,
          keyboardType: TextInputType.number,
          maxLength: 6,
          decoration: const InputDecoration(labelText: '验证码'),
        ),
        FilledButton(
          onPressed: age ? () => act('phone') : null,
          child: const Text('手机号登录'),
        ),
        const Divider(height: 30),
        if (demo || Theme.of(context).platform == TargetPlatform.iOS)
          OutlinedButton(
            onPressed: age ? () => act('apple') : null,
            child: const Text('Apple 登录'),
          ),
        OutlinedButton(
          onPressed: age ? () => act('wechat') : null,
          child: const Text('微信登录'),
        ),
      ],
    );
  }
}
