# 本地工具链

从仓库根目录执行。不要为了这个项目覆盖系统 Flutter、修改全局 PATH 或提交 SDK。

## Flutter（T13、T16 起共用）

本项目可使用 Flutter **3.38.10**（Dart **3.10.9**）。`build/` 已被 Git 忽略。如果已有对应 SDK，可跳过下载和路径设置；本地已有 `build/toolchains/flutter` 时直接使用，不要再次 clone。

```sh
mkdir -p build/toolchains
git clone --depth 1 --branch 3.38.10 https://github.com/flutter/flutter.git build/toolchains/flutter
test "$(git -C build/toolchains/flutter rev-parse HEAD)" = c6f67dede3d4aa1aa7a69dd56a3494a5cde6cc80
export PATH="$PWD/build/toolchains/flutter/bin:$PATH"
flutter --version
```

首次运行会拉取 Dart 和 Flutter 工具依赖。切换终端只需再次设置 PATH。可按开发平台执行 `flutter precache --web`、`--ios` 或 `--android`；SDK 可运行不代表真机能力、系统授权或平台审核已经通过。

## Go 服务与数据库

使用 Go 1.26.x；若需要先确认本地可用性，无需启动生产服务：

```sh
docker run --rm golang:1.26-alpine go version
docker run --rm redis:8.2.0 redis-server --version
./server/tests/migrations.sh
```

最后一条需要本机 `migrate` v4 工具，创建独立 PostgreSQL 容器，测试后销毁。不要将项目 `.env`、平台密钥或个人签名证书传给 CI。
