# 数据清单、副本与留存对表（草案）

> 状态：静态代码事实清单，不可直接作为正式数据清单或删除承诺。核对日期：2026-11-22。固定基线：`f60ace3`；候选证据：`ce479034bcba174475fa8fbc156be66a3b22ba5371b5344602f29394185d638a`（只标识早期 T33 草案，不是业务源码）。
>
> 已按主会话在 PG17 空库全量迁移后导出的 `verified-pg17-inventory.jsonl` 对固定基线 42 个 public 表/视图逐名核对（覆盖 42/42；本轮补入 7 个漏项）；后台员工表、平台配置、查询视图与普通用户数据分开列示，视图不计作物理副本。
> 真实结构以固定基线的 `server/migrations/` 为准。`bytea` 本身不等于加密；本清单中的“AES-GCM”只适用于明确标注 `*_enc` 且由 `server/internal/fieldcrypt/cipher.go` 封装写入的字段。日志、备份、供应商侧和平台侧留存不在本仓库可见范围内，不能据本清单宣称已全部删除。`[待运营填写]` `[待 T35 对表]`
> T25 后端增量新增三张表：D14 登记明确反馈，D39、D40 分别登记活动场景与推断请求。T23 后端增量新增 `review_requests` 与 `review_tombstones`，最终迁移为 `20261122120023_review_requests`，登记在 D23。固定基线 `f60ace3` 的 42 项逐名盘点不变，D37、D38、D23 及 T25 的 D14/D39/D40 均不计入这 42 项。本批后端实现不等于生产上线。T22 本机分享草稿 D37 仅依据已发布 `bc66e6e` 的三份原生代码登记；`reply_requests` 属于 T21 增量，不是 T23 复盘增量，T21 服务端仍未合入；不能把本机分享交接写成服务端原文不保存、删除闭环或供应商留存已完成。

## 1. 分类与关联原则

- **源记录**：用户直接产生或明确提交、能够独立删除的记录。
- **数值副本**：从源记录计算出的评分、成长分、基线、画像或计划；删除源后必须重算或清除，不能重新从旧事件生成。`[已知：docs/schema.md]`
- **关联元数据**：为幂等、删除防重放、额度、调用统计或安全保留的随机键、HMAC、时间和状态；不得借此恢复正文或重新绑定已删除源。`[已知]`
- **导出**：产品目标是按模块生成 JSON ZIP；固定基线通用 `GET /v1/me/export` 未接线并返回 `501 not_implemented`，客户端入口和覆盖范围待 T35。`[已知]` `[待 T35 对表]`
- **删除**：固定基线通用 `DELETE /v1/me/data/:kind/:id` 未接线并返回 `501 not_implemented`；注销冻结/撤销注销、健康窗口专用删除和删除协调器是另行核对的既有边界。`[已知]` `[待 T35 对表]`
- **位置**：本清单只描述仓库可见的服务器数据库/本机缓存/外部供应商边界；“境外”“境内”必须按真实部署、合同和平台后台核验。`[待运营填写]`

## 2. 逐项清单

| ID | 数据/功能 | 表、字段或位置 | 原始/副本/元数据 | 加密与访问边界 | 当前留存、删除和导出 | 同意用途/版本 | 状态 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| D01 | 账号、时区、年龄确认、注销请求 | `users.id`、`timezone`、`age_confirmed_at`、`closure_requested_at`、`app_account_token` | 账号源 | 内部账号 ID；不是密码；`app_account_token` 用于购买归属 | 至注销；冻结 15 天后按根清理；通用导出未接线 | `privacy`、`terms` / `2026-11` | `[已知]` `[待律师复核]` `[待 T35 对表]` |
| D02 | 登录标识 | `login_identities.subject_enc`、`subject_hmac`、`provider` | 源 + 检索元数据 | 归一化标识 AES-GCM；HMAC 用于唯一绑定；HMAC 不导出 | 随账号级联；通用导出未接线 | 首次隐私/协议 | `[已知]` `[待 T35 对表]` |
| D03 | 会话与刷新令牌 | `auth_sessions.refresh_hash`、`expires_at` | 认证元数据 | 只存随机刷新令牌 SHA-256，不存刷新明文 | 退出/轮换/冻结删除；过期清理；不导出认证材料 | 基础服务 | `[已知]` |
| D04 | 短信验证 | `sms_challenges.phone_hmac`、`otp_hash`、`sent_at`、`quota_day` | 注册前元数据 | 手机号和验证码摘要/HMAC；不存可读手机号或验证码 | 5 分钟可验证；成功/耗尽清验证码摘要；限流行 24 小时后回收；不导出 | 基础服务 | `[已知]` |
| D05 | 同意记录 | `consents.purpose`、`version`、`granted_at`、`withdrawn_at` | 授权历史 | 明文用途、版本和时间；仅本人或受权服务读取 | 至注销；撤回更新原行；新授权另开行；通用导出未接线 | 全部用途 | `[已知]`；版本校验有缺口 `[待 T35 对表]` |
| D06 | WLEIS 答卷与得分 | `assessments.instrument_version`、`answers_enc`、`scores_enc`、`completed_at` | 源 + 计算副本 | 答卷和得分分别 AES-GCM | 至删除测评或注销；删除源及待投递状态；通用导出未接线 | `assessment` / `2026-11` | `[已知]` `[待 T35 对表]` |
| D07 | 关系人手记与当前画像 | `contacts.profile_enc`、`last_used_at` | 源 + 当前画像副本 | 画像 AES-GCM；按 `(user_id,id)` 隔离；后端只接受通过校验的七个有界选项，并合并进当前画像，规范化选择不保存聊天原文或模型自由正文 | 至删除关系人或注销；删除关系人通过外键级联清理关联活动、观察、场景冻结、推断请求、标记、评分和副本；模块内部删除走协调器，不等于 T35 公共入口 | `contacts` / `2026-11`；选用已有摘要检查 `contacts` 和关系人使用权；仅导入聊天做推断时另需 `chat_import` | `[已知]` `[待 T35 对表]` |
| D08 | 本人画像 | `personal_profiles.profile_enc`、`updated_at` | 源/派生 | AES-GCM；与关系人当前画像分开，不混入关系人反馈或推断材料 | 至删除或注销；不得复制关系人原话；导出/删除仍待 T35 公共入口 | `contacts` 或对应画像用途 | `[已知]` `[待律师复核]` `[待 T35 对表]` |
| D09 | 对练、复盘、回复根活动 | `activities.content_enc`、`kind`、`state`、`source_id`、`contact_id` | 源根 + 关联 ID | 正文 AES-GCM；`source_id` 是随机清理键 | 随账号/关系人级联；通用单条删除和导出未接线；已接专用复盘删除；通用跨模块权利仍待 T35 验收 | 对练 `practice`；复盘 `review`；回复 `chat_import` | `[已知]`；候选模块另列 `[候选待对表]` |
| D10 | 对练逐轮消息 | `practice_messages.content_enc`、`role`、`seq`、`client_message_id` | 源明细 | 用户和 AI 双方发言均 AES-GCM | 随活动/关系人/账号级联；会话删除后不可由旧事件重建 | `practice` | `[已知]`；客户端授权写入与版本校验 `[候选待对表]` |
| D11 | 回复请求去重 | `reply_requests.input_mac`、`request_id` | 元数据 | 仅输入 HMAC，不存聊天原文 | 候选设计为随活动级联；固定基线不存在 `*reply_requests*` 迁移，不能按已实现写入 | `chat_import` / `2026-11` | `[候选待对表]` |
| D12 | 回复反馈 | `reply_feedback.outcome_enc`、`input_mac`、`occurred_at`、`pending` | 反馈源 + 元数据 | 结果 AES-GCM；输入仅 HMAC | 随回复活动级联；待投递状态可重试 | `chat_import` | `[候选待对表]`：非固定基线表；合入后复验字段、保留与实际清理 |
| D13 | 导入聊天原文 | `chat_imports.original_enc`、`received_at` | 源（关系人推断等路径） | AES-GCM；回复路径禁止写入属于候选/目标 | 设计目标 24 小时内删除；固定基线未找到自动清理函数、读取期限过滤、失败重试或导出排除的完整实现 | `chat_import` / `2026-11` | `[待实现/验收]` |
| D14 | 关系人/本人反馈画像观察 | `profile_observations.fact_enc`、`subject`、`applied`、`occurred_at` | 用户明确反馈形成的画像观察事实 | AES-GCM；`fact_enc` 是用户明确反馈形成的画像观察事实，不是模型推断正文；后端只接受通过校验的七个有界选项并写入 `contacts.profile_enc`，T25 推断链路不持久化聊天原文 | 随活动、信号事件或账号外键 `ON DELETE CASCADE`；删除关系人时相关活动及其反馈随源级联；通用导出/删除未接线 | 关联关系人时检查 `contacts` 与使用权；信号事件的本人确认另验 `health` 与 `voice` | `[已知：本批后端]` `[待 T35 对表]` |
| D15 | 对练/复盘评分明细 | `scores.detail_enc`、`occurred_at` | 派生源 | AES-GCM | 随活动/关系人/账号删除；导出未接线；删除源后不可回填 | `practice` / `review` | `[已知]` `[待 T35 对表]` |
| D16 | 成长数值副本 | `growth_scores.nvc_enc`、`emotion_enc`、`score_id`、`kind` | 数值副本 | AES-GCM；只存数值投影，不复制引文或理由 | 随源评分级联；删除源后重算或清除；导出未接线 | 随对应评分用途 | `[已知]` `[待 T35 对表]` |
| D17 | AI 调用统计 | `ai_calls` 的模型、任务、提示词版本、耗时、token、成本、状态、`operation_id`、`id`、`activity_id`、`score_id`、`contact_id` | 关联元数据 | 不保存输入/输出正文、评分理由或引文；密钥不入表 | 随活动/评分/关系人/账号级联；通用导出未接线；不导出密钥或提示词模板 | 随对应功能告知 | `[已知]` `[待 T35 对表]` |
| D18 | 健康 30 秒窗口 | `signal_windows.stats_enc`、`starts_at`、`channel` | 源/聚合 | AES-GCM；只接收 30 秒对齐窗口 | 180 天读取过滤和物理清理；健康窗口专用删除已接线；通用导出未接线 | `health` / `2026-11` | `[已知]` `[待 T35 对表]` |
| D19 | 健康/语音基线 | `signal_baselines.baseline_enc`、`signal`、`updated_at` | 派生副本 | AES-GCM | 删除源或账号时删除/重算；不延长聚合寿命 | `health` / `voice` | `[已知]`；语音 `[待 T29 对表]` |
| D20 | 自动事件/节奏记录 | `signal_events.event_enc`、`occurred_at`、`contact_id` | 源事件 | AES-GCM | 180 天清理；随关系人/账号删除；通用导出未接线 | `health` / `voice`；语音待 T29 | `[已知]`；T29 真机待验 |
| D21 | 手动标记 | `manual_marks.mark_enc`、`accepted_at`、`contact_id` | 源 | AES-GCM；不含音频/心率 | 180 天滚动；用户/关系人/账号提前删除；通用导出未接线 | `manual_mark` / `v1` | `[已知]`；客户端版本校验缺口 |
| D22 | 标记幂等映射 | `mark_requests.request_id`、`mark_id` | 元数据 | 账号内请求键到标记 ID；不跨用户合并 | 随标记/账号级联；不导出为独立数据 | `manual_mark` | `[已知]` |
| D23 | 文字复盘请求、短期生成检查点与删除墓碑 | `review_requests.activity_id`、`user_id`、`request_id`、`input_mac`、`scene_mac`、`mark_id`、`signal_event_id`、`repair_enc`、`generated_enc`、`generated_task`、`generated_call_id`、`generated_at`、`generated_expired`、`score_pending`；`review_tombstones.user_id`、`request_id`、`input_mac`、`deleted_at` | 请求幂等/来源关联元数据 + 短期生成检查点 + 删除防重放 | `input_mac`/`scene_mac` 为账号绑定 HMAC，不存正文；`repair_enc`（已审核修复短语）和 `generated_enc` 为 AES-GCM；只有成功落库且尚未过期的完整结果才能按原键复审。15 分钟从未审核输出 `generated_enc` 成功落库时起算；单独的已审核短语 `repair_enc` 不按此计时 | 生成期间可在专属列暂存检查点；完成时正文写入 `activities.content_enc`、评分写入 `scores.detail_enc`，清除阶段检查点并设置 `score_pending` 供事件投递。未审核输出超过 15 分钟不再恢复；下次检查或后台定期清扫成功后清空 `repair_enc`/`generated_enc`/`generated_task`/`generated_call_id`/`generated_at`，置 `generated_expired=true`，活动转 `failed` 并释放工作占位；原请求键不可恢复或重算。`mark_id`、`signal_event_id` 删除只 `ON DELETE SET NULL`，复盘保留；活动、关系人或账号删除经外键级联。删除复盘或关系人产生墓碑，账号注销清除墓碑；墓碑含账号、请求键、HMAC 及删除时间，不含正文或来源活动 ID，不导出。`reviews.json` 导出活动 ID、来源 ID、请求 ID、时间、状态、关系人/标记/信号关联、已批准修复短语和完成结果，不输出 `input_mac`/`scene_mac` 或未审核 `generated_enc`；通用 `/v1/me/export` 与 `/v1/me/data/:kind/:id` 仍为 `501 not_implemented` | `review` / `v1`；标记复盘预填是用户人工发起、本人参考，不自动绑定或提交 | T23 后端增量，不计入 `f60ace3` 的 42 项；本批后端实现不等于生产上线。T24 客户端回环、T32A 标记预填和隔离后端测试见交接；T35 公共权利入口仍待验。 |
| D24a | 每日计划 | `daily_plans.plan_enc`、`user_id` | 派生/源 | AES-GCM；只有用户外键，没有活动外键 | `daily_plans` 仅随账号删除；通用导出未接线 | 计划用途 | `[已知]` `[待 T35 对表]` |
| D24b | 单项训练进度 | `drill_progress.progress_enc`、`activity_id`、`kind` | 派生/源 | AES-GCM；`(activity_id,kind)` 指向单项活动 | `drill_progress` 随单项活动删除，并随账号清理；通用导出未接线 | 训练用途 | `[已知]` `[待 T35 对表]` |
| D25 | 支付订单与权益 | `orders`、`entitlements`、`payment_facts.checkout_enc`、`payment_notices`、`apple_purchase_chains` | 订单源 + 关联元数据 | 交易指纹/通知 HMAC；`checkout_enc` AES-GCM，五分钟复用 | 订单在注销后可脱敏保留 `user_id=NULL`；支付明细/通知随账号清理；不导出平台收据原文 | 支付平台规则 | `[已知]` `[待商户/平台确认]` |
| D26 | 额度与用量 | `quota_ledger.charged_day`、`daily_quota_usage.used` | 计量元数据 | 日汇总，不含消息或源 ID | 随账号/活动清理；用于额度重算；通用导出未接线 | 对应 AI 功能 | `[已知]` `[待 T35 对表]` |
| D27 | 删除协调与防重放 | `pending_erasure`、`erasure_roots` 视图、`ledger_binding`、Redis `deleted:<opaque_id>` | 清理元数据 | 仅随机根 UUID/安装身份；Redis 值为空，TTL 表达期限 | 成功后移除/过期；不导出；不能作为删除历史 | 基础安全 | `[已知：docs/schema.md]` `[待 T34 恢复验收]` |
| D28 | 平台模型密钥与准入证据 | `model_configs.api_key_enc`、`provider_admissions`、`prompt_versions`、`model_routes` | 运营/平台数据 | 平台 API key AES-GCM；准入条款证据为运营材料；不是用户个人导出分区 | 撤销准入时停用、解绑和删除凭据；历史调用统计可保留 | 非用户同意；供应商审核 | `[已知]` `[待运营填写]` |
| D29 | 本机续答/草稿/待发队列 | `app/lib/core/session.dart` 的私有 cache；`CacheKind.continuation/draft/queue` | 设备端源/队列 | 账号隔离；AES-GCM 密文；附加认证数据含用户、用途、ID；退出登录清理 | 由功能规则清理；T35 需验证换号、离线、重开和撤回 | 对应用途 | `[已知]` `[待 T35 对表]` |
| D30 | 本机录音保留 | `CacheKind.recording` 及过期基础设施；固定基线无麦克风权限/实际录音实现 | 设备端源（目标） | 目标为本机密文、账号隔离、3 天过期；**未实现/未验证** | 目标 3 天清理；杀进程、离线、重开、换号未验收 | `voice` + `audio_retention` | `[待 T29 对表]` `[待真机复核]` |
| D31 | 系统健康权限状态 | 固定基线 Android Manifest 仅声明 `INTERNET`；iOS 无 HealthKit entitlement、无 `NSHealthShareUsageDescription` | 系统权限元数据 | T28 候选拟申请运动识别和 Health Connect/HealthKit；基线未声明麦克风、相机或定位 | 系统权限由用户控制；App 内同意与系统权限分别撤回；候选接线与真机行为待验 | `health` | `[候选待对表]` `[待真机复核]` |
| D32 | 后台员工账号、会话与审计 | `admin_accounts.id`、`login`、`password_hash`、`role`；`admin_sessions.token_hash`、`admin_id`、`expires_at`；`admin_audit_logs.id`、`occurred_at`、`actor_id`、`action`、`target`、`result` | 后台员工数据（独立于 App 用户） | 口令仅保存 bcrypt 摘要；会话仅保存 32 字节随机令牌的 SHA-256 摘要；审计表结构未设登录名、口令、请求正文或 App 用户外键，`target` 文本的运营录入边界待定 | 后台账号由受信 CLI 管理；`admin_sessions` 随 `admin_accounts` 删除并清理过期会话；审计留存期待运营确定；`password_hash`、`token_hash` 和后台审计不进入 App 用户导出，也不随普通账号注销删除 | 非用户同意；后台权限与审计 | `[已知]` `[待运营填写]` `[待律师复核]` |
| D33 | 删除根兼容查询视图 | `erasure_roots_before_emotion.user_id`、`scope`、`root_id`、`parent_id`；`erasure_roots` 以其为基础 `UNION ALL` 健康窗口根 | 查询视图，不是物理副本 | 仅随机根/父根 UUID，不另存个人数据；供删除协调器解析既有级联根 | 视图无独立生命周期，内容随底层源行；`pending_erasure` 仅按 `root_id` 关联清理队列；视图本身不导出；恢复后重删待 T34 | 基础安全 | `[已知]` `[待 T34 恢复验收]` |
| D34 | 网关配置版本 | `gateway_revision.singleton`、`version` | 平台配置元数据 | 单行 UUID 版本；不含个人数据或密钥；`model_configs`、`provider_admissions`、`model_routes` 变更由迁移触发器在同一事务刷新版本 | 仅保留当前版本，不保留历史；平台配置不进入 App 用户导出或普通账号删除；撤销/变更按运营流程 | 非用户同意；平台配置 | `[已知]` `[待运营填写]` |
| D35 | 提示词发布指针 | `prompt_releases.task`、`model_id`、`model_kind`、`primary_version_id`、`experiment_version_id`、`experiment_percent` | 平台配置 | 只保存任务/模型到不可变提示词版本的发布指针和实验比例；不存个人分组或渲染结果 | 随平台配置维护；不进入 App 用户导出或普通账号删除；版本只追加，发布指针可原子切换/回滚 | 非用户同意；平台配置 | `[已知]` `[待运营填写]` |
| D36 | 额度尝试与恢复 | `quota_attempts.activity_id`、`token`、`state`、`held_day`、`valid_until`、`metered` | 普通账号/源结算元数据 | 内部工作令牌和状态，不含正文；`held_day` 是原时区自然日，`valid_until` 限定有效占位 | 随活动/账号级联；仅有效 `held`/`metered` 占位计入原日可用量，重连/重试按 `token` 和 `valid_until` 恢复或替换过期尝试；单条活动删除级联本行但不自动退回 `daily_quota_usage` 日汇总；T35 目标仅导出结算状态，不导出内部令牌 | 对应 AI 功能 | `[已知]` `[待 T35 对表]` |
| D37 | 提交分析前的本机分享草稿 | Android：`ReplyShare.pending`（当前 Activity 的一次性内存）；iOS：App Group `group.cn.higheq.highEq.reply` 下 `Library/Caches/T22/incoming` | 设备端临时源/交接副本 | 仅用户本人交接给主 App；Android 不写磁盘；iOS 使用 `.atomic` + `.completeFileProtection` 系统完整文件保护，不是业务 AES-GCM；分享扩展不联网、不读剪贴板、不要求登录 | Android 由系统分享把纯文本交给当前 Activity 内存，`take` 返回后立即清空，进程结束消失；iOS 在用户点“带入草稿”时原子写入，再次带入替换 `incoming`，主 App 启动、回到前台或收到可用通知时可先领取，领取不要求已登录；未登录时不显示正文，也可丢弃，登录后才可查看或编辑。领取时将 `incoming` 改名为 `claimed`，成功读取后删除。10 分钟仅用于拒领，App 未打开时不保证到点物理擦除，过期 `incoming` 留到下次领取/清理；未分析不上传；提交前不上传；只有开始分析并确认提交后才进入上传链路 | `chat_import`（提交分析时确认） | `[已知：bc66e6e]` `[待真机复核]` `[待 T35 对表]`；T21 服务端仍未合入 |
| D38 | 对练工作租约与结算补偿 | `practice_work.activity_id`、`used_tokens`、`worker`、`valid_until`、`action`、`client_id`、`completed_at`、`delivery_pending`、`settlement_pending`、`settlement_outcome` | 活动级关联元数据 | 不含正文；`worker` 是短期工作令牌，`valid_until` 限定 95 秒租约，`used_tokens` 上限 30000；`settlement_outcome` 只记录安全、审核不可用或失败等补偿状态 | `activity_id` 以 `REFERENCES activities ON DELETE CASCADE` 随单项活动删除；T19 清理钩子的核对范围是 `account`、`contacts`、`sessions`，并在删除后检查不再存在本人 `practice_work` 源；内部导出按每批 50 条输出会话、`setup` 和 `source_id`，`capped` 保留最后完整回复、丢弃未完成尾部，无完整回复时退款并禁止 finish；但通用 `/v1/me/export` 和 `/v1/me/data/:kind/:id` 仍为 `501 not_implemented`，T35 接线前不可由用户入口使用 | `practice`；T19 已接入 T25 画像摘要，选用关系人时额外检查 `contacts` | T19 后端增量（并与 T25 画像摘要协作），不计入 `f60ace3` 的 42 项；本批后端实现不等于生产上线。T20 首用授权与 T35 通用权利入口分开验收。 |
| D39 | 来源活动场景冻结 | `activity_profile_context.context_enc`、`user_id`、`activity_id` | 活动级场景副本 | AES-GCM，绑定账号和活动；冻结来源活动场景，包括已验证的 null，避免后续画像修改改写历史来源 | `(user_id,activity_id)` 主键和 `FOREIGN KEY ... ON DELETE CASCADE` 随活动/账号删除；`profiles.json` 可含 D14 反馈中的场景，不单列 D39 冻结行；内部模块能力不等于 T35 公共入口 | 仅回复或复盘的本人反馈冻结活动场景；对练读取摘要不写此表 | T25 后端增量，不计入 `f60ace3` 的 42 项；本批后端实现不等于生产上线。 |
| D40 | 关系人推理请求双同意与幂等 | `profile_inference_requests` 的 `request_id`、`contact_id`、`chat_consent_id`、`contacts_consent_id`、`input_digest`、`state` | 账号级幂等/授权元数据 | 同时绑定 `chat_consent_id` 和 `contacts_consent_id`；`input_digest` 为 32 字节 SHA-256，T25 推断链路不持久化聊天原文；状态仅 `processing`、`complete`、`invalidated`；模型尝试前和最终保存前复核精确同意 ID、摘要、状态与关系人可用性 | 处理中若检查到撤回/重授权或关系人已不可用，旧操作失效、不复活；同键更换材料或关系人返回 409，不改写原记录。完成后在当前仍有权限时重放只读当前画像，不重新外发；关系人、同意和账号删除均 `ON DELETE CASCADE`；提示词草稿 `b935fb60-5a85-4c12-82c0-401afd649325`；`profiles.json` 不输出 D40 请求、同意 ID 或输入摘要；模块内部删除不等于 T35 公共入口，通用 `/v1/me/export` 与 `/v1/me/data/:kind/:id` 仍为 `501 not_implemented` | `chat_import` + `contacts`；本批后端实现不等于生产上线。 | T25 后端增量，不计入 `f60ace3` 的 42 项。 |

## 3. 敏感字段加密核对

在固定基线迁移中可定位的密文信封列（字段级加密算法与读写路径另按各卡测试核验）：

`assessments.answers_enc`、`assessments.scores_enc`、`signal_windows.stats_enc`、`signal_baselines.baseline_enc`、`signal_events.event_enc`、`practice_messages.content_enc`、`scores.detail_enc`、`growth_scores.nvc_enc`、`growth_scores.emotion_enc`、`contacts.profile_enc`、`personal_profiles.profile_enc`、`manual_marks.mark_enc`、`activities.content_enc`、`daily_plans.plan_enc`、`drill_progress.progress_enc`、`payment_facts.checkout_enc`、`login_identities.subject_enc`、`model_configs.api_key_enc`、`[已知]`。`[已知：基线字段]`
T25 后端增量新增 `profile_observations.fact_enc` 和 `activity_profile_context.context_enc`，二者使用字段加密但不计入固定基线 `f60ace3` 的 42 项。T23 后端增量新增 `review_requests.repair_enc` 与 `review_requests.generated_enc`：前者保存已审核修复短语检查点，后者保存仅用于同请求重试的未审核生成结果，均由业务字段加密封装写入；成功保存后清除；审核故障可保留检查点用于恢复，过期清扫由维护任务或重试触发（不承诺到点即物理擦除）。两者不计入固定基线 42 项，本批后端实现不等于生产上线。T21 的 `reply_feedback.outcome_enc` 未随本 T23 归档复刻，不能写成已落库或已完成清理。`[已知：T23 本批后端]` `[T21 候选待对表]`

基线中的 `login_identities.subject_hmac`、`auth_sessions.refresh_hash`、`sms_challenges.phone_hmac`、`sms_challenges.otp_hash` 以及 `ai_calls` 的关联 ID 和计量字段不是加密正文。T23 的 `review_requests.input_mac`、`review_requests.scene_mac` 和 `review_tombstones.input_mac` 同为 HMAC 元数据，不是密文、正文或来源 ID；墓碑存在也不等于 T35 公共删除入口已接线。`[已知：T23 本批后端]` `[T21 的 reply_requests 候选待对表]`

## 4. 源、评分引用、数值副本与可关联日志链路

| 层级 | 固定基线字段/关系 | 含义与删除要求 |
| --- | --- | --- |
| 活动源 | `activities.source_id` | 随机清理键；删除活动后，关联评分、成长投影、调用统计和专项进度不得由旧事件回填。 |
| 评分源 | `scores.id = activities.source_id` | 评分记录通过该关系指回活动源；不是另造一个不可追踪的评分 ID。 |
| 评分明细 | `scores.detail_enc` | 引文、用户轮次、评分理由、改写和分项只在该 AES-GCM 密文中；不得复制到 `ai_calls` 或普通日志。 |
| 数值副本 | `growth_scores.score_id`、`nvc_enc`、`emotion_enc` | 只保存数值投影；随评分源级联，删除源后重算或清除。 |
| 业务操作 | `ai_calls.operation_id` | 串联同一次业务操作的主模型、备用模型和审核尝试；不能拿单次尝试 ID 代替业务操作。 |
| 单次尝试 | `ai_calls.id` | 区分主备/审核的每一次尝试，保留各自状态、耗时、token 和成本。 |
| 评分引用 | `ai_calls.score_id` | 仅成功评分尝试由 `LinkScoreTx` 补上评分引用；失败或审核尝试的 `ai_calls.score_id` 可为空，不得为它们补造评分引用。 |

删除与导出验收必须沿上述链路从 `activities` 追到 `scores`、`growth_scores` 和 `ai_calls`，同时保留 `ai_calls.operation_id` 与 `ai_calls.id` 的区别。`[待 T35 对表]`

## 5. 留存与删除证据等级

| 等级 | 本清单中的含义 |
| --- | --- |
| E1 代码可核对 | 有表、字段、触发器、删除钩子或读取过滤路径；例如健康 180 天、手动标记 180 天。 |
| E2 静态链路可核对 | 有删除协调器、专用删除路由或测试钩子，但没有通用客户端入口或完整端到端回执；不能据此宣称通用导出/删除已接线。 |
| E3 仅有产品目标 | 文案或任务卡写了期限，但没有实际执行路径或真机证据；例如录音 3 天、聊天原文 24 小时。 |
| E4 外部不可见 | 供应商、平台、备份、日志或基础设施侧留存；必须靠合同、后台或审计证据。 |

当前结论：**E3/E4 项不得写成“已自动删除”或“已闭环”。** 正式上线前至少应把敏感数据的 E3 提升到 E1/E2，并为 E4 建立供应商和平台证据编号。`[待运营填写]` `[待律师复核]`

## 6. 导出与删除验收清单

- [ ] 固定基线通用 `GET /v1/me/export` 当前返回 `501 not_implemented`；T35 必须接线后才能验证模块清单覆盖 D01–D40 中应导出的个人数据，并排除密钥、HMAC、平台收据原文和他人数据。D37、D38 及 T25 的 D14/D39/D40 均不计入 PG17 42 项，须另验设备端领取、场景冻结、双同意推理和实际清理边界。模块内部导出/删除不等于 T35 公共入口。`[待 T35 对表]`
- [ ] 固定基线通用 `DELETE /v1/me/data/:kind/:id` 当前返回 `501 not_implemented`；T35 接线后须能从源记录追到 `scores`、`growth_scores`、`ai_calls`、画像观察、计划和关联日志，并验证删除后重算不可回填。`[待 T35 对表]`
- [ ] 注销冻结、15 天冷静期、撤销注销、按根清理和支付订单脱敏，分别核对线上签收。T23 已有账号注销前后显式清理 `review_tombstones` 的触发器与隔离后端断言；T35 仍须验证公共删除/注销入口的实际回执和全链路证明，不能把内部测试写成生产闭环。`[待 T35 对表]`
- [ ] 健康窗口专用删除保持按账号、渠道和 30 秒起点定位，越权、相邻窗口和其他账号不受影响；该能力与通用单条删除分开验收。`[待 T35 对表]`
- [ ] `chat_imports` 在 24 小时后不可读、不可导出、不可由旧请求恢复；定时清理失败可重试并告警。`[待实现/验收]`
- [ ] T29 录音/语音特征、3 天清理、账号隔离、离线/杀进程和撤回行为有真机证据。`[待 T29 对表]` `[待真机复核]`
- [ ] 备份、Redis、日志、对象存储和供应商侧的留存/删除范围由运营和供应商证据确认。`[待运营填写]` `[待官方来源核验]`
