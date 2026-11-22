# T33 隐私与合规 QA（草案）

> 核对日期：2026-11-22。固定基线：`f60ace3`；候选证据：`ce479034bcba174475fa8fbc156be66a3b22ba5371b5344602f29394185d638a`（只标识早期 T33 草案，不是业务源码）。本文记录静态代码、文档和交接核对结果，不是法律意见，也不代表任何待办已由运营、平台、真机或律师完成。
>
> 结论：**未达到发布门槛。** 已完成的只是可先行材料与静态事实对表；运营资料、供应商证据、T29、T35、真机、完整法律适用性和律师意见仍为阻断项。

## 1. QA 状态说明

| 状态 | 含义 |
| --- | --- |
| `通过（静态）` | 固定基线或已明确标注的候选材料中能找到对应字段、接口、测试或文档；不代表真实环境已验收。 |
| `部分通过` | 有一部分实现或证据，但存在明确缺口。 |
| `未通过` | 当前材料与实现不一致，或关键闭环缺失。 |
| `阻断` | 上线前必须有外部资料、真机、平台、T29/T35 或律师证据才能关闭。 |

## 2. 逐项 QA

| ID | 检查项 | 证据路径 | 当前结果 | 状态 | 上线门槛/负责人 |
| --- | --- | --- | --- | --- | --- |
| QA-01 | 官方法规/平台入口是否取得一手正文、版本和日期 | `docs/compliance/official-source-register.md` | 已读取 PIPL、生成式 AI 办法、Apple 审核指南、Android Health Connect 和 MIIT 同文政策库的部分官方正文；已登记 URL 与两份正文哈希。其他来源、版本日期和业务适用性仍待补 | `部分通过` | 运营/律师补齐正文、抓取日期、证据编号和适用性意见 |
| QA-02 | 是否虚构公司名称、地址、联系方式、投诉渠道 | `docs/compliance/privacy-policy-draft.md`、`terms-of-service-draft.md` | 全部保留 `[待运营填写]`，未发现虚构主体或联系方式 | `通过（静态）` | 运营提供营业执照、地址、负责人和可达渠道 |
| QA-03 | 是否虚构商户、模型条款、授权函、备案或批准 | `docs/compliance/sdk-model-review-checklist.md`、`filings-and-authorizations.md` | 供应商、合同、WLEIS 授权、备案号和批准均未填写；只记录“待提供” | `通过（静态）` | 运营归档合同、授权函、后台回执和审批单；律师复核范围 |
| QA-04 | 数据清单是否覆盖 schema 的源记录、数值副本、关联元数据和导出/删除 | `docs/compliance/data-inventory.md`、`docs/schema.md`、`server/migrations/`、`verified-pg17-inventory.jsonl` | 依据主会话 PG17 空库全量迁移后的清单，D01–D37 已登记；其中 D01–D36 逐名覆盖 42/42 public 表/视图，D37 是 T22 设备端分享草稿、明确不计入 PG17 42 项；D32–D36 单列后台员工数据、查询视图、平台配置和额度尝试，视图不另存个人数据，后台口令/会话摘要、平台配置和内部令牌不进入 App 用户导出 | `通过（静态）` | T35 按同一清单跑导出→删除→再导出，并另验 D37 领取/过期清理；真实数据库完整测试由主会话执行 |
| QA-05 | 加密字段是否与迁移和 `fieldcrypt` 对齐 | `docs/compliance/data-inventory.md` 第 3 节、`server/internal/fieldcrypt/cipher.go` | 已列出 `*_enc` AES-GCM 字段；HMAC/摘要未误写为密文 | `通过（静态）` | 代码变更时重新扫描；密钥管理和备份由 T34 复核 |
| QA-06 | 同意 purpose 是否与 API/服务端枚举一致 | `docs/compliance/separate-consents.md`、`server/internal/accounts/consents.go`、`server/internal/api/app/routes.gen.go` | `privacy`、`terms`、`assessment`、`health`、`voice`、`audio_retention`、`practice`、`review`、`contacts`、`chat_import`、`manual_mark` 已对表 | `通过（静态）` | 正式版本和页面文案仍需运营/律师确认 |
| QA-07 | `privacy`/`terms` 是否强制开发占位版本 | `server/internal/accounts/accounts.go`、`app/lib/features/onboarding/repository.dart` | 服务端要求 `PolicyVersion=2026-11`；客户端 onboarding 写入同版本 | `通过（静态）` | 发布前替换正式版本、生效日期和通知流程 |
| QA-08 | 各敏感用途是否校验当前同意版本 | `server/internal/accounts/consents.go`、`separate-consents.md` 第 4 节 | `Granted` 只检查未撤回；除 `privacy`/`terms` 外版本非空即可 | `未通过` | 修复版本闭环并补端到端测试；产品/后端负责人 |
| QA-09 | 对练前是否写入 `practice` 单独同意 | `app/lib/features/practice/lobby.dart`、`server/internal/training/store.go` | 固定基线 `server/internal/training/` 只有 `.gitkeep`；候选计划要求有效授权，但客户端写入和候选服务端接线均须独立对表 | `未通过` | 候选合入后补客户端授权、拒绝/撤回和 E2E；T19/T29 相关负责人 |
| QA-10 | 手动标记客户端是否核对同意版本 | `app/lib/features/marks/book.dart`、`server/internal/marks/store.go` | 客户端设置 `v1` 但只检查 `granted == true`；服务端接受非空版本 | `部分通过` | 补版本校验和撤回后停写测试 |
| QA-11 | 聊天原文 24 小时删除是否闭环 | `server/migrations/20261121000200_training.up.sql`、`docs/schema.md`、`app/lib/features/replies/page.dart` | `chat_imports.original_enc`/`received_at` 仍存在；未找到自动清理函数、24 小时读取过滤、失败重试或导出排除完整证据 | `未通过` | 实现并验收读取过滤、物理清理、重试、告警和导出排除 |
| QA-12 | 回复原文不落库、关系人推断和 `reply_requests` 是否可写成基线事实 | `server/internal/training/`、`server/internal/profile/`、`server/migrations/` | 固定基线两个目录均只有 `.gitkeep`，且不存在 `*reply_requests*` 迁移；相关能力只能标候选/待对表 | `未通过` | T19/T23/T25 合入后按真实迁移和链路重新核对 |
| QA-13 | 聊天原文 24 小时删除文案是否有实现证据 | `app/lib/features/replies/page.dart`、数据清单 D13 | 页面目标存在，但自动清理、读取过滤和供应商证据未闭环 | `未通过` | 在实现和供应商证据齐全前删除或降级文案 |
| QA-14 | 设备健康权限是否被误写成基线已声明 | `app/android/app/src/main/AndroidManifest.xml`、`app/ios/Runner/Info.plist`、`Runner.entitlements` | Android Manifest 仅声明 `INTERNET`；iOS 没有 HealthKit entitlement 或 `NSHealthShareUsageDescription`。T28 候选权限未合入固定基线 | `未通过` | T28 合入后按 Manifest/Info.plist/entitlements 和真机重新验收 |
| QA-15 | 健康窗口删除、读取过滤和 180 天清理是否有静态证据 | `server/internal/emotion/privacy.go`、`window.go`、`reference.go` | 健康窗口专用删除按账号、渠道和 30 秒起点定位；180 天读取过滤与物理清理有测试覆盖 | `通过（静态）` | T35/T34 继续验收导出、恢复后重删和真机采集 |
| QA-16 | 注销冻结、撤销注销和清理协调器是否保留 | `server/internal/accounts/`、`server/internal/privacy/`、`docs/schema.md` | 冻结 15 天、撤销注销、按根清理和删除协调器均有静态路径 | `通过（静态）` | T35/T34 做端到端注销、恢复和重放测试 |
| QA-17 | 通用导出与单条删除是否真的可调用 | `server/internal/service/http.go`、`docs/api/app.yaml` | `GET /v1/me/export` 和 `DELETE /v1/me/data/:kind/:id` 不在生产路由白名单，对有效会话返回 `501 not_implemented`；测试钩子不能替代接线 | `未通过` | T35 完成生产接线和端到端覆盖 |
| QA-18 | 关系人推断/审核是否有 1 天绝对留存上限 | `server/migrations/20261121000600_gateway_admission.up.sql`、`server/internal/gateway/store.go` | 迁移只要求 `max_retention_days >= 0`；路由只比较主备/灰度相对留存，没有 `profile_inference` 或审核的 1 天绝对上限 | `未通过` | 1 天留存上限待实现/验收，并由供应商合同与运行时证据确认 |
| QA-19 | 用户权利能力是否已闭环 | `data-inventory.md`、`privacy-policy-draft.md`、T35 状态 | 通用 `GET /v1/me/export` 和 `DELETE /v1/me/data/:kind/:id` 为 `501 not_implemented`；注销冻结/撤销注销与健康窗口专用删除另列，不能据此宣称全量权利闭环 | `阻断` | T35 接线、全量覆盖、重算、防重放和恢复证明 |
| QA-20 | 用户权利是否已在客户端闭环 | `docs/compliance/privacy-policy-draft.md`、T35 状态 | 没有 `docs/tasks/T35.md`；设置页逐项撤回、全量导出/删除、注销验收未完成 | `阻断` | T35 验收；不得对外宣称权利已闭环 |
| QA-21 | 官方来源、文号、版本、日期和适用性是否完整 | `official-source-register.md` | 部分正文与 URL/哈希已取得；平台规则版本、其余法规正文、适用性和律师意见仍待补 | `部分通过` | 律师与运营按来源登记逐项关闭 |
| QA-22 | 主模型、备用/灰度模型和审核服务是否有真实证据 | `sdk-model-review-checklist.md`、`server/migrations/20261121000600_gateway_admission.up.sql` | 准入字段存在，但仓库没有真实供应商、合同、DPA、处理地、留存或删除证据 | `阻断` | 逐槽位归档合同、DPA、后台和调用证据 |
| QA-23 | WLEIS 商用授权函是否已归档 | `docs/wleis_items.md`、`filings-and-authorizations.md` | 仓库只有“已获作者商用授权”的文字，没有授权函、范围、期限或转授权证据 | `阻断` | 运营提供签章授权函并由律师复核 |
| QA-24 | 是否把未核验法规写成确定结论 | `docs/compliance/official-source-register.md`、全部 compliance 文档 | 未写备案号、批准或律师签字；已取得正文和未取得/未核验事项分开标记 | `通过（静态）` | 律师确认引用和适用性 |
| QA-25 | 是否访问真实用户数据或联系外部主体 | 本轮操作记录、仓库文件 | 未访问用户数据、未联系平台/律师、未代备案 | `通过（静态）` | 后续外部动作由运营主体执行并留痕 |
| QA-26 | 固定基线、候选证据和补丁交接是否分离 | `docs/tasks/T33.md`、归档目录 | 固定基线为 `f60ace3`，候选证据单列；主会话从归档提取补丁，本轮不生成或创建补丁 | `通过（静态）` | 主会话在归档跑完整测试并交 GPT high 复审 |
| QA-27 | 是否修改业务代码或覆盖 `docs/CHANGES.md` | 本轮交付路径、`docs/CHANGES.md` | 本轮只修订 T33 文档、契约测试和交接；跨卡问题仅追加到 `CHANGES.md` | `通过（静态）` | 主会话复核补丁范围 |
| QA-28 | T22 分享草稿是否按平台准确区分 | `../review-sharing.md`、`../sharing-evidence/ReplyShare.kt`、`../sharing-evidence/ShareController.swift`、`../sharing-evidence/ReplyInbox.swift`、`data-inventory.md` D37、`privacy-policy-draft.md` 第 7 节、`separate-consents.md` C08 | 仅基于已发布 `bc66e6e`：Android 是当前 Activity 一次性内存；iOS 是 App Group `Library/Caches/T22/incoming` 的系统完整文件保护缓存，不是业务 AES-GCM。10 分钟只拒领，不保证到点物理擦除；分享扩展不联网，未分析不上传、提交前不上传；T21 服务端未合入 | `部分通过` | 真机验证写入/替换/领取/杀进程/过期清理；T21 合入后复核服务端原文与删除链路 |
| QA-29 | 发布门槛是否关闭 | `docs/compliance/README.md` 第 5 节、本表 | 运营资料、供应商、T29、T35、真机、完整法律适用性和律师意见均未关闭 | `阻断` | 任一未关闭不得发布 |

## 3. T29 最终对表门槛

T29 尚无 `docs/tasks/T29.md` 交接。完成前不得把语音、录音、麦克风权限、3 天删除、实时提示或耗电结论写成“已实现”。最终至少核对：

1. 麦克风权限声明、申请时机、拒绝和撤回行为。`[待 T29 对表]` `[待真机复核]`
2. 音量、音调、语速的实际提取方式、有效秒数和静音处理。`[待 T29 对表]`
3. 是否上传、上传字段、30 秒聚合方式和抓包证据；不得上传音频或转写。`[待 T29 对表]`
4. 原始录音是否仅本机、绝不入库，以及本机加密和账号隔离。`[待 T29 对表]` `[待真机复核]`
5. 3 天清理在杀进程、离线、重开、换账号和过期录音场景下的行为。`[待真机复核]`
6. 录制时始终可见的状态提示，以及“可能混入他人声音”的告知。`[待 T29 对表]`
7. `voice` 和 `audio_retention` 的正式版本、触发时机、拒绝后果和撤回停采。`[待 T29 对表]`
8. 30 分钟连续录制耗电、机型、系统版本、构建 SHA 和实测边界。`[待真机复核]`
9. 会员到期、系统权限撤销、App 内撤回和后台重开时是否 fail-closed。`[待真机复核]`
10. 录音与心率对齐回放是否实际实现；会员页当前文案不得先于实现上线。`[待 T29 对表]`

## 4. T35 最终对表门槛

T35 尚无 `docs/tasks/T35.md` 交接。最终至少核对：

1. 设置页逐项展示并撤回 `health`、`voice`、`audio_retention`、`practice`、`review`、`contacts`、`chat_import`、`manual_mark`，撤回后立即停采。`[待 T35 对表]`
2. 查阅、复制/导出、更正、删除和注销的实际入口及错误处理；通用 `GET /v1/me/export` 和 `DELETE /v1/me/data/:kind/:id` 必须先完成生产接线。`[待 T35 对表]`
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
rg -n "RECORD_AUDIO|NSMicrophoneUsageDescription|ACTIVITY_RECOGNITION|READ_HEART|NSHealth" app/android app/ios
rg -n "GET /v1/me/export|DELETE /v1/me/data|not_implemented" server/internal/service/http.go
python3 docs/compliance/test_t33_contract.py
```

静态检查不能替代真机、平台后台、供应商合同、官方页面或律师审阅。任何“通过（静态）”都不得写成“上线已通过”。
