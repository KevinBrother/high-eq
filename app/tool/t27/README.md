# T27 成长档案与关系人删除验收

从仓库根目录运行。需要已安装的 Go 1.26、缓存完整的项目 Flutter SDK 和锁定依赖、本机 PostgreSQL 17，以及支持 `WAITAOF` 的 Redis。Go 模块须已在默认缓存或 `GOMODCACHE` 中。App 的 `app/.dart_tool/package_config.json` 和 `package_graph.json` 须由已准备好的 Flutter SDK 使用锁定依赖生成。

```sh
python3 app/tool/t27/history_journey.py \
  --pg-bin /path/to/postgresql-17/bin \
  --redis /path/to/redis-server \
  --flutter /path/to/flutter/bin/flutter \
  --go /path/to/go/bin/go
```

`--flutter` 和 `--go` 缺省时从 PATH 解析。启动器在三个随机回环端口启动全新的 PG17、普通 Redis 和独立 AOF Redis，复跑正式服务路由和 Flutter widget 用例，退出后停止进程、清除临时数据。仅使用合成账号、一次性登录票据和本地脚本化的评分/审核供应商。Flutter 用已缓存的工具和依赖，Go 模块代理关闭。脚本不需要 Docker、已启动的服务、`.env` 或账号凭据。它验证正式 Flutter 页面交互，无需真机。

进入 Go 和 Flutter 前，启动器先向它创建的账本 Redis 写入探针键，在同一条连接发送生产账本使用的 `WAITAOF 1 0 3000`。收到一个本地 AOF 落盘回执并删除探针键后，输出 `PASS(redis.ledger-durability)`。能力不足时以退出码 `2` 和固定阶段 `redis.ledger-durability` 停止。这个前置检查独立于正式旅程原有的 18 个成功回执。

| 阶段 | 通过条件 |
| --- | --- |
| `service.runtime` / `service.seed` | 运行真实迁移和服务健康检查，经 HTTP 建立合成测评和 101 条对练，完成 15/25、100/100 和 60/100 三条记录。仅用 SQL 将 60/100 的完成时间置空以模拟历史记录。 |
| `service.order-and-cursor` / `page.growth-history` | HTTP 的 100+1 记录按创建时间分页，重放完成请求保留完成时间。正式训练大厅按创建顺序展示，系统返回事件回到练习主页。正式成长页跨页按完成时间倒序展示，历史空时间排在最后。客户端核对首个响应的 `next_cursor`、后续请求和实际返回 ID，另输出各组请求的重复读取次数。 |
| `service.reference-before` / `page.offline-without-deletion` | 真实成长接口包含两条完整行为计算的参考分。退出再进入成长页时，让测试 HTTP 入口仅对 `GET /v1/sessions` 返回 503，确认原有加密缓存仍能显示全部原记录和参考分。 |
| `service.contact-summary-before` | 正式页面删除前，归属账号 A 读取 `GET /v1/contacts/{id}/summary`，返回 `200` 和有效画像。 |
| `page.contact-deleted` / `page.deleted-cache` | 点击正式关系人页面上的删除和确认，校验真实 DELETE 回执。后续 503 允许显示明确错误与重新加载，或显示安全的离线快照。页面、当前仓库缓存和直接读回的加密缓存均不得显示已删 100/100 或删除前参考分。 |
| `page.growth-recovery` / `service.delete-cascade` | 点击正式重试按钮，经真实 HTTP 读回 100 条剩余对练。页面和缓存只剩 15/25 与 60/100，参考分按一条完整行为重算。直接查 PG 确认关系人、关联对练、消息、评分和成长投影已删除，保留两条不关联的已完成记录。 |
| `page.account-isolation` | 通过真实登录接口及 Sessions 激活 B，旧 A scope 被拒绝。B 遇到 503 时没有 A 的缓存，重试后从真实服务读到空历史，参考分仍待解锁。冷重开 B 后从本地加密缓存读回这一状态。 |
| `service.contact-summary-after` | 删除成功并核验级联后，同一地址对 A 返回 `404 contact_not_found`，无凭证和无效令牌分别返回 `401 unauthenticated`。 |

每次运行的日志在 `build/t27-history/run-*/`。服务启动、播种、HTTP 请求、UI 等待及整个进程均有截止时间。`journey.log` 保留 `BEGIN(...)`、`PASS(...)`、`FAIL(...)` 和请求计数。启动器核对 Go 用例和各阶段的成功回执后才输出 `RESULT: PASS` 并以 `0` 退出。`1` 表示断言失败、超时或缺少成功回执，`2` 表示前置条件不足或用例未启动，`3` 表示 Go 用例明确跳过。

不启动服务的游标回归可直接运行：

```sh
dart app/tool/t27/history_cursor_smoke.dart
```

从仓库根目录复跑使用合成传输的客户端丢回执单例。

```sh
cd app
flutter test --no-pub -r expanded test/contacts/repository_test.dart \
  --plain-name '提交后丢回执，列表即使已空仍可只读核对并重建离线成长'
```

## 知识卡目录读取与完成旅程

从仓库根目录运行。入口是 Bash 加 Python 3（内部 `exec python3`），并从 PATH 解析 `go` 与 `flutter`。需要：

- Go 1.26.x（`server/go.mod` 为 `1.26.0`）。
- Flutter 3.38.10（Dart 3.10.9），按 [本地工具链](../../../docs/local-development.md) 准备。宿主 widget 用例由该 SDK 的 `flutter test` 执行；首次运行前按宿主平台预缓存工具工件（CI 在 Linux 执行 `flutter precache --linux`，macOS 可用 `flutter precache --macos`）。
- 本机 PostgreSQL 17，`--pg-bin` 目录含 `postgres` 与 `initdb`，二者须以普通用户启动（入口不降权）。
- 支持 `WAITAOF` 的 Redis（CI 用固定的 8.2.0 源码构建，供应命令见下文）。

干净检出先准备锁定依赖。冷缓存首次准备需要网络；`--offline` 只在对应缓存已齐时使用。

```sh
(cd app && flutter pub get --enforce-lockfile)   # 生成 app/.dart_tool/package_config.json 与 package_graph.json
(cd server && go mod download)                   # 填充 Go 模块缓存
(cd app && flutter pub get --enforce-lockfile --offline)  # 仅缓存齐全时
```

`go mod download` 和旅程必须使用同一个模块缓存：默认 `GOMODCACHE`，自定义时在准备和运行两端设同一个 `GOMODCACHE`。旅程运行时关闭模块代理（`GOPROXY=off`），只使用缓存中已有的模块；冷缓存下的完整 `go mod download` 可以联网补齐。可选核对用 `(cd server && GOPROXY=off go list -mod=readonly -tags=integration,t27knowledge -deps -test ./internal/service)`，在与旅程相同的缓存下执行，只验证该具名用例的离线模块依赖，不要求缓存具备全部模块，也不替代首次 `go mod download`；缺少该用例所需模块时，Go 会在旅程启动阶段停在 `go.startup`（退出 2）。

完整旅程模式只使用 `--pg-bin` 与 `--redis`，复用 `history_journey.py` 的一次性 PG17、缓存 Redis 和 AOF 账本 Redis 启动、账本预检与清理，只替换 Go 用例：

```sh
bash app/tool/t27/verify_knowledge_catalog.sh \
  --pg-bin /path/to/postgresql-17/bin \
  --redis /path/to/redis-server
```

完整旅程的退出 `0` 要求旅程完成、`--- PASS: TestT27KnowledgeCatalogJourney` 与八个具名回执 `service.catalog`、`page.browse-last-card`、`page.read-no-complete`、`page.plan-card-complete`、`page.growth-tab`、`page.growth-home`、`service.after`、`journey` 全部取得。状态对应：`1 → FAIL(stage)` 表示已进入旅程的断言失败、超时或缺少成功回执；`2 → NOT RUN(stage)` 表示前置不足或 Go 未进入用例，阶段属于启动边界（如 `workspace`、`postgres.binary`、`redis.binary`、`go.binary`、`flutter.binary`、`flutter.sdk-cache`、`postgres.version`、`go.version`、`flutter.dependencies`、`loopback.reserve`、`postgres.initdb`、`postgres.startup`、`redis.cache-startup`、`redis.ledger-startup`、`redis.ledger-durability`、`go.startup`）；`3 → SKIPPED(go.startup)` 表示 Go 明确跳过。三者都打印对应的 `STATUS(stage)` 行和 `T27_HISTORY_STAGE=stage`。

离线日志分类是独立子模式，不启动服务或旅程，也不需要 `--pg-bin`／`--redis`：

```sh
bash app/tool/t27/verify_knowledge_catalog.sh \
  --classify-log /path/to/journey.log --status 1
```

它只按给定日志和退出码归类：`FAIL(stage)` → `1`，Go 未进入用例 → `2`，Go 明确跳过 → `3`，未发现失败或跳过 → `0`。这里的退出 `0` 只表示“按给定日志与 `--status` 没有可识别的失败或跳过”，不是完整旅程回执：空白日志加 `--status 0` 也会输出 `RESULT: PASS` 并退出 `0`。分类结果不能替代完整旅程的八个回执和具名 Go PASS。

本地工位已有本入口的实际运行证据（完整旅程与离线归类），保存在任务归档而不入仓。仓库 CI 目前只完成手动运行接线，尚未在云端实际执行过；云上首次手动运行的运行回执为准。

## GitHub Actions

`T27 growth and practice` 保留旧的成长 HTTP 旅程与 Flutter 回归，新增关系人核对入口、旅程组件辅助回归，以及独立 PG17、缓存 Redis 和 AOF Redis 上的正式历史旅程。推送、拉取请求和手动运行均可触发。运行摘要逐项给出 `PASS`、`FAIL`、`NOT RUN`、`SKIPPED` 或 `CANCELLED`。三项均须有成功回执。摘要和检查步骤只输出固定结果，原始测试日志保留在运行环境中或随临时文件清理。

手动运行还额外执行知识卡目录读取与完成旅程，复用同一作业已安装的 PG17、Redis 和 Flutter/Go。该步骤只在 `workflow_dispatch` 时执行；执行失败或前置不足会使本次运行失败，推送和拉取请求不会执行它，也不把它记为通过。该步骤不写入上面的运行摘要。

Ubuntu 24.04 运行器从 Redis 官方发行源下载固定的 8.2.0 源码，使用 `redis/redis-hashes` 发布的 SHA-256 核验后编译，再检查构建产物的版本。正式历史旅程显式使用该原生二进制。若随后在 `page.contact-deleted` 失败，CI 摘要会给出固定的 HTTP 观测值。`acknowledged` 表示对目标的 DELETE 已收到 `200` 且 `ok=true`，页面成功提示与列表状态仍各有断言。`http-403`、`http-500` 和 `http-503` 表示观测到对应 HTTP 状态。`unacknowledged` 包含已收到 `200` 但正文无法解码为 JSON 对象的情况，解析错误仍会使旅程失败。`unobserved` 表示没有目标 DELETE 回执，`multiple` 表示观测到多条回执。

在仓库根目录离线复跑回执和 Redis 供应回归，无需 Flutter 或本地服务。

```sh
python3 -B -m unittest discover -s app/tool/t27 -p 'test_*.py' -v
dart app/tool/t27/history_delete_smoke.dart
```

在 Ubuntu 24.04 安装 `build-essential` 后，可先单独验证 Redis 供应和账本能力。账本预检仅需 Python 3、待验的 `redis-server` 和回环监听权限。

```sh
t27_redis_install=$(mktemp -d)
bash app/tool/t27/install_redis.sh "$t27_redis_install"
python3 -B app/tool/t27/history_journey.py --ledger-only \
  --redis "$t27_redis_install/redis-server"
python3 -B app/tool/t27/history_journey.py --ledger-only \
  --redis /path/to/redis-7.0.15/redis-server
```

8.2.0 应输出 `PASS(redis.ledger-durability)` 并退出 `0`。7.0.15 应输出 `NOT RUN(redis.ledger-durability)` 并退出 `2`。随后将新二进制传给本页开头的完整旅程命令，核验 18 阶段和 `RESULT: PASS`。GitHub Actions 上还需取得客户端和旧 HTTP 检查的两个独立 `PASS`。

## 四周复测旅程

从仓库根目录运行，复用宿主机安装的 Go 1.26、缓存完整的 Flutter SDK、PostgreSQL 17 和两份 Redis 实例。入口复用 `history_journey.py` 的随机回环服务启动、账本 `WAITAOF` 预检与清理，只替换 Go 用例；`flutter` 和 `go` 从 PATH 解析，App 目录由仓库检出位置确定，不接受卡目录或 SDK 绝对路径。入口只接受 `--pg-bin` 与 `--redis`，拒绝 `--ledger-only` 等通用预检参数；退出 0 必然要求完整旅程、五个阶段回执和具名 Go／Flutter 通过。Go 用例只在 `integration && t27reassess` 且显式 `T27_DISPOSABLE=yes` 时运行，不带 `t27reassess` 的服务器回归不受影响。

```sh
bash app/tool/t27/verify_reassessment.sh \
  --pg-bin /path/to/postgresql-17/bin \
  --redis /path/to/redis-server
```

| 阶段 | 通过条件 |
| --- | --- |
| `page.journey` | 同一合成免费账号从正式成长页的「去复测」进入正式 `/assessment`，完成 16 题第二套答卷并提交，得到 75 分和「距下次可复测还有 28 天」。首次自评（SEA 0、OEA 17、UOE 83、ROE 100）与复测（100、100、100、0）的四维读屏值和总分变化全部核对，OEA/UOE 不会被互换。次日只检查「单项练习」实际计划行子树内的目录副标题。 |
| `readback.assessments` | 正式导出 Hook 在只读事务内解密 PostgreSQL，确认同一账号恰有两份测评；答卷、题库版本、重算分数一致，首份 `completed_at` 是数据库时钟减 28 天的夹具，两份相差至少 672 小时，最弱维度从 SEA／观察变为 ROE／请求。 |
| `readback.plan-kept` / `readback.plan-adjusted` | 同日旧计划仍关联首份测评并保留观察维度；换到相邻当地日后生成的下一份计划关联复测结果。 |
| `journey` | 正式 `GET /v1/assessments?limit=2` 的最近/更早映射、四维 `percent/display/level`、所有维度均有变化、总分差 +25 与持久导出行全部一致；正式 `GET /v1/plans/today` 的单项关卡 `content_id` 与持久计划行精确相等，页面再只在同一「单项练习」行的子树内核对对应目录副标题。 |

边界：首份测评的四周历史只改 `completed_at` 一个字段，不推进系统时钟，也不执行未满四周的拒绝请求；换日通过正式 `PATCH /v1/me` 调整账号时区，不模拟真实午夜、前台恢复或后台恢复；页面只在「单项练习」计划行子树内按正式目录标题核对，不比较雷达像素，也不逐项核对旧计划全文。真实 Apple 授权、真机、Android、外部模型和云上执行均不在本入口的证明范围内；CI 只接入同一窄测，实际云执行需以运行回执为准。

## 断卡成就保留旅程

从仓库根目录运行，复用宿主机安装的 Go 1.26、缓存完整的 Flutter SDK、PostgreSQL 17 和两份 Redis 实例。入口复用 `history_journey.py` 的一次性服务启动、账本 `WAITAOF` 预检和清理，只替换 Go 用例；`flutter` 和 `go` 从 PATH 解析，App 目录由仓库检出位置确定，不接受卡目录或 SDK 绝对路径。入口只接受 `--pg-bin` 与 `--redis`，退出 `0` 必然要求完整旅程、十一个阶段回执和具名 Go／Flutter 通过。Go 用例只在 `integration && t27streak` 且显式 `T27_DISPOSABLE=yes`、`T19_DISPOSABLE=yes` 时运行；不带 `t27streak` 的服务器回归不编译此文件。

```sh
bash app/tool/t27/verify_retained_milestones.sh \
  --pg-bin /path/to/postgresql-17/bin \
  --redis /path/to/redis-server
```

| 阶段 | 通过条件 |
| --- | --- |
| `service.seeded-history` | 正式 HTTP 提交一份合成自评并生成今天的计划。唯一夹具是 30 个连续完成日的 `daily_plans` 行，末日为今天前两天，今天前一天完整未打卡。每行用生产字段密钥按生产 stored-plan 形状封装，含四个真实计划项、一个已完成的免费小练习和当地正午的 `completed_at`；生产计划导出在旅程开始前成功打开全部 31 份计划。 |
| `service.retained-before` | 正式 `GET /v1/growth` 返回当前连续 `0` 天和 `[3,7,30]`；正式 `GET /v1/plans/today` 仍是四项皆未完成。没有改系统时钟，也没有把成就写进 API 响应或 UI 缓存。 |
| `page.retained-milestones` | 正式 Flutter 练习首页显示「连续 0 天」、`0 / 4 已完成`，三个成就节点都是「已达成」，且没有「新成就解锁」弹窗。 |
| `page.practice-strip` | 在练习首页用普通拖动把「坚持的痕迹」阶段区滚入视口；三个阶段文字都命中可点击视口，真实渲染树中每枚都是已获得分支（`Icons.workspace_premium` + `tertiaryContainer`），阶段区内没有锁图标或未获得底色。 |
| `page.growth-retained` | 通过底部导航「成长」打开正式成长档案，普通拖动把「阶段成就」区滚入视口；「当前连续 0 天」，3/7/30 都按已获得分支真实渲染且可见，不是只找到离屏语义节点或标题。 |
| `page.today-completion` | 在正式页面点开「读人练习」，选择一项、核对解析后点「完成今日练习」。页面显示「已打卡 · 连续 1 天」和 `1 / 4 已完成`，旧 3/7/30 仍在且没有弹出旧成就。 |
| `page.cold-reopen` | 用全新空目录的 `Sessions` 和全新 ProviderScope 冷重开同一账号，重新登录后仍读回「连续 1 天」、`1 / 4 已完成`、已完成的读人小练习和三个已达成成就；阶段区滚入视口后仍按已获得分支渲染。结果不来自第一个页面的加密缓存。 |
| `page.growth-cold-reopen` | 冷重开后再次通过底部导航打开正式成长档案，滚入「阶段成就」区核「当前连续 1 天」和 3/7/30 的已获得渲染；与断卡后首次打开的成长档案证据相互独立。 |
| `service.today-once` / `service.retained-after` | 生产导出确认历史 30 行逐字节未改写，今天只有一行计划且恰好一个已完成项（免费小练习），`completed_at` 已落盘。正式 `GET /v1/growth` 返回连续 `1` 天和 `[3,7,30]`，`GET /v1/plans/today` 只有一个已完成项。 |
| `journey` | 以上全部通过后才输出。 |

边界：历史 3/7/30 是数据库夹具，不是自然连续 30 天的真实使用记录；今天的一天由正式页面的真实免费完成产生。不推进系统时钟，不模拟真实午夜或跨时区，不覆盖越权、换号、健康、模型、支付或真机。账号时区选在距离当地午夜最远的位置，避免测试期间跨日。`3` 和 `7` 阶段由同一 30 天连续段覆盖，不另造两段历史。两页证据都从正式导航、正式仓储和真实渲染树取得，未新增产品标记、改色值或绕过路由。

## 终稿宿主复验（2026-11-24）

- **正式旅程已通过。** 宿主在独立的 PostgreSQL 17、缓存 Redis 和启用 AOF 的账本 Redis 上执行同一轮 `TestT27HistoryJourney`，覆盖上表的 100+1 条正式分页、缓存恢复、级联删除和删除前后画像接口。该轮同时输出 `PASS(page.journey)`、`PASS(service.delete-cascade)`、`PASS(service.contact-summary-before)`、`PASS(service.contact-summary-after)`、`PASS(journey)` 和 `RESULT: PASS`。
- **客户端恢复交互通过独立审查。** 原仓测在点击核对前超时，修正后独立复跑同一用例和断言，连续两次通过。正式 Flutter 组件使用合成传输与本地缓存。空列表重挂后仍能点「核对删除结果」，全程仅一次 DELETE，手工点击后才发出一次 summary GET，确认后联网刷新可重建离线缓存。定向回归还覆盖按操作独立标记、迟到回执不结清另一笔、同账号重进恢复待办及换号隔离。
- **宿主标准 Flutter 回执。** 单例 **1 通过**，定向 **103 通过、1 跳过**，全量 **513 通过、2 跳过**，`flutter analyze` 通过。较早宿主快照的定向 **97 通过、1 跳过**、全量 **507 通过、2 跳过** 和 Go 全量 race/vet 结果属于历史。实施归档的回环监听和只读工具链失败为过程记录。

正式旅程由 `JourneyStorage` 提供与产品对应的加密缓存、会话退役文件和账号级删除围栏，让初始与冷重开的 `Sessions` 共享同一 `MemorySecret`。产品先把删除意图写入本机 pending，再发送一次 DELETE。服务端确认后清理记录和缓存，随后在线刷新可重建缓存。

签核限于本卡自动化证据，丢回执和 `503` 均由测试注入。物理断网、真机、真实用户、系统安全存储和外部签收仍未验证。整个 T27 的验收范围见 [T27 任务文档](../../../docs/tasks/T27.md)。
