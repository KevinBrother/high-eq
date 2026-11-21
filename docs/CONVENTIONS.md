# 工程约定

产品范围直接读[决策摘要](DECISIONS.md)，验收以[任务卡](tasks.md)及其引用的标准为准。

## 工具与位置

| 工作 | 工具基线与职责 |
| --- | --- |
| `app/`、`admin/` | Flutter 3.38 / Dart 3.10 起；两端采用同一 Flutter SDK 与 flutter_riverpod 3。依赖用 `flutter pub`，提交各应用的 `pubspec.lock`；若引入 JS 工具链只用 pnpm。 |
| `server/` | Go 1.26、Gin v1、oapi-codegen v2、pgx v5、go-redis v9；入口 `cmd/api/`，业务 `internal/<module>/`，生成文件 `internal/api/{app,admin}/` 禁止手改。T04 在 go.mod/go.sum 中锁定补丁版本。 |
| `server/migrations/` | PostgreSQL 17、golang-migrate v4；`YYYYMMDDHHMMSS_name.up.sql` + 对应 `.down.sql`，已分发迁移只增不改。Redis 8 用于缓存、配额、通知；不作为账单事实来源。 |
| `watch/` | Swift 6；T36 记录实际 Xcode、iOS、watchOS 和设备型号，测试 target 与生产隔离。 |
| `docs/` | T03 起 `api/app.yaml`、`api/admin.yaml` 是两套唯一对外契约（OpenAPI 3.0.3）；`schema.md` 随迁移更新。每卡提交一份 `tasks/Txx.md`。 |

## 命名与接口

- Go 包名小写单词，导出标识 PascalCase；Dart 文件名 `snake_case.dart`、类型 UpperCamelCase。SQL 表用复数 snake_case，外键 `<entity>_id`；时间列 `*_at` 用 `timestamptz`，API 传 RFC 3339 含偏移时间。
- 外部资源用不透明 UUID，路径 `/v1/<复数资源>`，后台 `/admin/v1/...`；JSON 字段 snake_case。列表以 `items`、可空 `next_cursor` 返回，按稳定排序键分页。
- 鉴权从服务端令牌取用户，不采信请求里的账号 ID。`session_id` 标一场、`client_message_id` 标一条用户发言、`request_id` 标一次助手/复盘操作；断线重发沿用原 ID。
- 技术错误统一 `{ "code": "moderation_unavailable", "message": "服务暂不可用，可重试", "retryable": true }`。400 `invalid_argument`、401 `unauthenticated`、403 `forbidden`、404 `not_found`、409 `conflict`、429 `quota_exceeded`、503 `moderation_unavailable`、500 `internal_error`；交互只展示可读消息，不展示堆栈。SSE 同名审核故障事件和 `safety` 互斥，非流式危机按任务卡返回 `{safety:true,message}`。

## 网关与数据

| T10 常量（配置、枚举和统计均用右列值） | 值 |
| --- | --- |
| 角色扮演 / 回复建议 | `role_play` / `reply_suggestion` |
| 评分 / 画像推断 | `scoring` / `profile_inference` |
| 复盘分析 / 内容生成 / 简单分类 | `review_analysis` / `content_generation` / `classification` |

- 业务只传任务名，不选模型。日志使用字段白名单：请求/调用关联 ID、模块、任务、模型及版本、耗时、token、成本、结果码。禁记请求体、提示词、语音、评分理由、密钥、手机号或第三方身份；关联日志纳入源数据删除与导出。
- `*_enc` 是服务端 AES-GCM 密文信封（密钥版本、随机 nonce、密文及 tag），不按密文检索。开发密钥由环境注入，生产走 KMS。按账号与源 ID 查找/删除；见[隐私清单](standards/privacy.md)。

## 提交与交接

- 默认在当前工作目录改动；按根目录 `AGENTS.md`，每张已验收的任务卡单独 commit，未明确要求不 push。需要 worktree 时按仓库规则建在项目根目录，使用 `feat/<name>` 或 `fix/<name>`；提交标题如 `feat(assessment): 增加四维计分`。
- 交接固定四项：**范围和入口 / 验证命令及实际结果 / 未验证条件 / 下一任务及注意事项**。跨模块契约问题登记 [CHANGES](CHANGES.md) 并指定负责卡；真机、商户和审核证据不可由模拟替代。
