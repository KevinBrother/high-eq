# T26 Flutter 训练旅程宿主桥

合装 `app/tool/t26/plan_journey_test.dart` 及其依赖后，在宿主机准备 Go 1.26、PATH 上的 Flutter SDK 和 `app/.dart_tool/package_config.json`。Go 测试启动真实应用路由和 T19 合成模型夹具，Flutter 走回环 HTTP。

为每次运行准备独占、可销毁的 PostgreSQL 17 数据库与两个独立 Redis 实例。数据库须无用户、模型路由须为空。存储地址均使用带显式端口的回环 IP，例如 `127.0.0.1`。账本 Redis 使用 DB 0，首次绑定时须为空，并启用 `appendonly yes`、`appendfsync always`、`maxmemory-policy noeviction`、`no-appendfsync-on-rewrite no` 和 `aof-load-truncated no`。

在宿主环境提供 `APP_ENV=development`、`DATABASE_URL`、`REDIS_URL`、`LEDGER_URL`、本次运行新生成的 32 字节 Base64 `FIELD_KEY_BASE64` 和正整数 `BACKUP_RETENTION_DAYS`。`DATABASE_URL` 须含数据库名和用户名，可附 `sslmode=disable`。如需 PostgreSQL 密码，将本次运行的临时密码放在 URL 中。

```sh
cd server
T19_DISPOSABLE=yes go test -tags integration,t26flutter -count=1 -timeout=6m -v \
  -run '^TestT26NewUserPlanFlutter$' ./internal/service
```

未显式设置 `T19_DISPOSABLE=yes` 时，入口会跳过。Go 仅向 Flutter 提供应用所需的 `T26_ORIGIN` 和一次性 `T26_LOGIN_PROOF`，子进程时限为 3 分钟。Flutter 使用测试专用 live binding 推进真实时间。HTTP 客户端仅接受数值回环地址，直连并拒绝跟随重定向。

## 阶段回执

Go 按 `login → assessment → plan → chat → score` 识别完整的固定标记。收到首条标记前显示 `stage=unreported`。子进程的原始标准输出和标准错误不进入 Go 回执。本入口屏蔽常规运行时请求日志。对练或评分失败时，Go 仅在核实账号属于本次合成 Apple 身份后，补充只读计数 `sessions`、`saved_turns` 和 `scores`。已保存轮次必须有同一消息 ID、序号相邻的用户发言和回复。回执和计数不含标识符、凭据或对话正文。

正式测试通过 `WLEIS_CONFIG_PATH` 加载仓内 `server/internal/service/testdata/t26_assessment.yaml`。Flutter 在测评页等待同意按钮可点，逐题点选并核对页面前进，第 16 题后选择家人场景，确认选中后提交。总分和复测提示出现后，等「进入练习」按钮可点，再在原有 `plan` 阶段点按。

测评细阶段依次为 `load`、`answer`、`scene`、`submit`、`continueReady`。

对练细阶段依次为 `openPlan`（点今日计划关卡）、`planOpened`（已进大厅，等授权或聊天）、`consent`（等待确认授权后进入聊天，已有授权时跳过）、`chatInput`（聊天已打开，等待输入可用）、`send`（点击发送）、`awaitReply`（发送后等待聊天读回）、`verifyReply`（核对本场已保存的一问一答）、`revealFinish`（检查并滚动到评分按钮）。`finish_before_scroll=hit|miss` 表示评分按钮滚动前的命中状态。

评分细阶段依次为 `finish`（点击结束并评分）、`feedback`（检查整场反馈及合成 NVC 总分）、`returnLobby`（等待评分页的 AppBar 返回按钮）、`lobbyCurrent`（等待原大厅成为当前路由且退场动画结束）、`lobbyBack`（等待原大厅的 AppBar 返回按钮）、`returnPlan`（等待原首页成为当前路由且退场动画结束）、`planCompletion`（等待原计划项刷新出已完成标签）、`revealCompletion`（按需滚动并确认标签可见）、`readback`、`verified`（已核对同一计划项和会话的 HTTP 读回）。Go 随后以只读事务核对账号、16 题及结果、计划关卡、对话、评分投影及单次计费。

## 宿主交接

- **既有宿主证据**：最近一次非跳过运行已完成真实 SSE、已保存消息核对和整场反馈分数校验，8.39 秒时退出于 `stage=score, phase=returnPlan, finish_before_scroll=hit`。只读计数为 `sessions=1 saved_turns=1 scores=1`。该次回执未区分第二次返回点击、计划刷新或标签滚动。
- **当前归档已验**：离线 Go 单文件回执回归先在新增 `lobbyCurrent` 阶段失败，更新解析后 5 项通过。Dart 和 Go 格式检查通过。代码审查确认原逻辑可在大厅标题刚可命中时就全局查找返回按钮。当前旅程记录进入对练前的原首页、原大厅路由，并等待两次正式返回各自的实际状态。
- **待宿主补验**：当前归档缺少 `app/.dart_tool/package_config.json`，Flutter CLI 在加载测试前因 SDK 的 `engine.stamp` 无写权限退出。本地 Go 1.22.6 也无法编译需要 Go 1.26 的服务包。宿主准备好依赖后，从 `app` 运行 `flutter test --no-pub test/growth/demo_plan_flow_test.dart test/practice/t26_viewport_test.dart test/practice/pending_plan_gesture_test.dart`。随后用一次性独占存储运行上面的 Go 正式入口，要求非跳过通过、收到 `stage=score, phase=verified`、通过 Go 持久化核对。若失败，只交接固定阶段、评分按钮滚动前命中状态和账号范围内计数。若停在 `planCompletion`，复核原首页返回后的计划刷新。

宿主桥使用正式 Flutter 界面、真实 HTTP 和 SSE，账号、发言和模型响应均为合成夹具。物理真机、真实供应商和正式发布仍是独立验收。

### 宿主验收与 CI（2026-11-24）

在各自全新的 PostgreSQL 17、普通 Redis 和独立 AOF Redis 上，宿主连续取得两次非跳过的 `TestT26NewUserPlanFlutter` 通过；第二次用时 9.53 秒。两次均走正式 Flutter 控件、Go 用户接口与数据库读回，不是视口模拟用例的结果。标准 Flutter 全量 490 通过、2 跳过，静态分析无问题。上述 SDK 写入限制属于分段实施环境，不是最终宿主结果。外部身份供应商、授权量表、真人、真机与生产未在此验收中使用。

#### 正式工作流

在同一台 Ubuntu runner 上，工作流设置 Go 后先执行 `bash app/tool/t26/ci.sh --offline-receipts`。此入口检查 `TestT26FixtureFailureReceipt`、测评夹具和阶段回执，无需 Flutter 或存储，要求选中的每个 Go 顶层测试及服务包通过。

随后工作流准备 Flutter 和锁定的依赖，执行 `bash app/tool/t26/ci.sh`。此入口为本次旅程创建临时回环存储，按 Go 的退出码、精确测试名和包级终态判定，跳过不算通过。CI 摘要仅显示允许的旅程阶段、夹具及 PostgreSQL 回查错误类别和账号范围内计数。回查断言在摘要中只显示 `error=assertion` 类别，原始 Go 输出保存在临时日志中，运行结束后清理。见 [GitHub 工作流](../../../.github/workflows/t26-new-user-plan.yml)。

宿主以 Go 1.26 实跑了离线入口。首次运行因误用了不存在的测试名而退出 1；改为实际声明的 `TestT26FlutterChatPhaseReceiptWithExistingConsent` 后，7 个精确顶层测试和服务包均通过。另有 9 项 CI 编排与声明一致性检查（`python3 -B app/tool/t26/test_ci.py`）及 11 项 Go 结果解析检查通过。托管环境的完整旅程仍须按发布提交 SHA 验证。

### Redis 诊断交接

正式 Go 入口在独立子进程中运行夹具。该进程关闭 go-redis 的内部日志。普通 Redis 不可连接时，夹具输出固定阶段回执 `T26 fixture: stage=start_runtime error=connection` 并判为失败。外层测试保留原测试名和诊断来源位置。

- **既有归档回归**：自定义 Dialer 注入合成错误，实际 go-redis 客户端触发拨号日志。回归在修复前检测到合成地址和错误文本，修复后核对退出码 `1`、固定回执及原始诊断缺席。对照用例验证夹具退出后外层客户端仍有默认日志。`TestT26FixtureFailureReceipt` 通过 race 检查，合成预检的 JSON 事件归在正式测试名下。
- **既有归档验证限制**：T19 两个入口编译成功，并按预期跳过存储集成。服务端全量测试中的 `TestCompatibleChat/text` 因沙箱拒绝绑定回环端口而失败。
- **宿主已验**：本次交接使用同一版最新 Go 源码，正式 `TestT26NewUserPlanFlutter` 非跳过通过，用时 16.97 秒，回执到达 `stage=score, phase=verified`。失败复验另起一套 PostgreSQL 17、普通 Redis 和独立 AOF Redis，只停本次的普通 Redis，并绑定占住它原先的回环端口且不监听。正式 `TestT26NewUserPlanFlutter` 顶层失败，Go 退出码为 `1`，仅报告固定的 `T26 fixture: stage=start_runtime error=connection` 诊断，无端口、原始连接信息或数据库诊断。原 T19 在另一套临时库中取得精确顶层 `PASS`。

#### 在宿主复验普通 Redis 不可连接

1. 按本文开头准备 Flutter 依赖及本次独占的 PostgreSQL 17、普通 Redis 和 AOF 账本 Redis。确认三者启动后，记下普通 Redis 的回环端口，只停止这个普通 Redis 实例。保留数据库和账本 Redis 运行。
2. 将 `bad_cache_port` 设为记下的端口。在一个 shell 运行下列命令，等出现确认消息后保持进程运行。`bind` 占住端口且不监听，若绑定失败则先核对本次专用端口。

   ```sh
   python3 -I -B - "${bad_cache_port:?set the stopped disposable cache port}" <<'PY'
   import signal
   import socket
   import sys

   with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as guard:
       guard.bind(("127.0.0.1", int(sys.argv[1])))
       print("T26 disposable cache port reserved without listening", flush=True)
       signal.pause()
   PY
   ```

3. 在另一 shell 设置同一个 `bad_cache_port`，使用本次独占环境的 `DATABASE_URL`、`LEDGER_URL`、`FIELD_KEY_BASE64` 和 `BACKUP_RETENTION_DAYS`，从 `server` 运行下列检查。命令只输出固定的成功确认，退出时清理临时回执。检查结束后用 Ctrl+C 释放端口，并清理本次存储。

   ```sh
   (
     set +x +v
     set -eu
     : "${bad_cache_port:?set the stopped disposable cache port}"
     umask 077
     receipt=$(mktemp)
     trap 'rm -f "$receipt"' EXIT
     code=0
     T19_DISPOSABLE=yes APP_ENV=development REDIS_URL="redis://127.0.0.1:$bad_cache_port/0" \
       go test -tags integration,t26flutter -count=1 -timeout=6m -v \
       -run '^TestT26NewUserPlanFlutter$' ./internal/service >"$receipt" 2>&1 || code=$?
     test "$code" -eq 1
     grep -Eq '^--- FAIL: TestT26NewUserPlanFlutter \(' "$receipt"
     grep -Eq '(^|:[0-9]+: )T26 fixture: stage=start_runtime error=connection$' "$receipt"
     if grep -Fq "127.0.0.1:$bad_cache_port" "$receipt" ||
       grep -Eq 'failed to dial after|dial tcp|connection refused|rediss?://|postgres(ql)?://|failed to connect|SQLSTATE|T26 readback:|error=database' "$receipt"; then
       exit 1
     fi
     printf '%s\n' 'T26 verified: startup failed with a safe Redis connection receipt'
   )
   ```
