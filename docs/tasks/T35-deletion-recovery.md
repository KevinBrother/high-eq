# T35 首卡 · 关系人删除与恢复

交付范围是关系人专用删除、客户端回执核对和服务端恢复。T35 的统一隐私入口与整体验收另行交付。

## 客户端核对

- **普通删除。** 用户确认后，App 先按服务端、账号和关系人保存本机待核对记录，再发 `DELETE /v1/contacts/{id}`。本机记录保存失败时显示「删除未发送」。收到 `200` 且 `ok: true` 后，App 结清对应记录并清理成长缓存。服务端已确认而本机清理失败时，页面会单独提示缓存尚未清理。
- **回执丢失。** 断网或超时后保留待核对记录。联网后在「关系人」点「核对删除结果」，App 只用当前账号发 `GET /v1/contacts/{id}/summary` 核对该 ID。只有这个请求返回 `404 contact_not_found`，才确认该关系人在此账号下已不存在。任何 `403`、普通 `404 not_found`、`503`、鉴权失败或列表未见该关系人，都不足以确认删除。
- **未确认后的重试。** 只读核对得到有效 `200` 时，页面提供「重新删除」和「放弃重试」，两者都先重新核对。仍存在且用户再次确认删除时才发 DELETE。仍存在时放弃重试会结清本机记录并清理成长缓存。只要还有待核对记录，成长缓存就保持失效。全部结清后，可联网刷新成长档案以重建缓存。见 [T27 的连续删除与结果核对](T27.md#连续删除与结果核对)及 [App API 契约](../api/app.yaml)。

## 服务端恢复

- **公开 DELETE 屏障。** 会话和归属在账号锁内复核。有效会话仅可继续本账号同一关系人的精确待办，其他未完成源仍触发 `503 service_unavailable`（`retryable: true`）。已失效会话重试精确待办返回 `401`。无关账号仍可处理自己的数据，越权目标按普通 `404` 处理（请求方自身无屏障时）。
- **删除日志。** 先提交 PostgreSQL `pending_erasure` 根 ID，再写独立 AOF Redis 删除登记并清理关系人及级联数据。清理事务成功才移除待办，清理或提交失败后待办继续拦截访问，即使 Redis 墓碑已丢失。在线 DELETE 在清理阶段重新取账号锁，复核意图提交后出现的其他待办或独立子源墓碑。
- **运行中继续。** `cmd/api` 每分钟调用 `RetryPending`，推进已提交的 SQL 待办。原会话过期或撤销后仍可继续。一个根持续失败会保留其待办与屏障，本轮其余根仍可推进，下个周期再试。
- **启动拒绝。** 启动经 `Resume` 校验登记库并扫描现存根，处理 SQL 待办和登记命中的根。恢复失败时进程退出、不监听 HTTP。故障解除后重启，完成清理才开始监听。相关实现见 [删除协调器](../../server/internal/privacy/coordinator.go)、[恢复任务](../../server/internal/privacy/resume.go)和 [API 启动入口](../../server/cmd/api/main.go)。

## 宿主回执与复跑

评审交接记录的宿主环境为一次性 PostgreSQL 17、普通 Redis、独立 AOF Redis。以下六项为补充原 owner 成功重试断言前的宿主回执，均通过，无跳过。

| 用例 | 宿主回执与覆盖 |
| --- | --- |
| `TestContactDeletionPublicDeleteBarrier` | PASS（0.43s）。公开 DELETE 的精确待办、同账号其他源、跨账号隔离和失效会话。 |
| `TestContactDeletionProcessTicker` | PASS（120.33s）。同一真实 API 进程自然运行两轮分钟任务，过期和撤销会话的待办先恢复，持续失败根在解除故障后的下一轮恢复。 |
| `TestContactDeletionStartupFailClosed` | PASS（0.30s）。清理故障下重启不监听，移除故障后重启清理并开放监听。 |
| `TestOwnedDeletionJournalSurvivesTombstoneLoss` | PASS。登记墓碑丢失及清理提交失败后，SQL 待办仍拦截访问并支持恢复。 |
| `TestContactDeletionRechecksBarrierAfterIntentCommit` | PASS。意图提交后新增的独立子源待办或墓碑仍拦截在线清理。 |
| `TestT32AMarkLifecycle` | PASS。手动标记生命周期及关系人级联回归，见 [T32A](T32A.md)。 |

在宿主从仓库根目录运行下列命令。使用 Go 1.26，按 `server/internal/service/config.go` 显式设置测试环境的 `APP_ENV=development`、`DATABASE_URL`、`REDIS_URL`、`LEDGER_URL`（DB 0）、`FIELD_KEY_BASE64`（一次性测试密钥）及 `BACKUP_RETENTION_DAYS=45`。登记 Redis 使用 `appendonly yes`、`appendfsync always`、`maxmemory-policy noeviction`、`no-appendfsync-on-rewrite no`、`aof-load-truncated no`。

```bash
(
  set -e
  cd server
  t35_dir=$(mktemp -d)
  trap 'rm -rf "$t35_dir"' EXIT
  go build -o "$t35_dir/api" ./cmd/api
  T35_API_BIN="$t35_dir/api" go test -count=1 -timeout=5m -v \
    -tags 'integration process' \
    -run '^(TestContactDeletionPublicDeleteBarrier|TestContactDeletionProcessTicker|TestContactDeletionStartupFailClosed)$' \
    ./internal/service
  go test -count=1 -v -tags integration \
    -run '^(TestOwnedDeletionJournalSurvivesTombstoneLoss|TestContactDeletionRechecksBarrierAfterIntentCommit)$' \
    ./internal/privacy
  go test -count=1 -v -tags integration -run '^TestT32AMarkLifecycle$' ./internal/service
)
```

先运行进程组，让正式 `cmd/api` 启动时应用迁移并初始化登记绑定。单跑两项 `internal/privacy` 回归也要先让正式 API 启动成功。宿主直接跑空库时因缺少 `ledger_binding` 失败，完成 API 迁移后两项均实际通过。

[T04 server 工作流](../../.github/workflows/t04-server.yml)的新 `t35-process` job 运行 `bash server/tests/t35-process.sh`，要求三个进程用例逐项出现 PASS，有 SKIP 即失败。该 job 的线上回执待核验。

前次归档已静态核对 DELETE 回执、summary 专用 404 和两处可重试 503。完整 `scripts/check_contracts.py` 因缺少 PyYAML 未运行到断言。

## 原关系人成功重试交接

`TestContactDeletionPublicDeleteBarrier` 在同一 `cmd/api` 进程中保留首次及故障中精确重试的 `500`、其他源的 `503`、越权 `404`、无关账号删除成功和失效会话 `401`。原 owner 保持有效会话。合成触发器解除后，由该会话对同一 ID 重试公开 DELETE，要求首轮分钟任务前返回 `200` 和 `{"ok":true}`，且同一 summary 由故障前 `200`、待处理 `503` 变为 `404 contact_not_found`。用例同时核对关系人、SQL 待办及所附的一条手动标记和请求记录已经清理，独立 Redis 仍保留对应墓碑，两个账号的无关关系人均可读取。

**上一轮宿主已验。** 评审记录了原 owner 成功重试、同一 summary 返回专用 404、级联清理和无关关系人保留，以及三个进程用例的 PASS 回执。

```text
    privacy_delete_process_integration_test.go:573: original owner retry: DELETE 200 ok:true, summary 404 contact_not_found, cascade cleaned, unrelated contacts retained
--- PASS: TestContactDeletionPublicDeleteBarrier (0.55s)
--- PASS: TestContactDeletionProcessTicker (120.43s)
--- PASS: TestContactDeletionStartupFailClosed (0.66s)
```

**本归档已验。** Go 文件通过 `gofmt` 语法解析和格式检查，`bash -n server/tests/t35-process.sh` 通过。`lua server/tests/t35-ledger.lua server/internal/privacy/ledger_write.lua` 的离线登记规则回归通过。改动前后运行目标进程用例及改动后运行 `go test ./...`，均因本机 Go 1.22.6 低于 `go.mod` 要求的 1.26，在编译前停止。

**本轮新增断言待宿主复跑。** 在成功重试并核对 summary 后，原有效 owner 再用同一会话 DELETE 同一 ID，要求返回 `404` 和 `{"code":"not_found","message":"未找到这条记录","retryable":false}`。请用上节的一次性合成环境和命令复跑，收集新的 `--- PASS: TestContactDeletionPublicDeleteBarrier` 及下列日志。进程组不得出现 `--- SKIP:`。

```text
post-completion owner DELETE: 404 not_found, retryable:false
```

**仍待验。** 旧 schema 升级、T34 备份恢复后重删与登记副本完整性、物理真机与物理断网、真实用户、生产环境及外部签收。
