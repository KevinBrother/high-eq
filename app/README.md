# 对话手记 · 手机客户端

Flutter iOS / Android，SDK 3.38.10。默认离线示例模式，无需连接后端、登录或授予传感器权限。只含四个导航入口，未实现业务页。

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

[开发、验收、边界与接手入口](../docs/tasks/T16.md) · [App 契约](../docs/api/app.yaml)
