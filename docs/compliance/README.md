# T33 隐私与合规材料总览

> 状态：可先行草案，不可直接用于上线。
> 核对日期：2026-11-23。
> 固定事实基线：`f60ace3`。
> 上一轮 T33 文档候选证据：`ce479034bcba174475fa8fbc156be66a3b22ba5371b5344602f29394185d638a`（只标识早期 T33 草案，不是业务源码）（仅文档，不含其他卡业务实现）。T19/T23/T25 是已有后端，T21 为本批后端增量；T29 归档静态实现、未合入固定基线、真机待验；T28 归档静态实现、未合入固定基线，真机与平台审批未验。
> 本目录不是法律意见。法规、平台规则和上线准入均须由具备资质的律师及项目运营主体复核。

## 1. 本批材料的边界

- 只形成隐私政策、用户协议、单独同意、数据清单、供应商审核、备案授权、禁用词和 QA 草案。
- 不修改业务代码，不代填公司主体、地址、联系人、商户、供应商、授权函、备案号或审批结论。
- 不代备案、不联系律师或平台、不访问任何真实用户数据。
- T29 归档已有语音特征、麦克风权限、本机加密队列、录音索引、3 天到期不可读和撤回清理的静态实现，但未合入固定基线；真机、抓包、耗电、ASR 质量和平台审批仍待验。T29 归档静态实现、未合入固定基线、真机待验。
- T28 归档已有健康历史读取、系统权限、30 秒窗口、华为受限发行和 D45 本机撤回 outbox 的静态实现，但未合入固定基线；本批同源码宿主合装回执为 analyze 绿、健康定向 181 过、health+voice 235 过（两者覆盖不同，不能相加）、全 Flutter 442 过/2 跳过、Swift arm64、Android API35 六种合同/适配器类实际重编及 T28 live `05:59` 4 过（含代理哨兵）；真机、真实健康库、完整 APK、平台审批和固定 SHA CI 仍待验。
- `GET /v1/me/export` 与 `DELETE /v1/me/data/:kind/:id` 在固定基线均未进入 HTTP 路由白名单，对有效会话返回 `501 not_implemented`。T35 独立导出候选已接线 ZIP 导出，当时通用单条删除仍返回 `501 not_implemented`。当前选删后端候选增加本人分页定位与单条删除，尚待 Flutter 全链路和生产验收。见 [T35 候选发布核对](qa.md#t35-候选发布核对)。
- 注销冻结/撤销注销、健康窗口专用删除、AES-GCM 字段加密和删除协调器是已核对的安全边界；不得因通用权利接口未接通而抹掉这些既有能力。

## 2. 状态标记

| 标记 | 含义 | 放行要求 |
| --- | --- | --- |
| `[已知]` | 能在固定基线 `f60ace3` 的代码、迁移、接口或交接中直接核对 | 记录证据路径；实现变动后重新核对 |
| `[候选待对表]` | 只见于独立候选或任务目标，尚未合入固定基线 | 合入后按固定基线重新核对 |
| `[待运营填写]` | 主体、联系人、供应商、价格、渠道、授权或运营规则尚未提供 | 项目方提供正式资料并留档 |
| `[待商户/平台确认]` | 支付、登录、健康平台或应用商店规则依赖真实账号和合同 | 商户/平台后台截图、合同或审批单归档 |
| `[待实现/验收]` | 设计目标存在，但未找到完整实现或端到端证据 | 代码、测试、真机/线上回执齐全 |
| `[待真机复核]` | 只能在指定系统、设备、签名或真实账号下确认 | 留存脱敏测试记录 |
| `[T29 待真机/平台验收]` | T29 归档已有静态实现，剩余真机、抓包、耗电、平台和正式版本项 | 按 T29 门槛逐项对表 |
| `[待 T35 对表]` | 依赖用户权利入口与全量导出/删除验收 | 按 T35 门槛逐项对表 |
| `[待官方来源核验]` | 官方正文已部分取得，但版本、适用性或业务结论仍未由律师确认 | 补官网正文、抓取日期、哈希和律师适用性意见 |
| `[待律师复核]` | 涉及法律适用、责任、授权基础、留存或争议条款 | 律师出具书面审阅意见 |

任何“待”项都不能通过复制模板、行业惯例或模型记忆改成“已完成”。

## 3. 文档地图

| 文件 | 用途 | 当前状态 |
| --- | --- | --- |
| `privacy-policy-draft.md` | 面向用户的隐私政策草案 | 主体信息、供应商及法律依据待补；T29 语音边界已按静态归档登记 |
| `terms-of-service-draft.md` | 用户协议草案 | 商户、退款、责任限制和争议条款待律师复核 |
| `separate-consents.md` | 各敏感/可选处理的单独同意文案 | 已有功能的文案可先行；C05/C06 已按 T29 静态归档补齐，真机待验 |
| `data-inventory.md` | 字段、原始记录、副本、加密、留存、删除和导出对表 | D01–D45 已登记；已按 PG17 清单逐名核对 42/42 表/视图；D32–D36 补后台缺口，D39/D40 另列 T25 增量，D41/D42 另列 T21 增量（D41 并入 T35 对练删除重放键），D43 为 T26 单项复习调度投影，D44 为 T29 本机语音队列、录音索引和 PCM，D45 为 T28 本机健康历史待发状态与撤回意图，D37–D45 均不计入 42 项；清理、通用权利接口与真机项待验收 |
| `sdk-model-review-checklist.md` | 主模型、备用/灰度模型、审核服务及 SDK 证据清单 | 无真实供应商资料，全部待运营提供 |
| `filings-and-authorizations.md` | 备案、ICP、应用商店、量表授权、健康平台和权限归档 | 无备案号、批准或授权函，不得宣称已完成 |
| `banned-words-and-examples.md` | 文案禁用词与 10 条改写示例 | 可先行用于文案评审 |
| `official-source-register.md` | 法规与平台官方来源版本登记 | 已读取部分官方正文并登记哈希；律师适用性待复核 |
| `qa.md` | 文档与实现一致性 QA | 静态 QA 已执行；发布门槛未满足 |

## 4. 已核对的产品事实摘要

**T23 文字复盘：** `review_requests`、`review_tombstones` 是固定 42 项盘点之后的增量，见 D23；不要与 T21 的 `reply_requests` 混淆。T24 经真实 HTTP 连接 T23 的受控上游验证了无授权拒绝、同键重放、成功评分和审核故障恢复；不代表真实模型质量或生产签收。

**T19/T25 后端增量：** `server/internal/training/` 已接入对练路由，T19 已接入 T25 画像摘要，选用关系人时额外检查 `contacts`；`20261122003019_practice_work` 新增活动级元数据，详见 D38。T25 新增 `profile_observations.fact_enc`、`activity_profile_context.context_enc` 和 `profile_inference_requests`，详见 D14/D39/D40；其 `profile_inference` 提示词草稿为 `b935fb60-5a85-4c12-82c0-401afd649325`。42 项仍是 `f60ace3` 的固定盘点，D39/D40 不计入。本批后端实现不等于生产上线。`TestPracticeWire` 和 T25 生命周期测试已在隔离 PG17、双 Redis 与受控上游实跑；不代表客户端首用、真实模型、真机、供应商合同或律师签收。
**T21 后端增量：** `server/internal/replies/` 已接线 `POST /v1/replies` 与 `POST /v1/replies/:id/feedback`；三个迁移新增 `reply_requests`、`reply_feedback`、`reply_request_keys`、`reply_outcome_receipts`，并安装 `reply_import_guard` 阻止 `chat_imports` 写入回复活动。服务端不持久化源文本与目的，结果与反馈使用 AES-GCM，输入指纹为 32 字节带密钥 HMAC，另存授权及请求关联元数据；删除后保留 `(user_id, request_id)` 定位键与输入 HMAC，`activity_id ON DELETE SET NULL` 防重放。反馈正文加密保存，普通效果消费另写最小非画像回执，只有显式 `self_report` 进入本人画像观察。以上为当前后端增量，不计入 `f60ace3` 的 42 项；隔离测试不证明真实厂商、日志、备份、生产发布或删除签收。
**T26 成长计划后端增量：** `20261123010026_growth_plan_delivery.up.sql` 为 `daily_plans` 增加可空 `assessment_id ... ON DELETE CASCADE`，并新增 `growth_drill_schedules`（D43）；分值和档位只存于 AES-GCM `schedule_enc`，表内没有明文 `score`/`band`。`growth_scores` 是固定基线表，T26 新增的是投影消费、计划与调度导出；该表只保存数值投影，账号和发生时间从存活源派生；成长参考按最近 WLEIS 与 720 小时内有效 practice/review 源即时重算，新增或删除有效来源后计数和参考值即时重算，删除低分有效来源时参考值可以上升。T26 只消费 practice/review 完整评分；单项调度使用独立 `schedule_enc`，不覆写 T19 `drill_progress`。生成新计划时，默认场景由账号、计划日和训练重点推导；只有会员权益、有效 `contacts` 同意和可用场景均满足时才采用 T25 最近使用关系人场景，无权益、无授权或无有效场景回退默认路径，会员检查的非拒绝错误不静默回退；生成仍读取到期单项调度和近期已用题卡。内部计划导出排除 `review_activity_id`。隔离组合证据见 `docs/tasks/T26.md` 末段，通用 `GET /v1/me/export` 与 `DELETE /v1/me/data/:kind/:id` 仍返回 `501 not_implemented`，不等于 T35 或生产上线；50 道题与 20 张卡尚未人工审题。

- 首次启动先展示隐私/协议摘要，用户主动勾选后才继续；未同意不发起登录。`[已知]`
- 新账号登录携带 `privacy_version`、`terms_version`，服务端接受后写入 `privacy` 与 `terms` 同意。当前版本均为 `2026-11`，属开发占位版本。`[已知]`
- 登录需确认已满 14 周岁；产品不是医疗、心理诊断或危机干预服务。`[已知]`
- 健康读取的产品目标是会员、App `health` 单独同意和系统健康权限同时成立；固定基线尚未声明这些设备权限。当前 T28 归档静态实现已有 Android 的 `ACTIVITY_RECOGNITION`、Health Connect 心率/HRV/步数/训练读取权限（无健康写入）和 iOS 的 HealthKit 读取用途/entitlement（无更新用途），查询最多回看 24 小时、30 秒对齐、单段最多 10 分钟；服务端既有 180 天留存和专用窗口删除另列。该归档未合入固定基线，真机、平台审批和真实 App→T30 回执未验。`[候选待对表]` `[待真机复核]`
- 固定基线 Android Manifest 仅声明 `INTERNET`；没有 `ACTIVITY_RECOGNITION` 或 Health Connect 读取权限。T29 归档另声明 `RECORD_AUDIO`；T28 归档另声明 `ACTIVITY_RECOGNITION`、`health.READ_HEART_RATE`、`health.READ_HEART_RATE_VARIABILITY`、`health.READ_STEPS`、`health.READ_EXERCISE`，未发现健康写入权限。`[已知：T28 归档静态实现]`
- iOS 在固定基线没有 HealthKit entitlement，也没有 `NSHealthShareUsageDescription` 或 `NSMicrophoneUsageDescription`；T29 归档新增 `NSMicrophoneUsageDescription`；T28 归档新增 `NSHealthShareUsageDescription` 和 `com.apple.developer.healthkit=true`，没有 `NSHealthUpdateUsageDescription`。`[已知：T28 归档静态实现]`
- T29 归档只把完整、UTC 对齐的 30 秒窗口统计上传，字段不含 PCM、逐秒数组或转写；`speech_rate` 是声学音节速率代理，不是转写语速。录音保留独立授权且默认关闭，本机队列不含 PCM。T29 归档静态实现、未合入固定基线、真机待验。`[已知：T29 归档静态实现]`
- T28 归档只读取 Apple Health、Health Connect 和 Huawei Health 的历史来源 `apple_history`、`health_connect`、`huawei_history`，没有 `watch_live`；`HealthHistory.swift` 为只读前台历史，无后台投递、写入或 Watch 桥。华为默认发行 `platform`，仅 `huaweiRestricted` 加载 AGCP，要求数字 App ID 和 `agconnect-services.json`；`T28_HUAWEI_HEALTH_APPROVED` 默认 false，未批准/未知来源 fail closed；授权只读 scope 为心率、步数、活动记录，不申请或消费 HRV。HMS 插件返回样本可能含其他平台字段，原生通道解析数据类型、时间及可转成数值的字段，归一化适配器才筛选心率、步数增量及对应时间，并把活动区间映射为 `exercise` 运动标志；插件原始返回和解析样本均不写入本机队列或上传。`[已知：T28 归档静态实现]` `[待真机复核]` `[待商户/平台确认]`
- T28 窗口以 30 秒对齐、最多回看 24 小时、单段最多 10 分钟，使用 `pending_end` 续传；本机队列只保存 slot range，不缓存测量值。D45 `t28.history.v1` 使用 AES-GCM 256，AAD 绑定账号、`queue` 和队列键；显式撤回意图独立加密 outbox，可跨登出但只能由原账号凭据重试，不等于删除云端历史。`[已知：T28 归档静态实现]`
- 对练消息、评分明细、成长数值副本、复盘、关系人画像和手动标记的目标是使用 `*_enc` AES-GCM 字段保存；具体候选实现须按模块对表。`[已知：字段与加密封装]` `[候选待对表：候选模块]`
- T25 后端已把用户明确反馈形成的画像观察事实写入 `profile_observations`，后端只接受通过校验的七个有界选项并合并到 `contacts.profile_enc`，T25 推断链路不持久化聊天原文；推理请求同时绑定 `chat_import` 与 `contacts` 的精确同意记录和 32 字节 SHA-256 输入摘要，处理中复核发现授权变化或关系人不可用时，旧推断失效、不再外发或保存；同键换材料或关系人返回 409，不改写原记录；已完成请求须有当前权限，重放只读当前画像。`[已知：本批后端]` `[待 T35 对表]`
- T21 回复请求不保存聊天原文或目的；输入 HMAC、加密结果/反馈和最小回执的字段边界见 D11/D12/D41/D42。模块内部导出不等于 T35 公共权利入口，厂商与基础设施留存仍待证据。
- T25 在 `profile_inference` 路由排除登记留存超过 1 天的主、备、灰度与审核端点；备用/灰度仍不得弱于主线路。此检查约束配置选择，不证明供应商实际留存或删除；供应商合同、执行记录仍待验收。
- `chat_imports.original_enc` 当前候选只处理历史导入行，已实现 24 小时到期行清扫、导出过滤和维护重试；当前关系人推断与回复助手的新提交均不写该表。固定基线本身未包含该实现，宿主实库、失败告警、供应商与备份/WAL 证据仍待验收；详见 [D13 交接](../tasks/D13.md)。`[已知：当前候选代码]` `[待验收]`
- 服务端 `provider_admissions` 强制境内处理、境内存储、不出境，并要求留存天数、删除方法和条款证据字段；数据库未预置真实供应商。`[已知]`；供应商证据 `[待运营填写]`
- T35 候选的 `GET /v1/me/export` 以流式 ZIP 提供当前账号的 13 个服务端分区；`GET /v1/me/data/{kind}` 提供本人公开定位键，`DELETE /v1/me/data/{kind}/{id}` 已接选删后端，发布与 Flutter 回执待验。健康/语音窗口继续走 `DELETE /v1/signal-windows` 专用删除；注销冻结/撤销注销和关系人专用删除按各自入口核对。`[待 T35 对表]`

## 5. 上线前强制门槛

以下任一项未关闭，不得把本目录草案作为正式版本发布：

1. 运营主体、注册地址、个人信息保护负责人、邮箱、电话和投诉渠道全部填写并验证可达。`[待运营填写]`
2. 主模型、备用/灰度模型、审核服务及所有 SDK 的供应商、处理地、存储地、跨境、留存、训练用途、子处理者和合同/条款证据全部归档。`[待运营填写]`
3. WLEIS 商用授权函、授权主体、16 题范围、版本、地区、期限和转授权边界归档。`[待运营填写]`
4. 聊天原文历史行的 24 小时到期逻辑清扫、导出过滤、失败重试和告警验收；到期筛选独立于清扫，清扫失败或行删除延迟不等于可导出，也不承诺物理擦除。`[待验收]`
5. T29 归档静态实现已补齐语音/录音权限、独立授权、30 秒聚合、账号隔离、3 天到期不可读和撤回清理；仍需真机验证权限与状态提示、杀进程/离线清理、账号切换、抓包、耗电、ASR 质量和平台材料。T29 归档静态实现、未合入固定基线、真机待验。`[待真机复核]` `[待商户/平台确认]`
6. T35 完成查阅、复制/导出、更正、删除、撤回同意、注销的实际入口和全量数据验收。导出及选删后端已有隔离回执，新增选删与 ZIP 联合回归待宿主复跑，Flutter 选删及目标环境、真机验收待补。`[待 T35 对表]`
7. T28 归档的 Android/iOS 健康读取权限、30 秒窗口、24 小时回看、华为受限发行和 D45 撤回 outbox 已做静态对表，并取得本批同源码宿主合装回执：analyze 无问题、健康定向 181 过、health+voice 235 过（两者覆盖不同，不能相加）、全 Flutter 442 过/2 跳过、Swift 模拟器 arm64、Android API35 六种合同/适配器类实际重编、T28 live 于 `05:59` 4 过（含代理哨兵）。固定基线仍只声明 `INTERNET`，不得把 T28 归档写成固定基线事实；完整 MainActivity/APK、Health Connect/HealthKit/HMS 真机、真实健康库、华为批准/签名、耗电、实际延迟、同步成功率和固定 SHA CI 仍须验收。`[候选待对表]` `[待真机复核]` `[待商户/平台确认]`
8. 法规、生成式 AI、算法/深度合成/内容标识、ICP/App 备案和应用商店规则的官方正文、版本、日期与适用结论完成核验。`[待官方来源核验]` `[待律师复核]`
9. 隐私政策和用户协议完成律师书面审阅，版本号、生效日期和变更通知流程确定。`[待律师复核]`
10. 正式文案不得出现未证实的功能、留存、绝对效果或平台批准表述。`[已知]` 发布前需再次 QA。

## 6. 证据分层和变更规则

证据按三层记录，不能互相替代：

1. **固定基线静态**：`f60ace3` 的 Android Manifest 仅声明 `INTERNET`，没有健康权限、HealthKit entitlement 或健康用途说明；这是固定基线事实，不是 T28 实现。
2. **当前 T28 归档静态**：已核对 Android/iOS 只读健康权限、三种历史来源、30 秒窗口、24 小时回看、10 分钟分段、华为默认关闭和 D45 撤回 outbox；证据见 `app/android/app/src/main/AndroidManifest.xml`、`app/ios/Runner/Info.plist`、`app/ios/Runner/Runner.entitlements`、`app/ios/Runner/HealthHistory.swift`、`app/lib/features/health/`、`app/lib/core/session.dart`、`docs/compliance/data-inventory.md` D45 和 `docs/compliance/test_t33_contract.py`。该归档未合入固定基线。
3. **本批宿主合装回执（非 CI 合同）**：同一源码树最终 `flutter analyze` 为 `No issues found`；健康定向回归 181 过；health+voice 回归 235 过，二者覆盖不同，不能相加；全 Flutter 回归 442 过、2 跳过；Swift 模拟器产出 `Mach-O 64-bit object arm64`；Android 用 API35 Kotlin 本批重编六种合同/适配器类（`HealthNotice`、`PhoneSteps`、`HealthHistory`、`ReplyShare`、`VoiceCapture`、`Commerce`，不是 MainActivity 或完整 APK）；T28 live 于 `05:59` 4 过，含真实代理哨兵，覆盖真实 T28 客户端、T30、PG17、双 Redis、直连夹具和合成设备授权，断言 `real T28 client and T30 storage enforce consent, collection, and withdrawal`。旧阶段 `unknown-join` 曾为 `24 issues found` 红态，现仅作历史记录，已被本批同源码 analyze 与回归回执替代；该 live 不能证明所有异常路径都在真机跑过。iOS 签名安装/授权/真实 HealthKit 样本、三台真机、真实健康库、Huawei 审批/签名/HMS、完整 MainActivity/APK、耗电、实际延迟/空窗率/成功率、HRV 缺失原因、固定 SHA CI 和生产发布均未签收。宿主日志只用于本次回执，不是 CI 合同或干净 clone 的必需文件；本层计数、耗时和命令输出不构成文档静态契约。

- 固定基线事实以 `f60ace3` 为准；候选实现必须单独标注，不得回填为基线事实。
- 任何新增模型、SDK、权限、数据字段、日志或留存期，都必须在 `data-inventory.md` 和 `sdk-model-review-checklist.md` 同步登记。
- 发现跨卡问题时，在 `docs/CHANGES.md` 仅追加新行，不删除、不覆盖其他卡已有进度。
- 正式发布版本需冻结文档哈希、协议版本、同意用途版本、供应商证据编号和备案/授权附件索引。
