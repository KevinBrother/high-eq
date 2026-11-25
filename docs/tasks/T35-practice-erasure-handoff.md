# T35 对练删除返修交接

删除完整对练或单项练习时，PG 在源行删除事务内保留账号绑定的创建键摘要。原创建请求返回不可重试的 409。摘要不含原始 UUID、正文或评分，随账号清除，也不进入 ZIP。独立 AOF Redis 的评分源墓碑仍由原删除协调器写入。

每日计划的密文新增条目完成来源和手动完成时间。删除撤回该练习的贡献并在同一事务中更新条目和打卡。有其他有效来源时保留完成状态。若原打卡时间来自被删练习，则改用最早的可证实存活完成。测评、计划内容、仍有效的评分和每日扣次继续按原规则保留。重复练习的详情和 `training.json` 共用前序存活检查，创建幂等比较仍使用原始设置。

旧计划没有逐条归因。删除遇到这种计划时，用当前账号时区下同日的已投递正本和旧首次完成时间匹配；已手动完成的旧计划能保留打卡日，来源不明的原时间可为空。改过时区且没有匹配首次完成时间的旧记录无法保证精确归因。迁移前已物理删除、且未留创建键的活动无法补记摘要。

## 当前归档验证

- **已验**。修复前使用归档源码中的 SQL 在 SQLite 复现旧创建重建公开 ID、删除后计划仍计打卡。在 Go 导出构造中核对到原始前序 ID 直接序列化。离线探针和失败输出在 `../tmp/practice-erasure-red.py` 和 `../tmp/practice-erasure-red.log`。
- **已验**。成长、对练、隐私和服务的 Go 单元测试，以及 83 项合规测试。新增离线回归覆盖同关卡多来源、其他关卡和手动完成的保留。具名实库回归通过带集成标签的编译。
- **待宿主验**。本归档没有隔离的 PG17 和两套 Redis，未执行公开 API 的实库断言，也未在 PG17 应用本次迁移。旧宿主的 `TestSamePracticeRightsWire` PASS 只覆盖修复前既有用例。

## 宿主复验

每条命令使用各自空的、一次性 PG17 库和两套独立 Redis，其中删除账本需要 Redis 8.2 AOF。按 [隐私账号卡宿主说明](T35-privacy-profile-closure.md#宿主复验) 显式注入合成配置。服务测试需要空模型路由表以及 API 和受控上游使用的回环监听端口。从归档根目录执行以下命令。

```sh
T19_DISPOSABLE=yes go -C server test -race -tags integration -count=1 -timeout=4m -v \
  -run '^TestPracticeErasureRemovesOnlyItsPlanContribution$' ./internal/service

T19_DISPOSABLE=yes go -C server test -race -tags integration -count=1 -timeout=4m -v \
  -run '^TestSamePracticeRightsWire$' ./internal/service

migrate -path server/migrations -database "$DATABASE_URL" up
go -C server test -race -tags integration -count=1 -timeout=4m -v \
  -run '^(TestOutOfOrderDrillCompletesOriginalDayWithoutReopeningSchedule|TestCompletePlanItemIsIdempotentAndConcurrent|TestDeletedDrillCannotRebuildScheduleOnReplay|TestReferenceRecalculatesAndDeletionCannotBeReplayed)$' \
  ./internal/growth
```

要求命令退出 0，上述顶层用例均为 `PASS`，无 `SKIP`。新公开用例的 `sole_source`、`same_level_repeat`、`single_skill_and_manual_completion` 各验证原创建响应、计划与打卡、重练详情和实际 ZIP。旧公开用例继续验证消息、带引用的完整评分、成长数值、AI 调用清除和评分投递重放。
