# T33 隐私与合规 QA（草案）

> 核对日期：2026-11-23。固定基线：`f60ace3`；候选证据：`ce479034bcba174475fa8fbc156be66a3b22ba5371b5344602f29394185d638a`（只标识早期 T33 草案，不是业务源码）。本文记录静态代码、文档和交接核对结果，不是法律意见，也不代表任何待办已由运营、平台、真机或律师完成。
>
> 结论：**未达到发布门槛。** 已完成的只是可先行材料、静态事实对表和隔离/合装回归证据；运营资料、供应商证据、T29 真机/抓包/耗电与平台材料、T35、完整法律适用性和律师意见仍为阻断项。T29 归档静态实现、未合入固定基线、真机待验；T28 健康历史已做静态与本次合装回归回执登记（QA-36），同源码 analyze 和回归已绿，但完整 APK、三台真机、真实健康库、Huawei 批准/签名/HMS、耗电、实际延迟和固定 SHA CI 仍未签。

## 1. QA 状态说明

| 状态 | 含义 |
| --- | --- |
| `通过（静态）` | 固定基线或已明确标注的候选材料中能找到对应字段、接口、测试或文档；不代表真实环境已验收。 |
| `通过（隔离后端）` | 已在归档源码的隔离 PG/Redis/受控上游回环找到通过记录；不代表生产、真实供应商、真机或真人已验收。 |
| `部分通过` | 有一部分实现或证据，但存在明确缺口。 |
| `未通过` | 当前材料与实现不一致，或关键闭环缺失。 |
| `阻断` | 上线前必须有外部资料、真机、平台、T29/T35 或律师证据才能关闭。 |

## 2. 逐项 QA

各模块 QA 行保留对应交付时点的接口状态。通用导出与选删的后续变化见 [T35 候选发布核对](#t35-候选发布核对)。

| ID | 检查项 | 证据路径 | 当前结果 | 状态 | 上线门槛/负责人 |
| --- | --- | --- | --- | --- | --- |
| QA-01 | 官方法规/平台入口是否取得一手正文、版本和日期 | `docs/compliance/official-source-register.md` | 已读取 PIPL、生成式 AI 办法、Apple 审核指南、Android Health Connect 和 MIIT 同文政策库的部分官方正文；已登记 URL 与两份正文哈希。其他来源、版本日期和业务适用性仍待补 | `部分通过` | 运营/律师补齐正文、抓取日期、证据编号和适用性意见 |
| QA-02 | 是否虚构公司名称、地址、联系方式、投诉渠道 | `docs/compliance/privacy-policy-draft.md`、`terms-of-service-draft.md` | 全部保留 `[待运营填写]`，未发现虚构主体或联系方式 | `通过（静态）` | 运营提供营业执照、地址、负责人和可达渠道 |
| QA-03 | 是否虚构商户、模型条款、授权函、备案或批准 | `docs/compliance/sdk-model-review-checklist.md`、`filings-and-authorizations.md` | 供应商、合同、WLEIS 授权、备案号和批准均未填写；只记录“待提供” | `通过（静态）` | 运营归档合同、授权函、后台回执和审批单；律师复核范围 |
| QA-04 | 数据清单是否覆盖 schema 的源记录、数值副本、关联元数据和导出/删除 | `docs/compliance/data-inventory.md`、`docs/schema.md`、`server/migrations/`、`verified-pg17-inventory.jsonl` | 依据主会话 PG17 空库全量迁移后的清单，D01–D45 已登记；其中 D01–D36 中除 D11/D12/D14/D23 外的基线条目逐名覆盖 `f60ace3` 的 42/42 public 表/视图，D32–D36 单列后台缺口。D37 为设备交接，D38 为 T19 工作状态，D14/D39/D40 对应 T25 新表，D41/D42 对应 T21 回复防重放键和最小回执，D43 对应 T26 单项复习调度投影，D44 对应 T29 本机语音队列、录音索引和 PCM，D45 对应 T28 本机健康历史待发状态与撤回意图，D37–D45 均不计入 PG17 42 项；视图不另存个人数据，后台口令/会话摘要、平台配置和内部令牌不进入 App 用户导出 | `通过（静态）` | T35 按同一清单跑导出→删除→再导出，并另验 D37 领取/过期清理；真实数据库完整测试由主会话执行 |
| QA-05 | 加密字段是否与迁移和 `fieldcrypt` 对齐 | `docs/compliance/data-inventory.md` 第 3 节、`server/internal/fieldcrypt/cipher.go` | 已列出 `*_enc` AES-GCM 字段；HMAC/摘要未误写为密文 | `通过（静态）` | 代码变更时重新扫描；密钥管理和备份由 T34 复核 |
| QA-06 | 同意 purpose 是否与 API/服务端枚举一致 | `docs/compliance/separate-consents.md`、`server/internal/accounts/consents.go`、`server/internal/api/app/routes.gen.go` | `privacy`、`terms`、`assessment`、`health`、`voice`、`audio_retention`、`practice`、`review`、`contacts`、`chat_import`、`manual_mark` 已对表 | `通过（静态）` | 正式版本和页面文案仍需运营/律师确认 |
| QA-07 | `privacy`/`terms` 是否强制开发占位版本 | `server/internal/accounts/accounts.go`、`app/lib/features/onboarding/repository.dart` | 服务端要求 `PolicyVersion=2026-11`；客户端 onboarding 写入同版本 | `通过（静态）` | 发布前替换正式版本、生效日期和通知流程 |
| QA-08 | 各敏感用途是否校验当前同意版本 | `server/internal/accounts/consents.go`、`separate-consents.md` 第 4 节 | `Granted` 只检查未撤回；除 `privacy`/`terms` 外版本非空即可 | `未通过` | 修复版本闭环并补端到端测试；产品/后端负责人 |
| QA-09 | 对练前是否写入 `practice` 单独同意 | `app/lib/features/practice/lobby.dart`、`server/internal/training/store.go` | T20 在启动、恢复创建及重练前读服务端状态；无授权须明确确认后写入并复读，旧本地告知无效。Widget 验证确认/拒绝；`app/tool/t20/live.sh` 使用无预授权合成账号验证服务端授权读写及无权创建返回 403 | `通过（隔离客户端与后端）` | 当前用途版本匹配、真机首用和撤回仍待验（见 QA-30） |
| QA-10 | 手动标记客户端是否核对同意版本 | `app/lib/features/marks/book.dart`、`server/internal/marks/store.go` | 客户端设置 `v1` 但只检查 `granted == true`；服务端接受非空版本 | `部分通过` | 补版本校验和撤回后停写测试 |
| QA-11 | 聊天原文 24 小时删除是否闭环 | `server/migrations/20261121000200_training.up.sql`、`docs/schema.md`、`app/lib/features/replies/page.dart` | `chat_imports.original_enc`/`received_at` 仍存在；未找到自动清理函数、24 小时读取过滤、失败重试或导出排除完整证据 | `未通过` | 实现并验收读取过滤、物理清理、重试、告警和导出排除 |
| QA-12 | 回复原文不落库、关系人推断和 T21 回复增量是否可写成基线事实 | `server/internal/training/`、`server/internal/profile/`、`server/internal/replies/`、`server/migrations/2026112300002{1,2,3}_*.sql` | `f60ace3` 的 42 项盘点不含 T19/T25/T21 增量。T19/T25 保持本批后端事实：反馈观察写入 `profile_observations.fact_enc`，T25 推断链路不持久化聊天原文。T21 已接线 `POST /v1/replies` 与 `POST /v1/replies/:id/feedback`，服务端不持久化源文本与目的；结果与反馈使用 AES-GCM，输入指纹为 32 字节带密钥 HMAC，另存授权及请求关联元数据；`reply_import_guard` 阻止回复路径写 `chat_imports`。效果反馈正文加密保存，另有仅用于非画像消费的最小回执，只有显式 `self_report` 进入本人画像观察；删除后 `reply_request_keys.activity_id` 为 `ON DELETE SET NULL`，保留 HMAC 防重放。以上均不计入固定 42 项 | `通过（静态）` | 真实厂商、日志、备份、生产发布和删除签收仍待证据；T35 公共导出/删除未接线 |
| QA-13 | 聊天原文 24 小时删除文案是否有实现证据 | `app/lib/features/replies/page.dart`、数据清单 D13 | 页面目标存在，但自动清理、读取过滤和供应商证据未闭环 | `未通过` | 在实现和供应商证据齐全前删除或降级文案 |
| QA-14 | 设备健康权限是否被误写成基线已声明 | `app/android/app/src/main/AndroidManifest.xml`、`app/ios/Runner/Info.plist`、`Runner.entitlements` | 固定基线 Android Manifest 仅声明 `INTERNET`，iOS 没有 HealthKit entitlement 或 `NSHealthShareUsageDescription`。当前 T28 归档静态实现另有 Android `ACTIVITY_RECOGNITION`、`health.READ_HEART_RATE`、`health.READ_HEART_RATE_VARIABILITY`、`health.READ_STEPS`、`health.READ_EXERCISE`（无健康写入）及 iOS `NSHealthShareUsageDescription`、HealthKit entitlement（无更新用途）；T28 归档未合入固定基线 | `通过（静态）` | 以 `f60ace3` 为基线不混淆；T28 合入后按 Manifest/Info.plist/entitlements、真机和平台审批重新验收 |
| QA-15 | 健康窗口删除、读取过滤和 180 天清理是否有静态证据 | `server/internal/emotion/privacy.go`、`window.go`、`reference.go` | 健康窗口专用删除按账号、渠道和 30 秒起点定位；180 天读取过滤与物理清理有测试覆盖 | `通过（静态）` | T35/T34 继续验收导出、恢复后重删和真机采集 |
| QA-16 | 注销冻结、撤销注销和清理协调器是否保留 | `server/internal/accounts/`、`server/internal/privacy/`、`docs/schema.md` | 冻结 15 天、撤销注销、按根清理和删除协调器均有静态路径 | `通过（静态）` | T35/T34 做端到端注销、恢复和重放测试 |
| QA-17 | 固定基线的通用导出与单条删除是否可调用 | `f60ace3:server/internal/service/http.go` | `GET /v1/me/export` 和 `DELETE /v1/me/data/:kind/:id` 在固定基线均未进入实现白名单，对有效会话返回 `501 not_implemented` | `未通过（固定基线）` | 当前候选见 [T35 候选发布核对](#t35-候选发布核对) |
| QA-18 | 关系人推断的 1 天留存边界是什么？ | `gateway/store.go`、`TestRoutingStore` | T25 在 `profile_inference` 路由排除登记留存超过 1 天的主、备、灰度与审核端点；备用/灰度仍不得弱于主线路。此检查约束配置选择，不证明供应商实际留存或删除；供应商合同、执行记录仍待验收。 | 配置校验通过；供应商待验收 | 运营取得供应商合同与删除证据后再放行 |
| QA-19 | 用户权利能力是否已闭环 | `data-inventory.md`、`privacy-policy-draft.md`、[T35 候选发布核对](#t35-候选发布核对) | 当前选删后端候选已接线导出、本人定位列表和通用单条删除。注销冻结、撤销注销与窗口专用删除分别有独立证据 | `阻断` | 选删 Flutter 旅程、目标环境复验、生产签收和 T34 恢复后重删 |
| QA-20 | 用户权利是否已在客户端闭环 | [T35 iOS 导出交接](../tasks/T35-export-ios-handoff.md)、`privacy-policy-draft.md` | 当前候选有隐私页导出入口；签名安装和真机交付、设置页逐项撤回、全量导出/删除及注销整体验收待完成 | `阻断` | T35 客户端和真机验收 |
| QA-21 | 官方来源、文号、版本、日期和适用性是否完整 | `official-source-register.md` | 部分正文与 URL/哈希已取得；平台规则版本、其余法规正文、适用性和律师意见仍待补 | `部分通过` | 律师与运营按来源登记逐项关闭 |
| QA-22 | 主模型、备用/灰度模型和审核服务是否有真实证据 | `sdk-model-review-checklist.md`、`server/migrations/20261121000600_gateway_admission.up.sql` | 准入字段存在，但仓库没有真实供应商、合同、DPA、处理地、留存或删除证据 | `阻断` | 逐槽位归档合同、DPA、后台和调用证据 |
| QA-23 | WLEIS 商用授权函是否已归档 | `docs/wleis_items.md`、`filings-and-authorizations.md` | 仓库只有“已获作者商用授权”的文字，没有授权函、范围、期限或转授权证据 | `阻断` | 运营提供签章授权函并由律师复核 |
| QA-24 | 是否把未核验法规写成确定结论 | `docs/compliance/official-source-register.md`、全部 compliance 文档 | 未写备案号、批准或律师签字；已取得正文和未取得/未核验事项分开标记 | `通过（静态）` | 律师确认引用和适用性 |
| QA-25 | 是否访问真实用户数据或联系外部主体 | 本轮操作记录、仓库文件 | 未访问用户数据、未联系平台/律师、未代备案 | `通过（静态）` | 后续外部动作由运营主体执行并留痕 |
| QA-26 | 固定基线、候选证据和补丁交接是否分离 | `docs/tasks/T33.md`、归档目录 | 固定基线为 `f60ace3`，候选证据单列；主会话从归档提取补丁，本轮不生成或创建补丁 | `通过（静态）` | 主会话在归档跑完整测试并交 GPT high 复审 |
| QA-27 | 是否修改业务代码或覆盖 `docs/CHANGES.md` | 本轮交付路径、`docs/CHANGES.md` | 本轮只修订 T33 文档、契约测试和交接；跨卡问题仅追加到 `CHANGES.md` | `通过（静态）` | 主会话复核补丁范围 |
| QA-28 | T22 分享草稿与 T21 回复后端是否按平台和持久层准确区分 | `../review-sharing.md`、`../sharing-evidence/ReplyShare.kt`、`../sharing-evidence/ShareController.swift`、`../sharing-evidence/ReplyInbox.swift`、`data-inventory.md` D37、`privacy-policy-draft.md` 第 7 节、`separate-consents.md` C08、`build/t21/after-t23/t22-live.log` | 仅基于已发布 `bc66e6e`：Android 是当前 Activity 一次性内存；iOS 是 App Group `Library/Caches/T22/incoming` 的系统完整文件保护缓存，不是业务 AES-GCM。10 分钟只拒领，不保证到点物理擦除；分享扩展不联网，未分析不上传、提交前不上传。T21 后端增量服务端不持久化源文本与目的，输入 HMAC、结果/反馈加密和最小回执边界见 D11/D12/D41/D42；真实 T22 客户端到 T21 HTTP/PG/Redis 的受控链路见 `build/t21/after-t23/t22-live.log`，模型/审核为合成上游 | `部分通过` | 真机验证写入/替换/领取/杀进程/过期清理；真实厂商、日志、备份、生产发布、删除签收和 T35 公共入口仍待验 |
| QA-29 | 发布门槛是否关闭 | `docs/compliance/README.md` 第 5 节、本表 | 运营资料、供应商、T28/T29 真机与平台材料、T35、完整法律适用性和律师意见均未关闭 | `阻断` | 任一未关闭不得发布 |
| QA-30 | T19 对练、额度与撤权是否经实服验证 | `server/tests/t19-wire.sh`、`TestPracticeWire`、清单 D38、[T19 交接](../tasks/T19.md) | 隔离 PG17、普通 Redis 和独立 AOF Redis，真实 HTTP/SSE 配合合成模型；11 个子项含中断恢复、撤权、封顶后保留可评分历史、扣次与补偿。T19 已接入 T25 画像摘要，选用关系人时额外检查 `contacts`。通用导出/删除未接线 | `通过（隔离后端）` | 客户端首次服务端授权隔离联验参见 QA-09；真机和真人使用真实模型 20 轮仍未验证，不构成上线放行 |
| QA-31 | T25 画像证据、冻结场景、双同意和撤权是否经隔离实跑验证 | `20261122010025_profile_evidence.up.sql`、`server/internal/profile/`、`server/internal/training/store.go`、`server/internal/service/profile_http.go`、`build/t25/with-practice/live.log`、`build/t25/joint-review-live.log` | 本批后端新增 D39/D40，并让 D14 的 `profile_observations.fact_enc` 只表示用户明确反馈形成的画像观察事实；后端只接受通过校验的七个有界选项，并合并到 `contacts.profile_enc`，T25 推断链路不持久化聊天原文。`profile_inference_requests` 同时绑定 `chat_consent_id`、`contacts_consent_id` 和 32 字节 SHA-256 输入摘要，状态为 `processing`/`complete`/`invalidated`；尝试前和最终保存前复核。处理中复核发现授权变化或关系人不可用时，旧推断失效、不再外发或保存；同键换材料或关系人返回 409，不改写原记录；已完成请求须有当前权限，重放只读当前画像。场景冻结包括已验证的 null；`DELETE /v1/contacts/:id` 走删除协调器，通用 export/delete 仍为 `501 not_implemented`。提示词草稿 `b935fb60-5a85-4c12-82c0-401afd649325`。`TestProfileLifecycle`、`TestProfileInferenceReviewRegressions`、`TestPracticeWire` 和 `TestProfileReviewSourceLifecycle` 已分别在隔离 PG17 + 双 Redis 回环通过，后一项覆盖 `work` 与 `null_scene`。 | `通过（隔离后端）` | 本批后端实现不等于生产上线。真实模型、真机、供应商合同、1 天绝对留存和律师签收仍待验；不替代 T35 公共入口 |
| QA-32 | 复盘来源、期限、导出与扣次边界 | `server/tests/t23-verify.sh`、`app/tool/t24/live.sh`、D23 | PG17、双 Redis、真实 HTTP 和合成模型：无权或过期标记不外发；本人删除标记后保留复盘；T25 用户首次明确提交本人反馈后，才按来源分组，不是完成复盘即产生反馈。真实 T26 订阅者写数值投影，再以受控的后续订阅者注入失败，验证投影与投递确认一起回滚。成功发布和删除后重算见 QA-34。未审核输出只在原键恢复窗口内重审；在途重审碰上永久过期，旧 worker 不能再保存评分或扣次 | 通过（隔离合装） | 仍待真实模型话术质量、供应商及真机；T35 通用导出/删除未放行 |
| QA-33 | T21 回复生命周期、最小回执和画像隔离是否经隔离实跑验证 | `server/internal/service/replies_integration_test.go`、`server/internal/replies/`、`server/internal/profile/outcome.go`、`server/migrations/20261123000021_reply_requests.up.sql`、`server/migrations/20261123000022_reply_request_keys.up.sql`、`server/migrations/20261123000023_reply_outcome_receipts.up.sql`、`build/t21/after-t23/grant-and-review-2.log`、`build/t21/after-t23/t22-live.log` | 隔离 PG17 已应用本卡迁移；`TestReplyLifecycle`、`TestReplyDispatchReusesSinglePoolConnection`、`TestReplyWithdrawalWaitsForInFlightDispatch`、`TestReplyContactRegrantBlocksPendingDispatchAndSave` 通过。覆盖源文本/目的不落库、回复触发器、32 字节 HMAC、AES-GCM 结果/反馈、普通效果与 `self_report` 双队列、最小回执无正文、画像隔离和删除后防重放。`build/t21/after-t23/t22-live.log` 仅证明真实 T22 客户端 ↔ T21 HTTP/PG/Redis 受控链路，不将合成模型或审核结果写成真人 | `通过（隔离后端）` | 本批后端实现不等于生产上线；真实厂商留存/删除签收、生产环境、真人、真机、律师和 T35 公共权利入口仍待验 |
| QA-34 | T26 成长计划、数值投影和单项复习调度是否经隔离组合验证 | `server/migrations/20261123010026_growth_plan_delivery.up.sql`、`server/internal/growth/projection.go`、`server/internal/growth/planning.go`、`server/internal/growth/planning_delivery.go`、`server/internal/growth/privacy.go`、`build/t26/correction-9lksr637/member-plan-http.log`、`build/t26/correction-9lksr637/final-storage.log`、`build/t26/correction-9lksr637/t04-server.log`、`build/t26/t27-latest/client.log`、[T26 交接](../tasks/T26.md)末段 | 隔离组合运行环境为 PG17、普通 Redis 与独立 AOF Redis。证据分层：`member-plan-http.log` 证明首次 `GET` 前测评事件已生成计划，并覆盖免费、会员和撤回 `contacts` 后的路径；正常账号当天无计划且有可用测评时，`GET /v1/plans/today` 可以幂等补生成，冻结账号才被拒绝且不会补生成。`final-storage.log`/`t04-server.log` 证明真实 T26 订阅者消费 T23 合成评分、失败回滚、删除后重算与乱序原日补记：T23 受控来源返回 NVC 20、情绪 2/3/2、行为分 24，T26 投递后成长计数 0→1，训练参考为 `(WLEIS 百分制分 + 24)/2`，删除复盘并重投原事件后计数恢复 0、无训练参考、内部导出没有该分数；跨日迟到只补记按事件时刻和账号时区确定的原日已有匹配关卡，不补建历史计划、不给今天打卡、不复活已关闭排期，手动完成接口不是历史补打卡入口。`t27-latest/client.log` 证明 Flutter 实际 HTTP 的测评、读计划、完成和客户端重建后读回，不是前两类服务端断言的客户端证据。迁移新增可空 `daily_plans.assessment_id ... ON DELETE CASCADE` 和 `growth_drill_schedules`：分值与档位只在 AES-GCM `schedule_enc`，无明文 `score`/`band`；10–24 分按 `occurred_at + 72h` 重练，`closed_at` 防旧事件复活；T26 不覆写 T19 `drill_progress`。内部 `growth.json` 含数值评分、计划和单项调度三类记录，计划导出不输出 `review_activity_id`，通用 export/delete 仍为 `501 not_implemented` | `通过（隔离组合）` | T26 已实际消费受控模型生成的完整评分；真实模型质量待验；人工审题、真机、律师、生产发布和 T34 恢复后重删仍待验；50 道题与 20 张卡为合成材料且未人工审校，不构成上线放行 |
| QA-35 | T29 语音权限、30 秒聚合、本机加密、3 天到期和撤回边界是否与静态实现一致 | `app/android/app/src/main/AndroidManifest.xml`、`app/ios/Runner/Info.plist`、`app/android/app/src/main/kotlin/cn/higheq/high_eq/VoiceCapture.kt`、`app/ios/Runner/VoiceCapture.swift`、`app/lib/features/voice/`、`app/lib/core/session.dart`、`docs/compliance/test_t33_contract.py` | 静态核对到 Android `RECORD_AUDIO`、iOS `NSMicrophoneUsageDescription`、原生内存 PCM 边界、`voice`/会员/`audio_retention`/系统权限顺序、完整 UTC 对齐 30 秒窗口、`speech_rate` 声学代理、无 PCM/转写上传、AES-GCM 256 账号作用域、3 天到期不可读、janitor/restore、撤回与会员到期不补传；隔离合成 PCM 经真实 T30/PG17/双 Redis 实服 HTTP 回环，覆盖真实 T30 加密存储和 wire 边界；T28 健康历史另见 QA-36 | `通过（静态 + 隔离合成 PCM 回环）` | T29 归档静态实现、未合入固定基线、真机待验；合成 PCM 回环不能签真机，30 分钟耗电、实际设备抓包、ASR 质量、双平台整包/权限回执、HMS/平台审批未验 |
| QA-36 | T28 健康历史权限、只读来源、30 秒窗口、D45 撤回和证据边界是否可静态对表 | 仓库内：`app/android/app/src/main/AndroidManifest.xml`、`app/ios/Runner/Info.plist`、`app/ios/Runner/Runner.entitlements`、`app/ios/Runner/HealthHistory.swift`、`app/lib/features/health/`、`app/lib/core/session.dart`、`app/test/health/logout_regression_test.dart`、`app/test/health/sync_test.dart`、`docs/compliance/data-inventory.md` D45、`docs/compliance/test_t33_contract.py`、`docs/tasks/T28.md`；宿主回执仅记录事实，不作为 CI 合同 | 固定基线仍仅声明 Android `INTERNET`，没有健康权限或 HealthKit；T28 归档静态实现只读 Android 健康/运动权限、iOS `NSHealthShareUsageDescription` 和 HealthKit entitlement，没有健康写入/`NSHealthUpdateUsageDescription`。来源仅为 `apple_history`、`health_connect`、`huawei_history`，无 `watch_live`；查询最多回看 24 小时、30 秒对齐、单段最多 10 分钟、`pending_end` 续传，队列是 slot range 而非测量值。普通 Android Health Connect 路径另申请运动识别；华为默认 `platform`，仅 `huaweiRestricted` 加载 AGCP，要求数字 App ID 和 `agconnect-services.json`，`T28_HUAWEI_HEALTH_APPROVED` 默认 false，未批准/未知来源 fail closed，按其心率、步数和活动记录三个只读 scope 授权。华为授权只读 scope 为心率、步数、活动记录，不申请或消费 HRV；HMS 插件返回样本可能含其他平台字段，原生通道解析数据类型、起止/采样时间和可转成数值的字段，随后归一化适配器才筛选心率 `bpm`、步数增量 `steps_delta` 及对应时间，并将活动记录/训练区间起止时间映射为 `exercise` 运动标志。插件原始返回和解析样本均不写入本机队列或上传。T30 外发仅含 30 秒窗口的 `mean`、`maximum`、`sample_count` 等必要聚合：`heart_rate`、`cadence` 含 `valid_seconds`，`hrv` 不含。D45 `t28.history.v1` 使用 AES-GCM 256，AAD 绑定账号、`queue` 和队列键；显式撤回意图独立加密 outbox，可跨登出但只能由原账号凭据重试，不等于删除云端历史；普通登出不自动撤回线上同意，只有已经存在的明确 `explicit` 意图才发送 `health:false`，撤回失败仍保持停采并分别报告本机清理、健康撤回和服务端登出结果；已到达云端的窗口不因登出或撤回自动删除。T30 按账号存储，并在收窗时按窗口时间校验授权；窗口内不写具体同意记录 ID。仓库内 logout/sync 回归覆盖离线登出、未知队列、显式撤回、直接登出无队列和墓碑写失败。本批同一源码宿主合装回执：analyze `No issues found`、健康定向 181 过、health+voice 235 过（覆盖不同，不能相加）、全 Flutter 442 过/2 跳过、Swift arm64、Android API35 六种合同/适配器类实际重编、T28 live `05:59` 4 过（含代理哨兵；真实 T28 客户端→T30/PG17/双 Redis/直连夹具，设备端为合成健康数据）。旧阶段 `unknown-join` 的 `24 issues found` 已由本批同源码回执替代，仅作历史记录；live 不证明所有异常路径都在真机跑过。 | `部分通过（静态 + 本次合装回归回执）` | T28 归档未合入固定基线；iOS 签名安装/授权/真实 HealthKit 样本、三台真机、真实健康库、Android 完整 MainActivity/APK、Huawei 批准/签名/HMS、耗电、实际延迟/空窗率/成功率/HRV 缺失原因、宿主回执升级为固定 SHA CI、生产发布和平台/律师审批均未签 |

## 3. T29 最终对表门槛

T29 归档已有静态实现，但未合入固定基线、真机待验。不得把静态代码、单文件类型检查或合成 PCM 测试写成双平台整包、真实权限、抓包、耗电、ASR 质量或平台审批已通过。最终至少核对：

1. 麦克风权限声明、申请时机、拒绝和撤回行为：静态顺序已核对，双平台真机仍待验。`[待真机复核]`
2. 音量、音调和声学音节速率代理的实际提取、有效秒数和静音处理；不得写成转写语速。`[已知：T29 静态]` `[待真机复核]`
3. 只上传完整 30 秒聚合字段的静态边界已核对；实际设备抓包仍待验，不得上传 PCM、音频、逐秒数组或转写。`[待真机复核]`
4. 原始录音仅本机、本机队列不含 PCM、AES-GCM 256 和账号作用域已静态核对；换号与真实清理仍待真机。`[待真机复核]`
5. 3 天到期不可读、janitor/restore 清理路径已静态核对；杀进程、离线、重开、换账号和真实过期场景仍待真机，不承诺恰好 72 小时物理擦除。`[待真机复核]`
6. 录制时可见状态和“可能混入他人声音”的文案已核对；实际界面、后台停止和系统权限弹窗仍待真机。`[待真机复核]`
7. `voice` 和 `audio_retention` 的独立授权、默认关和撤回停采已静态核对；正式版本、服务端版本闭环和拒绝后果仍待验。`[待运营填写]` `[待真机复核]`
8. 30 分钟连续录制耗电、机型、系统版本、构建 SHA 和实测边界。`[待真机复核]`
9. 会员到期、系统权限撤销、App 内撤回和后台重开的 fail-closed 代码路径已核对；真机恢复联网不补传仍待验。`[待真机复核]`
10. 录音与心率对齐回放不属于 T29；T32B 尚未实现前，会员页不得写成已可回放。`[待实现/验收]`

## 4. T35 最终对表门槛

### T35 候选发布核对

| 核对范围 | 通用导出 | 通用单条删除 |
| --- | --- | --- |
| 固定 T33 基线 `f60ace3` | `GET /v1/me/export` 返回 `501 not_implemented` | `DELETE /v1/me/data/:kind/:id` 返回 `501 not_implemented` |
| T35 独立导出候选 | 有效、未冻结的账号可流式取得 ZIP。删除屏障返回可重试的 `503`，ZIP 中央目录在事务提交成功后写入 | 有效会话的合法请求由路由门禁返回 `501 not_implemented` |
| T35 当前选删后端候选 | 沿用独立导出候选的 ZIP、事务提交与删除屏障 | `GET /v1/me/data/{kind}` 分页定位本人，`DELETE /v1/me/data/{kind}/{id}` 按本人记录的种类和公开 UUID 定点删除。窗口按 30 秒起点和渠道走 `DELETE /v1/signal-windows` |

候选的 `manifest.json` 为首条，后接 13 个 JSON 分区：`accounts`、`ai_calls`、`assessments`、`chat_imports`、`emotion`、`growth`、`manual_marks`、`membership`、`payments`、`profiles`、`replies`、`reviews`、`training`。源代码与回归核对的排除项包括其他账号记录、密钥和会话凭据、HMAC/防重放键、平台收据原文、聊天原文与设备录音，以及训练工作令牌、请求键和成长计划的 `review_activity_id`。保留关系人、标记与窗口专用删除以及注销各自的证据。

截至评审对照点 `7332045`，此前主线的通用导出仍未实现。独立导出切片在一次性 PG17、普通 Redis 和独立登记 Redis 环境中记录了 8 个顶级集成用例、2 个对练子例及 5 个提交/HTTP 中断用例的通过回执。该切片保留 `TestPrivacyRightsHTTP/selected_record_delete_stays_unimplemented`，断言匿名 `401`、有效会话 `501 not_implemented` 且 `retryable: false`，并核对标记仍在本人 ZIP 中且与另一账号隔离。该子例待用[独立导出候选的代码](../tasks/T35-export-ios-handoff.md#独立导出后端复验)单列回执。

当前选删候选的列表只提供静态标签、时间与公开删除键，活动类记录返回活动 ID，内部清理源由服务端解析。删除在账号锁内复核会话、归属和种类，写入清理意图和独立账本。删除屏障生效时，本人的有效会话只能重试精确待办。匿名或失效会话被拒绝，越权、种类不符与未知记录均返回 `404`。

当前归档新增 `TestPrivacyRightsHTTP/selected_record_delete_removes_only_the_listed_owned_mark`，以两个合成账号的真实 HTTP 列表和 ZIP、SQL 源行及独立账本核对拒绝请求无副作用、本人的选中项消失、同组与另一账号的记录保留。既有四项宿主实库回执覆盖定位与窗口、精确恢复、反序重放和对练清理。覆盖范围、已验与未验及复跑命令见[选删后端候选交接](../tasks/T35-selected-record-handoff.md)。

生产发布、物理清除、Flutter 选删、真机及 T34 备份恢复与重删仍各自待验。完整 OpenAPI 校验在具备仓库校验依赖的环境运行 `python3 -B scripts/check_contracts.py`。

### 完整用户权利验收

1. 设置页逐项展示并撤回 `health`、`voice`、`audio_retention`、`practice`、`review`、`contacts`、`chat_import`、`manual_mark`，撤回后立即停采。`[待 T35 对表]`
2. 查阅、复制/导出、更正、删除和注销的实际入口及错误处理。当前后端候选继续做目标环境交付验收，并补齐 Flutter 定位、选择、确认、删除后读回的全链路回执。`[待 T35 对表]`
3. 从源消息、带引用评分追到数值副本、画像、计划和可关联日志；导出包含用户仍有的数据，排除密钥、HMAC、他人数据和平台收据原文。`[待 T35 对表]`
4. 删除后重算、不可回填、不可再导出；防重放记录只保留不含身份信息的源 ID 并覆盖规定期限。`[待 T35 对表]`
5. 注销冻结 15 天、撤销注销、按根清理、订单脱敏、支付明细/通知清理及清理证明。`[待 T35 对表]`
6. 撤回健康/语音同意后的设备读取、未发窗口、缓存和联网补传行为。`[待 T35 对表]` `[待真机复核]`
7. 换账号、离线撤回、杀进程、重开和过期录音场景的隔离证据。`[待 T35 对表]` `[待真机复核]`
8. T34 备份恢复后加载最新删除记录、重做删除并验证不可查询/导出/恢复，再开放流量。`[待 T35 对表]` `[待 T34 复核]`

## 5. 本轮静态检查命令

```sh
rg -n "privacy|terms|assessment|health|voice|audio_retention|practice|review|contacts|chat_import|manual_mark" server/internal/accounts app/lib
rg -n "chat_imports|original_enc|received_at|24 小时" server/migrations server/internal app/lib docs/schema.md
rg -n "provider_admissions|processing_country|storage_country|cross_border|max_retention_days|deletion_method|terms_evidence" server/migrations server/internal
rg -n "RECORD_AUDIO|NSMicrophoneUsageDescription|ACTIVITY_RECOGNITION|READ_HEART|READ_STEPS|READ_EXERCISE|NSHealth|NSHealthUpdate" app/android app/ios
rg -n "t28.history.v1|t28Distribution|T28_HUAWEI_HEALTH_APPROVED|slotMs|pending_end|watch_live" app docs/compliance/data-inventory.md
rg -n "GET /v1/me/export|DELETE /v1/me/data|not_implemented" server/internal/service/http.go
rg -n "reply_requests|reply_feedback|reply_request_keys|reply_outcome_receipts|reply_import_guard|self_report" server/migrations server/internal/replies server/internal/profile/outcome.go
python3 docs/compliance/test_t33_contract.py
```

静态检查不能替代真机、平台后台、供应商合同、官方页面或律师审阅。任何“通过（静态）”都不得写成“上线已通过”。
