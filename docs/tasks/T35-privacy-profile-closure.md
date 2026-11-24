# T35 隐私入口、账号资料与注销恢复

## 发布范围

本卡以已独立上线验证的[关系人删除恢复首卡](T35-deletion-recovery.md)（`26a1da9`）为基础，隐私与账号注销小卡尚未上线。「我的 → 隐私与个人数据」和命名路由 `/privacy` 打开同一个正式页面。页面从 `GET /v1/me` 查阅账号 ID、绑定方式和时区，经 `PATCH /v1/me` 更正时区，再用 `GET /v1/me` 确认保存。资料查阅限账号资料。

注销沿用当前绑定身份。手机号须在注销表单重新申请验证码。Apple 与微信复用登录桥。确认对话框提示取消苹果订阅和 15 天冷静期。服务接受注销后立即撤销该账号全部会话。App 退役当前本机登录和加密缓存，并显示截止时间。清理失败时显示待确认，沿用会话退役日志在下次登录前重试。

每个登录租约以同账号的 `/v1/me` 为业务准入依据。读取失败时显示状态、重试和退出。冷静期重新登录显示冻结截止时间和「撤销注销申请」。业务路由与系统分享入口都经同一准入。健康前台任务也等待准入，避免冻结后重登触发授权或待发请求。撤销须由用户点按，直到读取同账号的 `frozen_until: null` 才返回正式自评入口。服务按自身时钟拒绝到期恢复，启动及分钟维护沿用首卡协调器清理，既有 T26/T27 的服务端准入和成长缓存行为维持原契约。

ZIP、逐记录权利、D13 授权拆分、绑定换号、语音功能和 Android 分属后续发布单元。本卡复用现有账号与清理服务和数据库迁移。门禁覆盖 development 合成身份和隔离存储。

## 正式入口

正式源码 [`app/lib/features/home/shell.dart`](../../app/lib/features/home/shell.dart) 已导入 `../privacy/entry_tile.dart`，并在 `Section.me` 渲染 `const PrivacyEntryTile(),`。这两处接入保留宿主已有的语音和健康菜单相对顺序，用户本地排序差异留在宿主。[客户端旅程](../../app/test/privacy/account_journey_test.dart) 从正式 `HighEqApp` 的 `/practice` 底栏进入 `/me`，滚动当前列表点按入口，核对 `/privacy` 和读回的账号 ID。CI 在检出的提交上验证这条旅程，入口缺失会阻断客户端门禁。

## GitHub 门禁

[T35 工作流](../../.github/workflows/t35-privacy.yml) 在 push 或 PR 涉及客户端、服务端、契约和门禁依赖时触发，也可手动启动。两个 job 分别记录客户端与服务结果。

- **Formal privacy client** 使用 Flutter 3.38.10 和锁定的依赖，执行 `gate.sh client`。门禁运行正式页面的全部 10 项 Widget 测试，其中 6 个具名用例必须分别取得 Flutter JSON 成功回执，Flutter 关联回归也须成功退出。
- **Privacy service and account lifecycle** 使用 `server/go.mod` 指定的 Go 版本。`ci-service.sh` 启动当前工作流实例独占的 PG17、普通 Redis 与独立 Redis 8.2 AOF 删除账本，在三条动态回环端口上执行 `gate.sh service`，要求 2 项契约、4 项集成共 6 项具名 Go JSON 回执。启动失败、用例缺项或跳过、命令失败以及清理失败都会阻断 job。服务输出只报告阶段、具名测试与结果，测试原始输出保存在临时目录并在退出时清理。

[T26](../../.github/workflows/t26-new-user-plan.yml) 和 [T27](../../.github/workflows/t27-growth.yml) 各自通过 `app/lib/**` 监听正式客户端改动，分别运行引用 `HighEqApp` 的原有旅程。T35 的两个 job 只运行本卡门禁。[T04](../../.github/workflows/t04-server.yml) 的 `t35-process` job 负责真实 `cmd/api` 的公开删除屏障、分钟任务和启动失败保护。

## 宿主复验

在仓库根目录使用 Flutter 3.38.10 和 Python 3 执行离线回执检查及客户端门禁。

```sh
python3 -B app/tool/t35-privacy/test_gate.py
(cd app && flutter pub get --enforce-lockfile)
(cd app && flutter analyze)
(cd app && flutter test --no-pub)
bash app/tool/t35-privacy/gate.sh client
```

客户端门禁要求以下 6 个具名回执。

- `named privacy route reads account and verifies persisted correction`
- `frozen relogin gates business routes until explicit cancellation and readback`
- `unknown account never starts assessment or growth`
- `phone closure submits one fresh proof and retires the local lease`
- `my tab opens the formal privacy page`
- `lost closure receipt remains visible on login after unauthorized readback`

服务门禁使用 Go 1.26、Python 3、空的独占 PG17 测试库和两套独立 Redis。通过宿主进程环境显式提供 `APP_ENV=development`、`PAYMENT_MODE=disabled`、`DATABASE_URL`、`REDIS_URL`、`LEDGER_URL`、`BACKUP_RETENTION_DAYS`（CI 为 `45`）和本轮新生成的 32 字节 Base64 `FIELD_KEY_BASE64`。三个存储地址使用数字回环 IP 和显式端口。账本用 Redis 8.2 的 DB 0，首次绑定为空，并启用 `appendonly yes`、`appendfsync always`、`maxmemory-policy noeviction`、`no-appendfsync-on-rewrite no`、`aof-load-truncated no`。

```sh
T35_PRIVACY_DISPOSABLE=yes bash app/tool/t35-privacy/gate.sh service
```

重跑服务门禁需要新的空库和独立账本。门禁通过 Go JSON 验证以下具名用例实际运行并通过。

- [契约用例](../../server/internal/service/privacy_account_contract_test.go) `TestPrivacyAccountRouteContract`、`TestPrivacyAccountBarrierResponse` 验证四个路由注册、匿名拦截、冻结例外和可重试 503。
- [手机号生命周期](../../server/internal/service/privacy_account_integration_test.go) `TestPrivacyPhoneOnlyClosureHTTP` 走正式路由，覆盖更正读回、拒绝旧验证码、旧访问及刷新会话作废、冻结重登、冻结写入与成长入口拒绝、显式撤销及到期维护清理。用例直接调用 `RunMaintenancePass`。
- [到期清理故障隔离](../../server/internal/service/privacy_account_maintenance_integration_test.go) `TestPrivacyExpiredAccountMaintenanceIsolatesFailure` 通过 `RunMaintenancePass` 验证最早到期账号持续清理失败时，同轮清理跨页的其余到期账号，并核对未到期账号、SQL 待办、独立账本、启动拒绝和撤除故障后的恢复。
- `TestAccountLifecycle` 复验原清理、支付脱敏、评分防重放和取消与清理并发。`TestGrowthRoutesRejectFrozenAccountWithoutGeneratingPlan` 复验冻结重登和禁止补生成计划。

宿主单独复跑 T26/T27 时，另设 `T35_PG_BIN`（PG17 工具目录）与 `T35_REDIS_BIN`（`redis-server` 路径）。`legacy` 依次运行 `TestT26NewUserPlanFlutter` 和 T27 的 `history_journey.py`。

```sh
T35_PRIVACY_DISPOSABLE=yes bash app/tool/t35-privacy/gate.sh legacy
```

契约改动限于描述和错误响应。Go 检查和契约生成复跑从仓库根目录执行。Python 依赖见 `scripts/contract-requirements.txt`，将固定版本的 `oapi-codegen` 安装到 `PATH` 上。

```sh
(cd server && go test -race ./... && go vet ./...)
python3 scripts/check_contracts.py
python3 app/tool/generate_api.py --check
go install github.com/oapi-codegen/oapi-codegen/v2/cmd/oapi-codegen@v2.5.1
./server/generate.sh
git diff --exit-code -- server/internal/api
```

## 验收记录

- **本轮宿主客户端已验。** 正式隐私页面 10 项 Widget 测试全部通过，6 个具名用例和 Flutter 关联回归均取得 `PASS`。其余 4 项覆盖 503 后重试读回且只提交一次、取消 Apple 重新认证、迟到刷新对不同账号和同账号的新租约各一次。两项迟到刷新用例均实际发出旧租约的刷新请求，在新租约生效后释放旧请求的 401 响应并等待读回结束，确认新租约和页面仍有效，旧注销提示未出现。标准 Flutter 全量测试 525 项通过、2 项跳过。
- **丢失注销回执已验。** 同一独立探针在旧版因登录页缺失「未收到注销确认」提示而失败，在修复版通过。提交响应丢失，读回与刷新均返回 401 后，旧租约退役，登录页显示「未收到注销确认」并提示重新登录核对。关闭提示后仍停留在登录页。
- **手机号注销旅程已验。** 用例确认「暂不注销」时未发送注销请求，首个凭证被拒后须重新申请验证码，注销成功后退役本机租约并清空缓存。在 320×568 的 Widget 测试视口中，注销成功返回登录页时可见提交回执和截止日期。点按可见的「关闭注销提示」后，回执消失，用户仍在登录页。此前的宿主运行在同一返回路径上因回执区的 `Tooltip` 位于 `Overlay` 外而失败，修复后该旅程已在宿主复验通过。
- **本轮宿主服务和原有旅程已验。** PG17、缓存 Redis 和独立 AOF 账本上的 2 项契约、4 项集成均取得顶级 `PASS`，无跳过。`TestT26NewUserPlanFlutter` 通过（9.83 秒），`TestT27HistoryJourney` 通过（8.75 秒）。
- **到期清理故障隔离和启动保护已验。** 旧版回归在最早到期账号的清理持续失败后，留下 101 个本应清理的到期账号，账本登记为 0。修复版在同一轮分钟维护中跨页清除其余 101 个到期账号并登记删除，保留未到期账号。失败账号保留 SQL 待办和独立账本登记，故障移除后可重试清理。故障仍在时，启动继续传播清理错误并拒绝启动服务。
- **前轮宿主检查已验。** `flutter analyze`、Go race 和 vet 通过。OAS 校验通过（App 66 项、Admin 18 项），Flutter 生成物检查通过，固定 `oapi-codegen v2.5.1` 重新生成 App 和 Admin Go 代码后均逐字节相同。
- **归档离线已验。** `test_gate.py` 四项通过，覆盖缺项、跳过、进程失败、共用 Redis、存储启动和清理失败及原始日志隔离。工作流 YAML 与路径触发已静态核对。前轮归档通过 Flutter 静态分析及测试编译、Go 契约和账号服务单测。前轮归档的 Widget 测试设备启动受回环绑定限制，修复后的 Widget 验收采用宿主回执。
- **云端及上线验收待补。** 推送后在 GitHub Actions 核对候选提交的 push 和 PR 运行，确认 T35 两个 job 的实际回执及 T26、T27、T04 对应门禁通过。生产环境、真机、物理断网、外部签收均待验。上述宿主门禁使用 development 合成身份与隔离存储，旅程传输工具用于测试。完整 T35 仍按[总任务验收范围](../tasks.md#t35-我的页与个人信息权利客户端--后端)单独验收。

## 改动清单

| 路径 | 改动 |
|---|---|
| `app/lib/main.dart` | 注册正式隐私路由，业务路由和冷热分享经过当前租约准入，撤销读回后回到自评，登录页显示申请与清理结果 |
| `app/lib/features/home/shell.dart` | 导入正式隐私入口组件并在「我的」渲染 |
| `app/lib/core/api.dart` | 给有状态 JSON 请求增加发送前同步校验；注销凭证 401 直接呈现；未知或冻结退出时延后远端健康撤回 |
| `app/lib/features/onboarding/account_entry.dart` | 从候选提取租约准入页面和冻结恢复分流 |
| `app/lib/features/privacy/account_access.dart` | 从候选提取严格 `/me` 解码、同账号校验、合并并发读回和冻结状态 |
| `app/lib/features/privacy/store.dart` | 从候选提取时区更正、SMS 与原生重新认证、注销、退役及撤销操作 |
| `app/lib/features/privacy/page.dart` | 从候选提取资料、注销确认和冷静期界面 |
| `app/lib/features/privacy/entry_tile.dart` | 「我的 → 隐私与个人数据」入口组件 |
| `app/lib/features/health/binding.dart` | 前台健康任务跟随账号准入 |
| `app/lib/features/replies/share_host.dart` | 在现有登录通知区域呈现注销回执 |
| `docs/api/app.yaml` | 仅 `/v1/me` 和 `/v1/me/closure` 四个动作补 503 与状态契约 |
| `server/internal/service/privacy_account_contract_test.go`、`server/internal/service/privacy_account_integration_test.go` | 正式路由契约与手机号生命周期 |
| `app/test/privacy/account_journey_test.dart` | 正式根 App 的命名路由、更正读回、冻结与未知准入、发送证明及清理、「我的」导航 |
| `app/test/{health/page_test,onboarding/journey_test,practice/pending_plan_gesture_test,replies/entry_test,voice/page_test}.dart` | 给现有合成客户端补对应账号的 `GET /v1/me` 夹具，保留原断言 |
| `.github/workflows/t35-privacy.yml` | push、PR 与手动触发的客户端和服务门禁 |
| `app/tool/t35-privacy/{gate.sh,client_receipt.py,ci-service.sh,test_gate.py}` | 宿主与 CI 门禁、具名回执、CI 一次性存储和离线失败回归 |
| `docs/tasks/T35-privacy-profile-closure.md` | 本卡发布范围、复验和交接 |
