# T35 本人记录选删后端候选交接

## 发布范围

固定基线 `f60ace3` 的通用导出与单条删除均返回 `501 not_implemented`。在上一张[独立导出卡](T35-export-ios-handoff.md)上，ZIP 导出已接线，通用单条删除仍为 501。该卡保留 `TestPrivacyRightsHTTP/selected_record_delete_stays_unimplemented` 的历史断言和复验范围。[T33 发布核对](../compliance/qa.md#t35-候选发布核对)登记三个验收时点。

当前候选在账号删除屏障内分页定位本人记录。每项仅返回种类、静态标签、定位时间与公开删除键。`assessments`、`sessions`、`reviews`、`replies`、`contacts`、`manual_marks`、`signal_events` 使用公开 UUID，活动类记录的内部源由服务端解析。采集窗口以 `recorded_at` 和 `channel` 定位，使用 `DELETE /v1/signal-windows` 的 `starts_at` 和 `channel` 参数。通用删除在账号锁内复核会话、归属与种类，先持久化清理意图，再写独立账本并清理。屏障期间仅允许有效本人会话重试精确待办。当前候选尚未发布。

## 已验

- **此前宿主实库回执。** 评审记录前三项在新建 PG17、缓存 Redis 与独立 AOF Redis 上取得顶层 PASS，无跳过。对练用例在另一套同样独占的存储上取得顶层 PASS，无跳过。

  | 具名用例 | 既有实库覆盖 |
  | --- | --- |
  | `TestRecordLocatorListsOnlyOwnedPublicDeletionKeys` | 本人列表的分页、公开键与脱敏，拒绝越权和错种类，按 30 秒起点及渠道选删窗口并保留相邻窗口与其他账号记录 |
  | `TestSelectedRecordDeleteRetriesOnlyExactPendingRoot` | 屏障期间拒绝列表及同账号其他删除，只有有效本人会话可完成精确待办，其他记录继续可读 |
  | `TestDeletionReplayWindowWithinAndExpired` | 删除复盘或注销后检查物理行、成长参考和导出。恢复合成源行后，未过期投递被独立墓碑拦截，墓碑模拟过期后超出 30 天的投递仍被拒绝 |
  | `TestSamePracticeRightsWire` | 对练公开活动 ID 与内部源有别。删除验证消息、带引用评分、成长数值副本和关联 AI 调用清理，训练参考重算，保留同账号另一场和其他账号记录 |

- **当前归档静态回归。** 修订前合规套件共 82 项，其中两项沿用独立导出候选的 501 预期并失败。新增的三时点证据回归也先复现缺少候选区分。修订后 `python3 -B -m unittest discover -s docs/compliance` 通过 83 项，固定基线仍从 Git 中核对，并保留 42 项历史清单。离线反例分别移除独立导出证据、移除列表路由门禁接线及恢复选删的 OpenAPI 501，三种改动均被断言拒绝。
- **当前归档 Go 离线检查。** Go 1.26 的 service、recordlocator 和 privacy 非集成 race 测试通过。service 通过 `integration process` 标记下的 `go vet`，带 race 的集成二进制编译成功，可枚举下列命令选中的五项顶层用例。

## 未验及宿主复跑

当前归档新增 `TestPrivacyRightsHTTP/selected_record_delete_removes_only_the_listed_owned_mark`。A 有两条关联同一关系人和场景的合成标记，B 有一条自己的标记。目标 UUID 来自 A 的列表第二项，并与创建回执独立核对。匿名及已撤销会话的删除返回 401，直接调用删除处理器也拒绝已撤销会话。两个方向的越权与错种类返回和未知 UUID 相同的不可重试 404。被拒后，两人的列表、ZIP、SQL 源行和请求映射保持原状，三个标记均无删除账本项。本人选删成功后，只有目标从列表、实际 ZIP 和 SQL 消失，独立 AOF 账本只有目标新增带 TTL 的墓碑。同组与他人标记仍可读、可导出。重复删除返回 404，使用原标记请求键重新提交返回 409。父用例继续核对导出脱敏、删除屏障、专用标记删除以及冻结和撤销注销。

该新增路径需要宿主实库回执。使用 Go 1.26、各自独占的空 PG17、缓存 Redis 和独立 AOF Redis，按[隐私账号卡宿主配置](T35-privacy-profile-closure.md#宿主复验)提供 development 合成身份、临时字段密钥与禁用支付配置。对练另用一套空存储，夹具要求 `T19_DISPOSABLE=yes`、空模型路由表及可绑定回环端口的本机受控模型夹具。以下命令从仓库根运行。复验确认五个顶层用例和新增具名子例均有 PASS、无 SKIP，三条命令均退出 0。

```sh
go -C server test -race -tags integration -count=1 -v \
  -run '^TestPrivacyRightsHTTP$' ./internal/service

go -C server test -race -tags integration -count=1 -v \
  -run '^(TestRecordLocatorListsOnlyOwnedPublicDeletionKeys|TestSelectedRecordDeleteRetriesOnlyExactPendingRoot|TestDeletionReplayWindowWithinAndExpired)$' \
  ./internal/service

T19_DISPOSABLE=yes go -C server test -race -tags integration -count=1 -v \
  -run '^TestSamePracticeRightsWire$' ./internal/service
```

完整 OpenAPI 检查须准备 `scripts/contract-requirements.txt` 中的依赖，再运行 `python3 -B scripts/check_contracts.py`。当前归档缺少 `openapi_schema_validator`。Flutter 选删及正式全链路、生产签收、真机、物理清除与 T34 恢复后重删由各自卡验收。
