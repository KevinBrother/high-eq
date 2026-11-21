# 对话手记 · 手机客户端

Flutter iOS / Android，SDK 3.38.10。默认离线示例模式。首次打开从隐私摘要、年龄确认和示例登录开始；无需私人账号、真实短信、付款或传感器权限。

```sh
# 仓库根，参见 docs/local-development.md 安装 SDK
export PATH="$PWD/build/toolchains/flutter/bin:$PATH"
cd app
flutter pub get --enforce-lockfile
flutter devices
flutter run -d <设备ID>  # 默认 APP_ENDPOINT=mock
# 改同一项配置后重新运行；使用设备可访问且证书受信的 HTTPS 源站
flutter run -d <设备ID> --dart-define=APP_ENDPOINT=https://api.example.org
```

## 试用路径

1. 阅读摘要并主动勾选同意，确认已满 14 岁。示例模式点「获取验证码」，使用页面提示的模拟码，也可选择示例第三方登录。
2. 单独同意后逐题作答，点「稍后续答」可暂时离开；从首页的「本次自评与续答」继续。第 16 题之后选场景，提交后可看四轴结果与复测时间。跳过自评不影响其他页面。
3. 「我的」可查看会员权益、恢复购买或退出。示例模式不会扣款、授予会员或代表平台审核通过。真实服务和商户条件见 [T17 验证与交接](../docs/tasks/T17.md)。

[脚手架、网络与存储入口](../docs/tasks/T16.md) · [App 契约](../docs/api/app.yaml)
