# T27 成长档案与关系人删除验收

从仓库根目录运行。需要已安装的 Go 1.26、缓存完整的项目 Flutter SDK 和锁定依赖、本机 PostgreSQL 17 与支持 AOF 的 Redis。Go 模块须已在默认缓存或 `GOMODCACHE` 中。App 的 `app/.dart_tool/package_config.json` 和 `package_graph.json` 须由已准备好的 Flutter SDK 使用锁定依赖生成。

```sh
python3 app/tool/t27/history_journey.py \
  --pg-bin /path/to/postgresql-17/bin \
  --redis /path/to/redis-server \
  --flutter /path/to/flutter/bin/flutter \
  --go /path/to/go/bin/go
```

`--flutter` 和 `--go` 缺省时从 PATH 解析。启动器在三个随机回环端口启动全新的 PG17、普通 Redis 和独立 AOF Redis，复跑正式服务路由和 Flutter widget 用例，退出后停止进程、清除临时数据。仅使用合成账号、一次性登录票据和本地脚本化的评分/审核供应商。Flutter 用已缓存的工具和依赖，Go 模块代理关闭。脚本不需要 Docker、已启动的服务、`.env` 或账号凭据。它验证正式 Flutter 页面交互，无需真机。

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

每次运行的日志在 `build/t27-history/run-*/`。服务启动、播种、HTTP 请求、UI 等待及整个进程均有截止时间。`journey.log` 保留 `BEGIN(...)`、`PASS(...)`、`FAIL(...)` 和请求计数。退出码 `0` 表示整链通过，`1` 表示进入用例后的断言失败或超时，`2` 表示前置条件不足或工具未能启动用例。核对本卡终稿时，从同一轮日志确认下方所列各阶段回执和 `RESULT: PASS`。

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

## 终稿宿主复验（2026-11-24）

- **正式旅程已通过。** 宿主在独立的 PostgreSQL 17、缓存 Redis 和启用 AOF 的账本 Redis 上执行同一轮 `TestT27HistoryJourney`，覆盖上表的 100+1 条正式分页、缓存恢复、级联删除和删除前后画像接口。该轮同时输出 `PASS(page.journey)`、`PASS(service.delete-cascade)`、`PASS(service.contact-summary-before)`、`PASS(service.contact-summary-after)`、`PASS(journey)` 和 `RESULT: PASS`。
- **客户端恢复交互通过独立审查。** 原仓测在点击核对前超时，修正后独立复跑同一用例和断言，连续两次通过。正式 Flutter 组件使用合成传输与本地缓存。空列表重挂后仍能点「核对删除结果」，全程仅一次 DELETE，手工点击后才发出一次 summary GET，确认后联网刷新可重建离线缓存。定向回归还覆盖按操作独立标记、迟到回执不结清另一笔、同账号重进恢复待办及换号隔离。
- **宿主标准 Flutter 回执。** 单例 **1 通过**，定向 **103 通过、1 跳过**，全量 **513 通过、2 跳过**，`flutter analyze` 通过。较早宿主快照的定向 **97 通过、1 跳过**、全量 **507 通过、2 跳过** 和 Go 全量 race/vet 结果属于历史。实施归档的回环监听和只读工具链失败为过程记录。

正式旅程由 `JourneyStorage` 提供与产品对应的加密缓存、会话退役文件和账号级删除围栏，让初始与冷重开的 `Sessions` 共享同一 `MemorySecret`。产品先把删除意图写入本机 pending，再发送一次 DELETE。服务端确认后清理记录和缓存，随后在线刷新可重建缓存。

签核限于本卡自动化证据，丢回执和 `503` 均由测试注入。物理断网、真机、真实用户、系统安全存储和外部签收仍未验证。整个 T27 的验收范围见 [T27 任务文档](../../../docs/tasks/T27.md)。
