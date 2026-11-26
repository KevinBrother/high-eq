# T17 首次自评续答宿主旅程

`resume_journey_test.dart` 由 Go 入口 `TestT17FirstAssessmentResumeJourney` 分两次启动。两次是独立 Flutter widget 进程，共用同一个合成账号和本机存储目录：

1. 第一次走正式隐私弹窗、年龄确认和 Apple 开发登录，在真实自评页点击前 7 题的选项，停在第 8 题。草稿由产品页写入加密缓存。
2. 第二次由产品 `Sessions.restore()` 恢复账号，自评页读回同一草稿，停在第 8 题；回到第 7 题核对已选选项，再完成第 8–16 题并从页面提交。

合成题库来自 `server/internal/service/testdata/t26_assessment.yaml`（版本 `t26-synthetic-1`，16 题、7 个选项）。Flutter 只通过 `T17_RESUME_ORIGIN` 上的回环 HTTP 访问真实服务；`T17_RESUME_APPLE` 是一次性开发登录票据。Go 在第二次旅程后用同一合成账号的新票据经 HTTP 读取 `GET /v1/assessments?limit=1`，并在只读事务中解密 `assessments` 行，核对：

- 答案序列为 UI 实际点击的 `[1..7,1..7,1,2]`；
- HTTP、PostgreSQL 和题库评分对同一答案序列一致；
- 只有一条已提交记录。

## 替身与边界

- 文件式 `SecretStore`（`T17_RESUME_SECRET`）替代平台 Keychain/Keystore，只为让两个独立进程共用同一合成账号；产品加密缓存和草稿读取仍由 `Sessions` 完成。
- Apple 登录的 `authorize` 方法由测试通道返回一次性开发票据；未调用真实 Apple、短信、商户或生产服务。
- `flutter test` 使用测试专用 live binding 推进真实时间；不是真机、真 iOS 杀进程或真人计时。安卓未纳入。
- 答案只通过产品页选项按钮写入，没有任何直接写草稿或注入 7 个答案的代码。

## 入口与前提

Go 入口要求：

- Go 1.26 工具链；`PATH` 上有 Flutter SDK，且 `app/.dart_tool/package_config.json` 已由 `flutter pub get --offline --enforce-lockfile` 生成。
- 一次性、空的 PostgreSQL 17：不得有既有用户、测评或 `model_routes` 行；数据库名和用户名须出现在 `DATABASE_URL` 中（可带 `sslmode=disable`）。共用夹具只接受空的模型目录。
- `T19_DISPOSABLE=yes`（或 `T20_DISPOSABLE=yes`）为共用夹具的实际启动门槛，`T17_DISPOSABLE=yes` 只是本卡入口的第一层门槛，二者必须同时设置。
- 普通缓存 Redis 使用 `REDIS_URL`，独立账本 Redis 使用 `LEDGER_URL`（DB 0；`appendonly yes`、`appendfsync always`、`maxmemory-policy noeviction`、`no-appendfsync-on-rewrite no`、`aof-load-truncated no`）。两者必须是不同实例。
- `APP_ENV=development`、正整数 `BACKUP_RETENTION_DAYS`、本次运行新生成的 32 字节 Base64 `FIELD_KEY_BASE64`、`PAYMENT_MODE=disabled`。
- `WLEIS_CONFIG_PATH` 指向仓内合成题库；`T17_DISPOSABLE=yes`。
- 宿主可用的 `TMPDIR`、`PUB_CACHE` 和 Flutter 缓存写权限。

```sh
cd server
T17_DISPOSABLE=yes T19_DISPOSABLE=yes APP_ENV=development \
PAYMENT_MODE=disabled \
DATABASE_URL="postgres://user@127.0.0.1:PORT/db?sslmode=disable" \
REDIS_URL="redis://127.0.0.1:CACHE_PORT/0" \
LEDGER_URL="redis://127.0.0.1:LEDGER_PORT/0" \
BACKUP_RETENTION_DAYS=45 \
FIELD_KEY_BASE64="$(openssl rand -base64 32)" \
WLEIS_CONFIG_PATH=internal/service/testdata/t26_assessment.yaml \
go test -count=1 -v -tags integration,t17resume \
  -run '^TestT17FirstAssessmentResumeJourney$' ./internal/service
```

Go 入口为两个 Flutter 子进程单独开一个真实 HTTP 监听，只统计 `POST /v1/assessments` 的次数和响应状态：第一次中断前必须为 0，第二次一次点击后必须为 1 且状态 200。计数在请求进入处理器时按当前阶段归属，响应状态单独记录，因此跨阶段的慢请求不会换桶。种子和提交后的 Go 回读不经过该监听，不计入。第二次进程还会从结果页读出总分和四轴的实际显示数字，交给 Go 与同一次提交的题库评分对账；日志只含数字/状态，不含题目正文或票据。
