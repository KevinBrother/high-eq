# T34 运行手册

## 入口

在含本卡完整历史的仓库根执行；需要 Git、Bash、Python 3.10+、jq、Compose v2.33+ 和本机 Linux Docker Engine（或 Desktop 的 Linux 引擎）。构建阶段需要访问公共基础镜像和 Go/Flutter 依赖，运行期拓扑全部使用 Docker internal 网络。

| 命令 | 用途 | 退出后的资源 |
|---|---|---|
| `infra/t34/accept.sh --config-only` | 完整 T34 离线测试套件 + test/production 两套 Compose 解析 + runtime/schema 锁定；不创建容器 | 无 |
| `infra/t34/accept.sh` | 一次性合成验收：构建、发布/回滚、备份、隔离恢复、门禁故障注入、告警送达失败和最终开放 | 自动销毁 |
| `infra/t34/accept.sh --preview` | 同一验收，通过后在随机 `127.0.0.1` 端口临时开放 Web | `Ctrl-C` 后销毁 |
| `T34_ALLOW_PERSISTENT_TEST=1 infra/t34/accept.sh --stage-test` | 需显式授权的本地持久测试环境；固定 Compose 项目 `t34-synthetic-stage` | 成功后保留，必须手工销毁 |
| `infra/t34/accept.sh --ci-staging` | 仅允许 GitHub Actions 自托管 runner；运行隔离合成 staging，固定 Compose 项目 `t34-ci-staging`，不是真实部署/生产签收 | 首次初始化，后续原位更新；失败时仅在证据一致时回滚镜像，否则拒开并保留持久资源 |
| `infra/t34/accept.sh --destroy-stage` | 只销毁固定本地 stage 项目、其卷和 `t34-synthetic-stage/*:local` 镜像 | 无 |

本地持久 stage 只允许非 CI 的本机执行，并要求 `T34_ALLOW_PERSISTENT_TEST=1`；唯一宿主端口是 Compose 分配的 `127.0.0.1::8080`，不会监听公网地址。验收失败时仍清理本次启动的资源；只有完整走完并打印 `synthetic-pass` 后才保留。

PR 和非 `main` 分支的 GitHub Actions 只跑完整 T34 离线契约，不运行一次性 `rehearse` 或发布准入。`main` 分支先执行 `stage-preflight`：只有固定受保护 environment `t34-synthetic-release` 中已预配 `T34_STAGING_RUNNER_LABEL`、`T34_STAGING_STATE_VOLUME`、`T34_PREVIOUS_COMMIT` 及唯一 secret `T34_DECODER_APPROVALS_JSON` 时才进入自托管、受 environment 保护的隔离合成 staging；未配置时 workflow summary 明确显示“未部署/已跳过，发布准入未执行”，不得记作发布通过。该路径只验证合成数据、门禁和恢复闭环，**不是真实部署，也不是生产签收**。staging 只接受 `CI=true`、`GITHUB_ACTIONS=true`、`RUNNER_ENVIRONMENT=self-hosted`，除 decoder 审批外不使用 secrets，也不使用 SSH、云凭据、真实告警接收端或生产门禁开关。

### 恢复 decoder 的精确发布审批

发布准入不能只看可改的运行回执、manifest 或候选代码自己写出的“已通过”标记。每次 `release.validate_release()` 都从冻结的 Git 对象物化候选和前版源树，分别计算并绑定：

- 工件摘要：`server/`、`admin/` 和 `infra/t34/` 的实际文件字节、相对路径及执行位；用于阻止 decoder 摘要未变但待发布工件已被替换。
- decoder 摘要：从 `training`、`fieldcrypt`、`privacy`、`scoring`、`reviews`、`events` 出发，动态追踪内部 import 闭包，覆盖生产 Go 文件、包内非测试资源以及 `server/go.mod`、`server/go.sum` 的原始字节。注释和换行同样参与摘要，因为 Go 自动分号插入与 `//go:embed` 都能改变行为；无法从字节安全证明等价时选择 fail closed。

外部审批文件必须按“工件摘要 + decoder 摘要”的精确二元组同时批准候选和前版，文件须为 checkout 外的绝对路径、普通非 symlink 文件且不可由 group/other 写入。CI 只从受保护 environment 的 `T34_DECODER_APPROVALS_JSON` 将审批物化到本次 run/attempt 唯一临时路径，完成配置校验、staging 或 proof 后无论成败都删除。旧审批不能覆盖任何 decoder 字节变化；合法的新 decoder 版本必须重新取得与两个真实工件精确匹配的新审批才会放行。

审批 JSON 本身不是密码学签名，也不能把候选可改代码当作唯一信任锚。正式信任边界是受保护 environment 的审批人、受保护的 `main` workflow/发布控制器，以及 checkout 外保存的审批内容；候选代码只负责计算事实并 fail closed。GitHub environment、审批人轮换、secret 托管和发布控制器在 Linux/GitHub 上尚未实跑，不能把本地合成探针当作线上审批链签收。

### 固定 CI staging：状态归属与故障恢复

`T34_STAGING_STATE_VOLUME` 必须是项目方预先创建的本地 Docker 命名卷（`local` 驱动且无额外挂载选项），不能是宿主路径或挂载规格。必须带以下标签：

- `cn.higheq.t34.staging-owner=t34-ci-staging`
- `cn.higheq.t34.staging-role=state`
- `cn.higheq.t34.state-instance=<本卷新生成且永不复用的 64 位小写十六进制值>`

由受信任的预配方在 **runner 服务环境** 设置 `T34_STAGING_RECOVERY_DIR`，指向 checkout、构建归档、临时目录及状态卷以外的本地持久绝对路径。同一安装的历次调用必须使用同一目录。目录须归 runner 用户所有、权限 `0700`；放置同一用户所有、权限 `0600` 的 `provision.json`，四个字段均为字符串：

| 字段 | 可信预配值 |
|---|---|
| `engine_id` | 专用 daemon 的原始 `docker info --format '{{.ID}}'` 值 |
| `volume` | `T34_STAGING_STATE_VOLUME` 的精确名称 |
| `created_at` | 预配原卷时 `docker volume inspect --format '{{.CreatedAt}}' <卷名>` 的原始值 |
| `instance` | 预配时写入该卷的唯一 `state-instance` 标签值 |

不能从本次失败后恰好同名的卷补抄身份，也不能在合成作业中自动认领已有卷。目录内的锁只串行化使用同一目录的协调器；**预配方还必须提供覆盖整次调用及人工恢复的外部独占租约**，确保专用 daemon、socket、项目、原卷和恢复目录不会被其他进程写入、重建或换绑。协调器被强杀后，持租约的 runner 监管方须确认上轮遗留 CLI 和 daemon 侧已提交的服务操作全部结清，才可以交接给下轮；不能把 Python PID 退出或目录锁释放当成结清。GitHub Actions 的 concurrency 不能替代这个租约。以下保证以可信候选代码、独占 runner、以及正确实现原子 `rename` 和文件/目录 `fsync` 的本地持久文件系统为前提；不覆盖宿主管理员越权或磁盘丢失已确认持久的数据。

固定 staging 的顺序如下：

1. 更新先确认旧 API/Web 和维护消费者已停，只移除已停止的 API/Web 容器（不删卷）。初始化从空原卷、空项目开始。两条路径都在更改存储或启动 writer 前持久写入 `transition.json` 的 `pending`。镜像预检只读取本地镜像 ID、启动入口和 API 版本标签，不创建容器。固定 staging 初始化静态预检 A/B；A→B→A→B 的运行演练在独立合成环境中执行。
2. 原卷上的 `staging-state.json` 由无网络 writer 以 `0600` 写入：先同步新文件，再原子替换，最后同步状态卷目录。writer 退出状态按精确容器 ID 核对，销毁后还要核验无遗留挂载。更新若丢失写入回执，只有已核实持久写入成功且 writer 已结清，才可选择 B；若结清后确认仍是原状态，只可在关闭入口的情况下准备 A。读到 B 不等于证明写入持久。
3. 复核选中版本的本地镜像、原卷回读、PG/schema、删除根和原绝对到期时间，再走恢复票据门禁并确认服务仍停。随后将 `transition.json` 原子替换成绑定卷实例和完整状态摘要的 `committed` 收据。文件和守卫目录同步成功并复核原卷归属后，初始化才执行真实 runtime 的 HTTP 404/200/401 检查并复核恢复数据。随后启动维护消费者和选中版本的 API/Web，核对实际运行镜像 ID、Web bundle、release 文件、同源 API 健康和回环端口。回滚 A 遵循相同的放行顺序。运行检查失败时关停服务。凭据、字段密钥、challenge 和 token 不打印、不上传。

**恢复行为：** 守卫收尾不再删除标记。若替换收据后目录 `fsync` 失败，本轮拒开并报人工核验；下轮只有重新同步目录成功、确认 `committed` 收据精确匹配可信原卷状态，且重新通过上述发布检查，才可收敛。若只看到 `pending`、缺失/不匹配的收据（空卷且没有项目的首次初始化除外）、旧版 `unresolved`，或发现遗留 writer，则拒开并保留持久资产。关停查不到不能报 `serving_fenced=true`。已有状态但无新版收据的安装不自动采用；操作员须持独占租约，停流并确认旧进程与 writer 已结清，再用可信原卷、发布记录和持久资产证据复核状态，恢复与已核验状态对应的收据（同一 runner 用户持有、`0600`，使用与发布器相同的状态编码、原子替换及同步顺序）。不要通过删除标记、重启消费者或重建卷绕过门禁。CI 不提供持久 staging 重置或销毁入口。

**待专用环境实跑（离线 mock 不能替代）：**

- 确认专用 Linux Engine/Compose 版本、私有 socket、独占租约及异常交接机制、预配 ID/原卷身份，并留存资源基线。以两份不同且 schema 兼容的不可变候选，在独立进程间隔超过 10 分钟验证 `initialized → updated`；记录实际 loopback 入口、消费者、API/Web 镜像 ID、状态 current/previous/history、PG 标记、vault 摘要、Redis 根及绝对到期时间。
- 验证初始化、更新与回滚在写前、写后/守卫提交前强杀，及守卫替换后目录同步失败；在故障现场和独立下一次调用中分别观察 API/Web 进程、维护消费者及实际端口。覆盖缺根、schema 拒绝、写入回执丢失、writer 未结清、最终复核失败；还要确认没有删除卷或更换原卷。验证真实 production overlay 继续以退出码 `78` 阻断；不向生产接流。
- 如另行运行专用一次性引擎夹具，使用自己的独立引擎和清理收据；该夹具不覆盖固定 runner 的持久守卫。

历史 `build/t34/ledger-rehearsal/release-typed.log` 记录的是上一次在一次性 Linux Docker 合成环境中的 A/B/A/B 实跑，不等价于本次持久 staging 更新实跑。当前持久更新代码和契约测试已覆盖“首次初始化后原位更新、失败恢复旧镜像、单边状态拒绝”，但尚未在具备 Docker 权限的主机完成真实连续两次部署。

**不要直接对项目根运行 `docker compose down`，也不要传入已有 DB、目录、Compose 项目名、外部 env 文件或远程 Docker context。** `accept.sh` 只从 Git 对象归档。候选默认使用 `HEAD^{tree}`，验证暂存改动时可提供完整的 `T34_CANDIDATE_TREE` tree ID。候选归档包含 `server/`、`admin/`、`infra/t34/` 和两份 T34 workflow。前版只取 `T34_PREVIOUS_COMMIT` 指定的完整 commit SHA 的 `server/`、`admin/`，配用当前 `infra/t34/`。流程不打包工作目录。临时 Docker 配置不读取 registry 登录、SSH 或云凭据。

除销毁入口外，调用前应设置：

```sh
export T34_PREVIOUS_COMMIT='<由发布控制方核对的完整前版 commit SHA>'
export T34_DECODER_APPROVALS='/absolute/path/outside-checkout/approvals.json'
infra/t34/accept.sh --config-only
```

在独占本地引擎中，可用同 schema 的合成前版和明确标记的外置测试夹具继续执行默认入口。正式前版须由发布控制方依据实际部署和受保护环境选定。仓库内没有默认前版 SHA。

## 版本、回滚与门禁

`compose.yml` 是公共拓扑，必须和 `test.yml` 或 `production.yml` 成对使用。测试 overlay 只允许合成数据；`APP_ENV=development` 是 T04 唯一可用的字段密钥提供者。Nginx 提供 T13 Flutter Web 并同源转发 `/v1/`、`/admin/v1/`；不配置真实模型、审核、商户或默认管理员。

`release.py` 先按名字和字节哈希完整迁移清单。两个 schema 不一致或缺少迁移时拒绝自动换回旧二进制，且不会进入 Compose。以本地 D13/T35 基线 `b5c89f05e2886df4ca6bdbabadac254e5736caa4` 为例，共 52 个 SQL 文件，摘要为 `d39d2b85d7a5177a46037398aedb8a4ec643fbc219a85d5cf8c9f8fb1d990ff9`。历史 `d44e8b6` 仅 48 个，缺少 `profile_inference_retryable` 与 `practice_erasure` 两对迁移。交接记录中的 `cab1c24` 与本地 `4c2d0b2` 均为 50 个，也不满足当前库的二进制回退条件。跨 schema 应先制定前向修复或独立的备份恢复方案。

固定 staging 另外校验持久 state v3 中实际在位的 `release`。即使声明的初始前版有有效审批，更新也要求当前审批索引包含实际回退对象的工件、decoder、契约版本、审批人、引用、时间和决定。跨审批文档仍保留其原始文档摘要。缺少该身份、旧状态版本或任何字段不匹配时，在改动服务前拒绝。

发布链先构建 A/B、drill、ops、sink，启动存储并验证生产锁，再执行真实 drill seed、成本查询和首份备份。完整票据必须同时绑定：

- 安装名、目标 DB/cache 服务名和本轮 challenge；
- 独立安装 UUID、45 天备份期限，以及 purpose 对应的精确删除根与绝对截止见证；
- 业务 dump 的 SHA-256；
- 恢复库中的 `ledger_binding` 与零待处理删除任务。

一次性验收的 A→B→A→B 只在经准入的同 schema 前版与当前候选之间使用真实运行容器 image ID、Web bundle、release 文件和同源 API 健康检查。回滚只切换镜像，不 down 迁移、还原 DB 或回退删除登记；跨 schema 不得自动二进制回退。部署 receipt 明确记录 `schema_digest`、`same_schema_rollback`、`runtime_composition`、`mode` 和 `production=blocked`。生产 overlay 没有测试 helper 或宿主端口，所有服务等待固定退出 78 的 `release-lock`，任何布尔开关、空文件或 CI 通过都不能解锁。

票据 version 2 区分两类用途：`purpose=initial` 只用于首次发布，`roots` 必须为空，且真实 ledger 不得已有删除根；`purpose=recovery` 只用于恢复，`roots` 必须非空、唯一，并与恢复时真实 ledger 中的全部 `deleted:*` 根完全一致。缺失、额外或重复根都 fail closed，不允许用空根绕过恢复检查。门禁不信任票据自报的 purpose，而是从受控目标独立推导：`db:cache` 只接受 `initial`，`restored:coldcache` 只接受 `recovery`，其他组合直接拒绝；票据声明的 service 也必须与受控目标一致。

## T34+D13 离线恢复清单

本地集成基线 `b5c89f05` 的 `runtime.go` SHA-256 为 `9b763c38ad658244e1c56d720179e53795300c49cfed49ef0a4243046e4253b9`。门禁同时固定 API 入口、独立分钟维护实现、原文清扫实现的精确字节，并为候选与前版分别报告原文清扫策略。前版使用不同的运行时组合时需要独立复核并更新准入清单。

`privacy.NewRegistry` 的模块均通过模块名绑定 hook。下表分别按两种参数的源码顺序列出：

| 模块清单顺序 | hook 调用顺序 |
|---|---|
| `training` | `payments.Hooks()` |
| `chat_imports` | `s.Membership.Hooks()` |
| `profiles` | `assessment.Hooks(c.Fields)` |
| `assessments` | `accounts.Hooks(c.Fields)` |
| `payments` | `training.Hooks(c.Fields)` |
| `membership` | `training.ChatImportHooks()` |
| `accounts` | `s.Profiles.Hooks()` |
| `replies` | `replies.Hooks(c.Fields)` |
| `ai_calls` | `gateway.Hooks(c.authMaster)` |
| `emotion` | `emotion.Hooks(c.Fields)` |
| `manual_marks` | `marks.Hooks(c.Fields)` |
| `reviews` | `reviews.Hooks(c.Fields)` |
| `growth` | `growth.Hooks(c.Fields, &training.Service{Fields: c.Fields})` |

组合使用 `training.Decoder(c.Fields, reviews.Decoder(c.Fields))`。
生产订阅依次为
`ProfileFeedback → Profiles.Consume`、`ReplyOutcome → Profiles.ConsumeReplyOutcome`、
`ScoreCompleted → Growth.Consume`、`AssessmentCompleted → Plans.ConsumeAssessment`、
`DrillProgressed → Plans.ConsumeDrill` 和 `ScoreCompleted → Plans.ConsumeScore`。
离线 drill 继续运行恢复验证所需的真实 growth/plan 消费者。启动清扫失败时记录固定重试事件，分钟维护在 marks 之后重试原文清扫。

D13 只删除 `chat_imports.received_at <= now−24h` 的行，事务客户端时限 10 秒，删除语句时限 5 秒。
练习活动和幂等根保留。到期原文可能从预删除快照回到恢复库，因此恢复就绪检查要在原文仍留库时验证读与导出，
再确认到期行被删除、未到期原文及四个活动根保留。行删除证据只覆盖数据库可见行。宿主真实验证见
[原生 PG/双 Redis 回归](tests/README.md#t34d13-原生恢复回归)。

受控 A 镜像演练使用一次性合成环境。每次镜像切换先关闭入口、停止上一次清扫进程，再启动独立的
`chat-sweeper`。它将清扫绑定到发布入口独立核对的 PG 实例、库与登记身份，仅删除到期 `chat_imports`。
首轮事务清扫与零到期行回查都成功后才签发就绪记录。进程每分钟重试，API 与 Web 启动依赖它健康，
发布入口在启动前、冒烟后再次验证进程与目标。清扫失败、超时或目标不一致时关闭入口并报错。
清扫保留原活动、备份和权威删除登记，恢复或回退不可重置登记的绝对到期时间。

## 监控、告警与备份

| 对象 | 取证/周期 | 留存与边界 |
|---|---|---|
| AI 成本 | `monitor` 每 300 秒只读 `ai_calls.started_at,cost_cny`，按上海自然日比较今日和之前七个完整日：`7 × 今日 > 2 × 前七日总和`。已知成本异常和未知价分别输出，互不遮蔽；离线用例锁定真实 7 条状态顺序 `normal, cost_anomaly, cost_anomaly, unpriced, normal, cost_anomaly, unpriced` | 每个非 `normal` 状态独立尝试 POST 到 `ALERT_WEBHOOK`，前一次失败不跳过同轮其他状态；任一次投递失败都令进程非零并打印 `alert_delivery_failed`。合成验收只用 internal 网络中的无日志 sink 计数，不使用真实值班路由。 |
| 本地告警 sink | `/alerts` 丢弃正文并计数，`/health` 返回计数；健康检查与验收读取均不记录 payload | 只用于自动化证明“发生了独立投递”。生产值班系统、接收人、重试策略、静默和升级时限均未配置、未验证。 |
| API/容器日志 | T04 字段白名单；Nginx 不记访问日志；DB、登记、drill、permit 关闭容器日志 | 有界 `1 MiB × 2`，禁止采集正文、URL 参数、token 或散发原始 dump、登记和 ZIP。 |
| PG17 业务库 | `backup` 每 24h 执行 `pg_dump -Fc`，临时目录校验后原子改名；健康检查要求最新快照开始时间不超过 26h | 绝对期限 45×24h，从 dump 开始计算；日扫提前一天清理，恢复入口再次拒绝到期包。`restart: unless-stopped` 使 dump 失败后的 supervisor 可被 healthcheck 识别。RPO 目标 24h，只在连续成功时成立。 |
| 日常恢复 | `ops.sh restore <snap-name>` 接受任意合法既有快照；检查目录、清单、安装身份、SHA-256、绝对期限和目标 public schema 为空，再用单事务 `pg_restore` | 综合验收入口通过 `docker compose run --rm backup restore <snapshot>` 调用该入口，不维护一份私有 `pg_restore` 实现。合成 vault 不是生产加密备份。 |
| 删除登记 | T04 `WAITAOF`、`appendfsync always`、`noeviction`、拒绝 truncated AOF；仅在独立 `ledger-net` 暴露，并启用 `requirepass` | 登记不在 PG dump 中。门禁比较身份、精确根集合、绝对截止、DB binding 和待处理任务。普通根覆盖写入后 45 天。单窗的随机根和逻辑根覆盖写入后 45 天与窗口起点后 180 天中的较晚时间。首次核验使用每次删除前后的 Redis 时钟及独立窗口截止，之后冻结通过核验的绝对截止。 |

| 普通 Redis / App 本机 | 普通缓存可重建，恢复使用新实例；设备录音、草稿和 token 不采集 | 不进业务备份，无跨环境拷贝。 |

恢复重删在临时 Redis DB 1 执行。恢复工具先从指定快照按账号、渠道、起点定位窗口，验证业务密文与随机根绑定，重算逻辑根并与删除见证核对。重删完成后只清理已验证的临时集合。历史随机根只有通过该快照证明且以预期空值和截止出现时，才纳入本次临时清理。权威 DB 0 的根集合、安装身份与绝对截止再次核验。

门禁故障注入使用同一张完整票据：先验证完整根通过，删除一个实际登记根后必须退出 1，清理 DB 1 探针副本后，权威 DB 0 仍须用原截止通过。恢复流程使用真实 T04 `Resume`、清理 hooks、ZIP 导出、正常登录路径和真实事件总线。

离线 drill 按当前生产顺序注册 13 个隐私模块与 13 个 hook，并使用真实 `events.New(data, training.Decoder(c.Fields, reviews.Decoder(c.Fields)))`。fixture 使用真实 `assessments.Submit`、`practice.Create`、`training.PlanLevelIDs`、`bus.PublishDrill`、growth consumer 与 plan service，并通过真实 `scoring.Full` 和 `Fields.Seal` 生成评分，覆盖 `activities`、`scores`、`review_requests`、`ai_calls`、`growth_scores`、`daily_plans`、`growth_drill_schedules`、review tombstone、ZIP 导出及账号注销清理；恢复后按源记录反序重放删除项，并保留源 activity/score 制造 721 小时过期投递，证明拒绝来自过期策略而非源行缺失。门禁通过后，drill 在进程内调用生产 `service.Start` 与 `runtime.Router`，通过 `httptest` 有界等待 `/v1/health` 返回 200，再用真实 router 验证已删除复盘的 `GET /v1/reviews/:id` 为 404、存活账号的 `GET /v1/me` 为 200、已注销旧会话的 `GET /v1/me` 为 401。该探针不启动 API 容器、不监听外部端口、不启动分钟维护循环。

## 隔离恢复次序

1. 冻结写入，撤销旧 permit，停止 Web、API、监控和备份；按项目标签核查仅剩存储、restored/coldcache 等允许服务。源 DB 只作对照，不原地覆盖。
2. 新建 PG 卷和空缓存，保留最新独立删除登记；核验快照来源、安装身份、SHA-256、绝对到期时间和空目标。缺登记、来源不明、时钟/TTL 异常或损坏包均保持关闭。
3. 通过唯一保留 identity、少一个删除根的故障注入验证 gate 会拒绝；离线 drill 不监听外部端口，但注册真实 growth/assessment/plan/drill consumers。恢复后确认复盘、评分、成长副本、计划、演练排期、网关关联、单窗口及注销账号/会话均消失，相邻窗口和另一账号保留。
4. 重新生成 challenge 和 recovery 票据，复验导出、721 小时过期评分、旧登录/刷新/撤销注销拒绝、最新登记覆盖和备份期限。门禁通过后由离线 drill 在进程内复用生产 runtime/router，等待 `/v1/health` 后验证已删除复盘 404、存活会话 200、已注销旧会话 401；全部通过后才启动 Web、消费者、监控和备份，并打印机器签收行。
5. 生产仍关闭。云主机、域名/TLS、值班人、KMS、商用凭据、真实告警路由、跨故障域登记连续性、备份销毁和人工双签均未验证；不能把本卡合成分支、CI 合成 staging 或 `synthetic-pass` 当作真实部署或生产签收。
6. 后续真实发布必须采用受控滚动更新和可回滚迁移，不得用销毁长期测试库、删除长期备份或重建空环境来冒充升级验证。

## 验收证据边界

离线测试覆盖 decoder 原始字节与依赖闭包漂移、精确审批、工件执行位、审批文件、发布生命周期及状态写入和回退故障注入。Linux 的运行结果应关联实际 Git tree、Compose 版本、镜像来源和服务回执。使用合成镜像时，另记标准 Dockerfile 的构建结果。固定 staging 需要独占的长生命周期验收。GitHub Actions、正式前版、外签、云/KMS 和生产验收各需自己的回执。
