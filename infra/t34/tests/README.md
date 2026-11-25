# T34 持续 staging 隔离补验

这是**宿主手动运行**的合成数据验收，不替代 `../accept.sh`、固定 CI staging 或生产签收。
归档内的自动化测试只使用内存 Mock，不启动 Docker、Compose、夹具或部署；真实补验仅在授权的独立宿主上手动执行。
既有 Compose 测试检查 YAML 源，实际 Compose 渲染仍由运行时的 `Lab.config` 检查。

```sh
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=infra/t34/tests:infra/t34 \
  python3 -m unittest discover -s infra/t34/tests -p 'test_*.py' -v
```

## 授权宿主上的真实补验

本节命令不由本归档的离线测试执行。真实补验必须在宿主外部预先创建的独立 Linux VM 或私有 Docker 引擎上手动运行，
并满足以下可审计前提；任一事实不能由预配记录或运行前核验证明时，必须安全拒开，而不是换个名字继续尝试。

- 专用 Linux daemon 拥有自己的 data-root、builder 和镜像/容器/网络/卷状态，不与本机默认 Docker、用户项目、
  共享 daemon、宿主 builder 或任何 CI staging 引擎共用。
- 只通过该引擎的私有绝对路径 `unix://` socket 接入。socket 不得被其他进程重绑、代理或转发到既有引擎，
  并由本次补验独占租约；开始后不得并发运行第二个补验或把 socket 指向另一 daemon。
- 预期 daemon ID 必须来自可信预配记录（例如基础设施工单或镜像构建平台的准入记录），不能在待验证 socket 上
  `docker info` 后现取现信。包装器会将其与实际 daemon ID 比对，并在每次变更/清理边界重新绑定。
- 引擎中除已核验的 `postgres:17.6-alpine`、`redis:8.2.0-alpine` 和受控构建缓存外，不应有业务容器、网络、
  卷或镜像。不得注入真实凭据、业务数据、生产密钥或外部 webhook；只使用本次生成的合成数据。
- 运行时不得使用 host bind mount 或 external Compose 资源；内部网络隔离，唯一暴露是 `127.0.0.1` 上的随机 web 端口。
- 禁止默认 socket、宿主 Docker、共享 builder，以及 `t34-ci-staging`、`t34-synthetic-stage`、固定 staging
  命名空间或其他项目的资源。命中同名残留对象时拒绝，不接管、不复用、不清理。
- 基础镜像和 Go/Flutter 等构建依赖应预拉取到该专用引擎的受控缓存。若构建仍需网络，只允许经独立的构建出网策略
  或私有镜像源，不得让合成运行时访问外部网络；磁盘、10 分钟以上的验证时长和失败后保留/人工复核窗口也需预配。

随机 run ID、资源名、端口和私有 owner token 只降低碰撞概率并把本次命令绑定到本次操作，**不是所有权安全边界**；
真正的边界是专用引擎、可信 daemon ID、独占 socket，以及每次变更前对资源 ID/标签的重新证明。

入口强制要求显式、非默认的独立 daemon 地址和 daemon 身份；缺失环境时在 Git 与 Docker 访问前安全拒开：

```sh
export T34_ISOLATED_STAGING_DOCKER_HOST=unix:///absolute/path/to/dedicated-docker.sock
# 只能填入可信预配系统给出的 daemon ID（标准小写 UUID，或历史 64 位小写十六进制）；不要在该 socket 上执行 docker info 反推此值。
export T34_ISOLATED_STAGING_ENGINE_ID="<trusted-provisioning-record-engine-id>"
```

- 地址只允许绝对路径的 `unix://` socket；拒绝 `tcp://`、相对路径、`/var/run/docker.sock`、
  `/run/docker.sock` 及用户默认 Docker socket。
- `T34_ISOLATED_STAGING_ENGINE_ID` 接受标准 UUID 或历史 64 位小写十六进制形状，且必须与 `docker info`
  返回的 daemon ID 原始字符串精确一致；不做大小写、连字符或十六进制规范化。
- 每次认领、变更和清理前都重新绑定该 engine，并即时复核本次私有 owner token、Compose project 与资源 ID；
  无法证明归属或对象身份时中止，不修改该对象、不清理、不接管同名资源。

在含 T34 的仓库根运行，默认以同一候选原位部署第二次；可追加 `--update-revision <兼容更新提交的完整 SHA>`：

```sh
T34_ALLOW_ISOLATED_STAGING_TEST=1 PYTHONDONTWRITEBYTECODE=1 \
  python3 infra/t34/tests/persistent_staging_accept.py "$(git rev-parse HEAD)" --previous "$T34_PREVIOUS_COMMIT"
```

若试跑的是主仓库下的独立补验归档（`src/`，相邻 `../base-tree` 是宿主提供的 Git 树），在 `src/` 运行：

```sh
T34_ALLOW_ISOLATED_STAGING_TEST=1 PYTHONDONTWRITEBYTECODE=1 \
  python3 infra/t34/tests/persistent_staging_accept.py --candidate-tree "$(cat ../base-tree)" --previous "$T34_PREVIOUS_COMMIT"
```

- `--previous <完整提交 SHA>` 必须显式指定初始兼容回滚提交。更新时真实回滚目标是 state 中的第一次部署。
  构建上下文经 `inputs.stage_inputs` 从 Git 白名单物化，不使用未跟踪文件或任意目录。
- 可选 `T34_ISOLATED_STAGING_RUN_ID` 为新生成的 **24 位小写十六进制**（例如 `openssl rand -hex 12`）；不填则自动生成。
  入口只输出 `t34-proof-<id>`、固定阶段、通过/失败与异常类型。发现同名容器（含已停止）、网络、卷（含 state）
  或镜像即拒绝，不清理旧对象。它只发布 Compose 动态分配的 `127.0.0.1:端口`，不会输出连接信息或凭据。
- 包装器复用生产 `release.run_ci_staging`，校验 `initialized → updated` receipt，以及 current/previous/history 和
  state 的稳定身份；调用 `staging.verify_storage`，比较 PG 标记行与集群标识、vault 已完成快照校验和、
  独立 Redis 删除登记根与绝对过期时间。它不做数据库全表或跨故障域备份的验收。
- 负向探针把同一 state 卷内的 `schema_digest` 改成不匹配值，再走真实 `run_ci_staging` 更新分支，
  要求生产 schema 校验以固定文本明确拒绝，并调用生产 fencing 关闭入口与消费者。拒绝前后必须保持持久资产不变：
  state（含文件标识/摘要）、PG、vault、ledger 以及 Docker 资源名称/ID/归属；容器运行状态不属于该快照，
  因为 fencing 本身会停止已确认归属的服务。确认后才恢复探针改写的 digest，不会通过删卷或重建环境制造通过结果。
- 测试覆层只添加所有权标签与用于挡住镜像隐式匿名卷的 tmpfs；使用生产 Compose、门禁和顶层发布流程，
  不允许 host bind mount 或外部资源。正常结束及可处理的退出会尝试清理验过标签和命名空间的对象；
  不清理共享基础镜像或构建缓存。清理失败会额外输出 `FAIL cleanup <异常类型>`，不会覆盖原始失败阶段；
  若被强杀或所有权/清理校验失败，按打印的 namespace 人工复核；不要清理其他项目，也不要用同一个 ID 接管残留。

**证据边界：** 两轮在同一个 Python 进程内执行，第二轮仍从持久卷读取 state。此验证不证明 runner 重启后也能更新：
`staging.apply_to_lab` 当前不回填 `BUSINESS_DUMP_SHA256`；该值非空时，`gate.sh` 才会把票据摘要与它做额外比对。
同进程保留了首轮写入的值，本测试不补写它，也不修改生产逻辑。跨进程的更新与摘要绑定需要单独验证。
生产 `verify_storage` 还使用短时合成 ledger 校验阈值；准备好构建缓存，避免第二轮慢构建超过该窗口。

## T34+D13 原生恢复回归

由宿主在隔离的一次性环境运行。使用 PostgreSQL 17 的原生客户端和两个不同的空数据库，
并准备两个独立原生 Redis 8.2 实例（普通缓存和删除登记，各自的 DB 0、DB 1 都空）。
PG 连接用户需要执行迁移、`pg_dump`、`pg_restore` 和 `pg_control_system()`。
登记 Redis 启用 `appendonly yes`、`appendfsync always`、`maxmemory-policy noeviction`、
`no-appendfsync-on-rewrite no` 和 `aof-load-truncated no`。宿主提供 Go 1.26、Python 3、
`jq`、`redis-cli`、`psql`、`pg_dump` 和 `pg_restore`。只使用本次创建的临时存储与合成连接信息，
运行后由宿主销毁。无需 Docker 或发布工作流。

```sh
export T34_SOURCE_DATABASE_URL='postgresql://t34@127.0.0.1:15432/t34_source'
export T34_RESTORE_DATABASE_URL='postgresql://t34@127.0.0.1:15432/t34_restored'
export T34_CACHE_URL='redis://127.0.0.1:16379/0'
export T34_LEDGER_URL='redis://127.0.0.1:16380/0'
PYTHONDONTWRITEBYTECODE=1 python3 infra/t34/tests/verify_backup_replay.py \
  --repo /path/to/project --candidate-tree '<包含本次改动的完整 Git tree ID>' \
  --previous "$T34_PREVIOUS_COMMIT"
```

将示例端口和库名替换成本次临时环境的值。归档内执行时，`--repo` 指向宿主用于物化候选树的 Git 仓库根。
入口从同一个不可变候选树构建 API 和 drill，并使用已审阅前版做 schema 和运行时核验。
保留完整的最终 JSON 回执。只有实际执行全部步骤才会输出 `T34+D13 native replay PASS`。

1. 用真实 T34 drill 建立删除见证所需数据，同时加入两户独立合成用户，每户各含一条 25 小时和一条 1 小时的原文以及活动根。原生 `pg_dump` 在业务删除之前完成，使用原有 manifest 校验摘要及 45 天期限。
2. 完成真实删除并冻结权威 Redis DB 0 的逐根绝对到期时间。在空 PG 恢复原备份，逐行核实双账号的原文、时间、归属、活动状态和根确实来自该备份。继续执行原有 `Resume`、事件重投拒绝、导出、会话以及恢复票据校验。重放和缺根探针分别使用核验过的登记 DB 1 副本，全程复核 DB 0。
3. 对恢复库的 `chat_imports` 持有 SHARE 锁，启动候选的真实 API，确认启动清扫记录重试并且健康检查通过。确认旧 T34 HTTP `404/200/401` 结果，再在四条原文仍存在时检查两户真实会话读取和隐私协调器的 ZIP 导出。验证有正常练习数据可读、串户读取被拒、两户各自导出可用，同时原文不可见。公开导出路由的交付与定位元数据仍归 T35。
4. 释放表锁。等待同一 API 进程的分钟任务删除两条到期行，逐条复核两条未到期原文和四个活动根原样保留。进程退出后再比对权威登记的全部绝对到期时间与原 dump 摘要。

宿主已有基础 T34 原生备份重放和 D13 单账号启动/重试证据可作对照。本归档执行了离线门禁回归和 Go 编译检查，
实际原生 PG/双 Redis 联合复跑与该候选树的发布签收待宿主完成。
