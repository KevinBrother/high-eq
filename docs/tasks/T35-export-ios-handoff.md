# T35 正式隐私页导出与 iOS 交接

截至 **2026-11-24 18:28 CST**，宿主已验证待发布冻结切片的正式 HTTP 导出、离线归属门禁和独立 iOS Simulator 探针。导出切片仍待独审、提交、推送和云 CI，尚未上线或由用户签收。上一账号卡 `7332045` 已发布且云 CI 通过，其回执属于上一卡。

当前切片已实现 `GET /v1/me/export`。ZIP 首条为 `manifest.json`，后接实际的 13 个 JSON 分区，包含 `chat_imports`。样例也列出清单和全部 13 个分区，各分区用空数组示范结构。通用单条删除 `DELETE /v1/me/data/{kind}/{id}` 当前仍返回 `501 not_implemented`，记录选择交付留给后续卡。参见 [OpenAPI 契约](../api/app.yaml)和 [T35 候选发布核对](../compliance/qa.md#t35-候选发布核对)。

「我的 → 隐私与个人数据 → 导出我的数据」仅在已确认账号状态的普通账号分支显示。正式页面复用账号资料、更正时区及注销入口。下载使用当前登录凭证，要求 HTTP 200 和 `application/zip`，写入当前账号散列命名空间。客户端验证清单与实际分区、中央目录、本地条目、数据描述符、解压长度及 CRC 后才发布暂存 ZIP。

用户取消下载、接受页面退场或切换账号时，请求中止，尚未开始的系统交付也随之取消。系统面板打开后，应用保留源 ZIP 直到系统回执。取消或完成后清理本次文件。同账号在进程中断后再次导出时，先按所有权记录回收残留，再开始网络请求。系统已接手的目标文件由系统或接收应用持有。当前设备或构建不支持系统交付时显示不可用。

## 宿主已验

| 验证 | 宿主回执与覆盖范围 |
| --- | --- |
| 正式页面与真实 HTTP | 两个合成账号在实际 `HighEqApp` 上登录并导出。真实 Go 服务使用独占 PostgreSQL 17、缓存 Redis 和独立 AOF Redis。接收器读到两份 ZIP，分别与当次真实 HTTP 响应的 SHA-256 匹配。核对首条清单、13 个分区、本人测评、标记、派生计划和跨账号隔离。六阶段通过，最终为 `T35_EXPORT_RESULT=PASS`。 |
| 离线测评归属 | `TestT35ExportAssessmentOwnership` 顶级通过且无跳过。`gate.sh export-ownership` 通过。分别对两个账号调换测评行，两个错包被拒。合成 ZIP 保留其余分区的原始内容，并按各自交付的 ZIP 重算有效 HTTP 响应摘要。 |
| 权限、服务与流式门禁 | 门禁取得 12 个独立顶级通过回执。实服回归覆盖 7 个核心用例及 `TestPracticeWire` 的两个精确子项。覆盖三业务使用同一请求编号，以及画像请求返回 503 后重登换材料返回 409，调用数和扣费均无增加。同材料可重试，重复导出的分组稳定，旧缺绑定的重放被拒。新增迁移完成 UP → DOWN 一层 → UP，删除登记屏障与真实 `TestRoutingStore` 通过。 |
| 全量与相关回归 | Flutter 全量 574 通过、2 跳过，analyze 无问题，Go vet/race 通过，OAS 66 + 18 检查通过。app/admin 契约生成的 Go、Flutter 产物均匹配。T26 正式评分持久化、T27 100 + 1 分页和级联实服通过。 |
| 完整 Runner 构建 | 正式 Runner 在宿主离线构建成功，产物为 Debug arm64 Simulator，未签名。 |
| 独立 iOS 系统面板 | 在新建的 iPhone 17 / iOS 26.5 Simulator 中，独立 UIKit 探针直接使用 Runner 的生产 Swift 桥，真实 XCTest 3 项通过、0 失败、0 跳过。覆盖私有 `tmp` 和 `Library/Caches` 各一次面板呈现及取消，以及越界和符号链接拒绝。探针的合成夹具 ZIP 只含 `fixture.txt`。 |
| 真实 Runner 的 Flutter 通道 | 使用测试专属 Dart 入口，经未替换的 AppDelegate 通道呈现系统面板、取消并核对源文件持有和清理。21.520 秒，1 项通过、0 跳过，`T35_RUNNER_EXPORT_RESULT=PASS`。 |
| Simulator 本机「文件」读回 | 独立 UIKit 探针通过系统动作保存至本机，完成后清除源 ZIP、重启探针，经系统文件选择器打开外部同名目标，141 字节及 SHA-256 一致。49.720 秒，1 项通过、0 跳过，`T35_LOCAL_FILES_RESULT=PASS`。 |

## 待验与发布状态

- 三层证据来自不同运行：正式 A/B 实服页面使用合成接收器；完整 Simulator Runner 使用测试专属入口与真实通道；本机文件读回使用合成 ZIP 与真实系统选择器。尚未把正式账号页到真实 iPhone「文件」验证为同一条旅程。早期实跑先遇到界面只匹配英文动作，随后点静态文本未返回文件；修订后匹配双语动作、点选文件单元格并在需要时确认「打开」。
- **真机、iCloud、对外分享和用户签收待验。** 需在签名真机包上核对系统交付、运行时文件描述符和账号绑定。Android 暂缓。

完整 Runner 的 Flutter 原生通道另有[一次性模拟器复验命令](../../app/tool/t35/ios_export/README.md#正式-runner-flutter-通道验收)。

## 正式账号页实服导出旅程

实服入口使用临时目录启动独占 PostgreSQL 17、缓存 Redis 和独立 AOF Redis，确认删除账本的 `WAITAOF` 回执，再启动接线正式 Runtime、迁移及 Gin 路由的 Go 测试。测试使用开发身份供应商和禁用支付配置。两个合成账号通过业务路由提交不同答卷并创建标记，数据库读回确认标记归属和测评派生计划已持久化。各账号以本人的会话从 `GET /v1/assessments` 回读预期结果。[实服入口](../../app/tool/t35-privacy/export_journey.py)

实际 `HighEqApp` 点击正式隐私页的导出按钮，通过真实环回 HTTP 下载，以正式传输、ZIP 校验和私有暂存代码处理响应。测试用内存登录存储和注入的临时目录。iOS MethodChannel 由严格的合成接收端模拟，检查路径、MIME、所有权记录及 ZIP 字节，再模拟呈现通知和最终回执。A 退场并显示登录页后才切到 B。Go 从接收器传回的两份 ZIP 核对相应 HTTP 响应摘要，逐条读完整 ZIP，核对 `assessments.json` 恰有本人一条测评，包含正确的答卷、量表版本、分数和时间。核对本人标记和 `growth.json` 内引用本人测评的派生计划，并逐分区检查另一账号的标识、标记和测评 ID。临时存储和测试副本随运行回收。

### 宿主命令与回执

从仓库根目录以非 root 用户运行。需要可写的工作区和临时目录、IPv4 loopback、Go 1.26、Flutter 3.38.10、PostgreSQL 17 的 `postgres` 与 `initdb`，以及支持 `WAITAOF` 的 Redis。GitHub 作业复用 T27 的 Redis 8.2.0 安装脚本。先将正确版本的 Go 和 Flutter 放入 `PATH`，再准备锁定依赖、Flutter engine 和 Go 模块缓存。导出命令创建独占存储进程，使用合成身份和自生成的临时存储配置。

```sh
(cd app && flutter pub get --enforce-lockfile)
(cd server && go mod download)
bash app/tool/t35-privacy/gate.sh export-ownership
python3 -B app/tool/t35-privacy/export_journey.py \
  --pg-bin /path/to/postgresql-17/bin --redis /path/to/redis-server \
  --go /path/to/go1.26/bin/go --flutter /path/to/flutter/bin/flutter
```

CI 作业先运行离线归属门禁，再运行正式 HTTP 旅程。离线门禁要求 `PASS: TestT35ExportAssessmentOwnership`、`T35 privacy gate export-ownership PASS` 和退出码 0。见 [Formal account export over real HTTP](../../.github/workflows/t35-privacy.yml)。

实服旅程要求 Go 精确测试 `TestT35FormalAccountExportJourney` 的顶级测试与包通过事件、退出码 0，并依次给出下列回执。

```text
PASS(service.runtime)
PASS(service.seed)
PASS(page.account-a)
PASS(page.account-b)
PASS(receive.wire-and-inventory)
PASS(receive.account-isolation)
T35_EXPORT_RESULT=PASS
```

缺少前置条件时返回 `NOT RUN(<阶段>)` 和状态码 2，例如 `NOT RUN(postgres.binary)`。跳过、空选、仅有子测试回执、阶段缺失、重复、乱序或进程失败均会被拒。`T35_EXPORT_RESULT=PASS` 在一次性存储和临时目录清理成功后才发出。

T26/T27 实服复跑在配置隔离存储后，从根目录运行 `bash app/tool/t35-privacy/gate.sh legacy`。见[隐私入口交接的隔离存储配置](T35-privacy-profile-closure.md#宿主复验)。

## Flutter 与离线复跑

准备锁定依赖后，从仓库根目录运行现有回归。独立 Flutter Widget 旅程使用合成 HTTP 响应、临时目录和系统面板回执，覆盖分块暂存、损坏 ZIP 拒绝、取消 HTTP、退场、切号、平台回执和不支持平台。

```sh
(cd app && flutter test --no-pub -r expanded test/privacy/export_journey_test.dart)
(cd app && flutter test --no-pub -r expanded test/privacy)
(cd app && flutter test --no-pub -r expanded test/growth test/practice test/contacts test/onboarding tool/t27/history_journey_support_test.dart)
(cd app && flutter test --no-pub)
(cd app && dart analyze lib test tool/t26/plan_journey_test.dart tool/t27/history_journey_test.dart tool/t35/export_check.dart)
(cd app && dart tool/t35/export_check.dart "${TMPDIR:-/tmp}")
python3 -B -m unittest discover -s app/tool/t35-privacy -p 'test_*.py'
python3 -B -m unittest discover -s app/tool/t27 -p 'test_*.py'
```

Dart 离线检查的成功回执为 `Account ZIP, delivery lifetime and cold recovery passed`，覆盖 13 分区 ZIP、损坏 ZIP、交付持有、跨账号清理和冷启动回收。

## iOS Simulator 复跑

从仓库根目录执行。完整 Runner 构建需要已缓存的 Flutter engine、锁定依赖和 iOS 插件的 Swift Package 依赖。以下命令供宿主复跑，`--config-only` 为正式入口生成 Simulator 构建配置。

```sh
(
  set -e
  cd app
  flutter build ios --config-only --simulator --debug --no-pub
  xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner \
    -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath build/t35-export-runner \
    -disableAutomaticPackageResolution -skipPackageUpdates \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
)
```

独立探针的 `--build-only` 模式执行 Swift 类型检查、编译及链接，无需启动 Simulator。运行时模式新建一个 iPhone 17 / iOS 26.5 Simulator，检查退出码 0 和 `T35 Simulator acceptance passed: 3 passed, 0 failed, 0 skipped`。

```sh
bash app/tool/t35/ios_export_simulator.sh --build-only
bash app/tool/t35/ios_export_simulator.sh \
  com.apple.CoreSimulator.SimRuntime.iOS-26-5 \
  com.apple.CoreSimulator.SimDeviceType.iPhone-17
```

本机「文件」的独立验收使用下列模式。定位器修复后，需确认退出码 0、1 项通过、0 项失败、0 项跳过，以及清理 Simulator 后发出的 `T35_LOCAL_FILES_RESULT=PASS`。结果包和日志位置由脚本输出。保存和读回步骤、141 字节夹具及预期 SHA-256 见 [iOS 探针验收说明](../../app/tool/t35/ios_export/README.md#存储到本机文件的独立验收)。

```sh
bash app/tool/t35/ios_export_simulator.sh --local-files-only \
  com.apple.CoreSimulator.SimRuntime.iOS-26-5 \
  com.apple.CoreSimulator.SimDeviceType.iPhone-17
```

此前的 Swift 路径策略与 Runner 生产桥对象编译仍可按下面的命令复跑。目标编译使用本机 Xcode SDK 和已缓存的 Flutter iOS framework。

```sh
t35_swift_scratch=$(mktemp -d)
swiftc -module-cache-path "$t35_swift_scratch/modules" \
  app/ios/Runner/PrivacyExportFiles.swift app/tool/t35/ios/main.swift \
  -o "$t35_swift_scratch/ios-export-policy"
"$t35_swift_scratch/ios-export-policy" "$t35_swift_scratch"

t35_ios_sdk=$(xcrun --sdk iphoneos --show-sdk-path)
t35_flutter_bin=$(command -v flutter)
t35_ios_engine="${t35_flutter_bin%/bin/flutter}/bin/cache/artifacts/engine/ios/Flutter.xcframework/ios-arm64"
xcrun --sdk iphoneos swiftc -swift-version 5 -sdk "$t35_ios_sdk" \
  -target arm64-apple-ios15.0 -F "$t35_ios_engine" \
  -module-cache-path "$t35_swift_scratch/ios-modules" -parse-as-library \
  -whole-module-optimization -emit-object \
  app/ios/Runner/PrivacyExportFiles.swift app/ios/Runner/PrivacyExportShare.swift \
  app/ios/Runner/MobileCommerce.swift -o "$t35_swift_scratch/ios-export-arm64.o"
```

## 历史回归记录

- **面板状态。** 宿主首轮在合成接收器读到 ZIP 后查找「请在系统面板中完成保存或分享。」失败。接收 I/O 可在下一帧前完成。修正后，提交交付先显示「正在打开系统面板…」，按请求 ID 收到呈现通知后才显示等待文案。正式旅程分别验证 A、B 在回执前持有 ZIP、无成功提示，最终回执后清理再报成功。本页所列宿主实服通过回执覆盖这条路径。
- **切号。** 旧旅程在 A → 未登录 → B 时触发 `PracticeHomeRoute.build` 的 Riverpod 构建期刷新异常。以登录租约为键创建子容器后，同一登录的练习、成长、关系人及场景共享依赖，退役旧导航时同步退役子容器。Widget 回归检查 A 取消和残片清理、只交付 B ZIP、A 的迟到回执只清理 A 的暂存文件，并且 B 页面无 A 的成功提示。
- **归属正反例。** 旧离线核验接受两个互换测评的错包。修复后，两个原包通过，两个错包被拒。回归还覆盖保留本人 ID 时替换答卷或分数、删除或重复测评、互换或删除派生计划、外账号测评 ID 混入其他分区。
- **历史环境限制。** 旧归档的 Flutter 定向和全量尝试曾在共享 SDK 的 `engine.stamp` 写入阶段退出。上方宿主回执记录了后续冻结切片的实际全量和实服结果。

## 本次文档归档复核

- **已验。** T35 的 8 项和 T27 的 26 项 Python 离线回归通过，两支导出脚本的 Bash 语法检查通过。Swift 合成路径策略检查通过，探针的 `--build-only` 完成生产桥类型检查和 XCTest 编译链接。
- **本次未复验。** 归档默认 Go 1.22.6，离线门禁未取得 Go 1.26 的顶级测试回执。Dart 离线脚本因缺少本归档的 Flutter 包配置，在解析项目包时退出。本次没有启动存储进程、Simulator 或云作业，正式实服、完整 Runner 构建与三项系统面板通过均采用上方注明日期的宿主证据。
