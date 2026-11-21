# 情商训练 · 运营后台

Flutter Web 独立构建，页面和 API **同源**。会话只存在当前标签页内存；刷新或过期后需重新登录。管理端不接受 App 令牌，无默认账号。以下均从仓库根执行：

```bash
export PATH="$PWD/build/toolchains/flutter/bin:$PATH"  # 初次安装见 docs/local-development.md
(cd admin && flutter pub get --enforce-lockfile && flutter build web --release --no-web-resources-cdn)
./server/dev.sh  # 创建本地环境、迁移并启动 API
# 构建和当前源码一致的工具镜像。密码只从标准输入交付，不放进命令参数、仓库或历史。
./server/dev.sh --profile verify build tests
# bash / zsh 均可：通过 getpass 在本机终端隐藏输入
python3 -c 'import getpass; print(getpass.getpass("新管理员密码（12–72 字节）: "))' | \
  ./server/dev.sh --profile verify run -T --rm --no-deps tests go run ./cmd/admin-account -login local-ops -role super_admin

docker compose --env-file build/t04/dev.env -p high-eq-dev -f docker-compose.yml -f admin/compose.yaml up -d admin-web
```

打开 `http://127.0.0.1:8090/`。同样方式可另建 `operator`（使用不同账号名），它无法查询审计或提交模型、密钥与路由变更。登录名仅接受 1–64 位 ASCII 字母、数字、`.`、`_` 或 `-`。CLI 仅新建，不覆盖现有账号或重置密码。停用本地后台：同一条 `docker compose` 命令将 `up -d admin-web` 改为 `stop admin-web`。本地代理不用于公网；生产部署须使用受限管理网络、HTTPS、登录限速和受控的数据库运维通道。

测试：`cd admin && flutter analyze && flutter test`。接口、页面扩展及事务性审计接入见 [T13 交接](../docs/tasks/T13.md)。
