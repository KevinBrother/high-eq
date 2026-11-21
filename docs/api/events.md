# 单体内的数据事件与钩子（v1）

这里约定模块之间的交接，不是 App SSE，也不开放 HTTP 发布入口。ID 均为不透明 UUID，时间为带偏移的 RFC 3339。发布方在源操作成功提交后才交付事实；可重复投递，不承诺全局顺序。失败、危机、审核故障均不是评分完成。请求体、引文、评分理由、录音、逐条读数及模型输出不得随事件广播或进日志。

| 名称 | 发布 → 订阅 | v1 载荷与处理键 |
| --- | --- | --- |
| `assessment.completed` | T08 → T26 | `user_id, assessment_id, occurred_at`。按 assessment_id 去重；从仍属该用户的测评读数生成计划，免费计划不读画像。 |
| `score.completed` | T19（整场）、T23（完整复盘）→ T26 | 下例为完整字段。`activity_id` 为会话/请求 ID，`source_id` 为活动建立时服务端已预分配且永不复用的 `activities.source_id = scores.id`；不是投递 ID。`kind` 仅 `practice/review`。不得有单项成绩、文本或评分解释。 |
| `drill.progressed` | T19 → T26 | `user_id, activity_id, level_id, occurred_at, target_item, score`。按活动去重；仅调度单项目标（25 过关、10–24 三天后重练、0–9 当场再试），不写成长评分副本。 |
| `profile.feedback` | T21（建议使用及效果）、T23（复盘反馈）、T30（本人核对）→ T25 | `feedback_id, user_id, source_id, source_kind, subject, contact_id?, occurred_at`。source_kind 为 `reply/review/self_event`，subject 为 `contact/self`。按 feedback_id 去重；在源模块内按所属账号读取必要反馈，不复制聊天/复盘。只读关系人拒绝写入；T30 只转本人明确核对，区分肯定与否定；未核对、对话节奏与单纯手动标记不自动更新画像。 |
| `data.delete`（必须完成的钩子） | T04 协调；T05 冻结期满 / T35 单源删除及相关模块 → 所有持有源数据、衍生数据或关联日志的模块 | `operation_id, user_id, scope, source_id?`。scope 为 `account` 或源类别；单源须传不透明清理 ID，恢复/注销按 schema 的 purge_id、source_id 等逐一登记。按 operation_id/源幂等，不是发出通知即算删除完成。 |
| `data.export`（按请求执行的钩子） | T35 → T04 协调 → 各数据模块 | `operation_id, user_id`。钩子流式写入本账号命名的 JSON 分区，由协调器输出 ZIP；遍历仍存在的源、副本、手动标记及可关联调用记录。任一必需模块失败不是成功导出。不上传本地录音，不导出平台密钥或删除登记。 |

`score.completed` 示例：

```json
{
  "user_id": "c314cf45-e598-4e37-83de-b9a1c74e3aa7",
  "activity_id": "55c0311e-fca7-4489-b812-20fab79ba613",
  "source_id": "51cefba2-17dc-44e3-9843-e8cbc58d2600",
  "kind": "practice",
  "occurred_at": "2026-11-21T09:00:00+08:00",
  "nvc": {"observation": 25, "feeling": 25, "need": 10, "request": 0, "total": 60},
  "emotion": {"read_others": 3, "self_management": 4, "relationship": 3}
}
```

**消费与删除的竞态**：`occurred_at` 取源评分的原始发生时间，重投不刷新。T26 在 30 天重放期内以 `source_id` 去重，按 T02 的账号→源锁序与删除协调；拒绝过期、命中删除登记、账号/源不存在或归属不符的事件，以现存源为准，不重建源或账号。删除先登记、后清源与副本并重算，独立登记的业务数据仅是不透明源 ID，TTL 不短于 `max(30 天, 最长可恢复备份期)`；失败保持不可读、不可导出且不可消费。恢复后先重新删除再开放。详细边界见 [schema](../schema.md#写入与清理协议后续服务必须实现) 和[隐私清单](../standards/privacy.md)。
