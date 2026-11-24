# T35 iOS 导出系统面板验收

`MobileCommerce` 的 `shareExport` 分支调用 Runner 的 `PrivacyExportShare.present`，
再把原生回执映射成 Flutter 回执。独立 UIKit 探针直接编译 Runner 的
`PrivacyExportFiles.swift` 和 `PrivacyExportShare.swift`，走正式路径校验、
`UIActivityViewController` 与系统完成回调。夹具是在探针 App 沙箱里生成的 ZIP，
只有一项 `fixture.txt`，内容为 `T35 synthetic export` 加换行。

## 本归档已验

- 改动前，`--build-only` 因脚本引用归档中不存在的 `PrivacyExport.swift` 失败。
  检查 Xcode Sources 阶段也复现了旧引用。改动后，探针和 Runner 的 Sources 阶段
  都解析到同一对实际 Swift 文件，两个工程均通过 `plutil -lint`。
- `bash app/tool/t35/ios_export_simulator.sh --build-only` 使用归档可用的
  iPhoneSimulator SDK 27.2 对生产 Swift 文件做了 iOS 15 类型检查，并为 iOS 17
  Simulator 目标编译、链接了探针和 XCUITest 动态库。
- `app/tool/t35/ios/main.swift` 与正式 `PrivacyExportFiles.swift` 编译后在 macOS
  通过了合成路径检查，覆盖合法 ZIP、错误 MIME、越界路径和符号链接。

## 宿主复跑

在有 Xcode、`python3` 和已安装 iOS Simulator runtime 的宿主，从仓库根目录运行：

```bash
bash app/tool/t35/ios_export_simulator.sh \
  com.apple.CoreSimulator.SimRuntime.iOS-26-5 \
  com.apple.CoreSimulator.SimDeviceType.iPhone-17
```

需要换型号或 runtime 时，用相同格式传入宿主已安装的标识。脚本只创建一个新 iPhone
Simulator，后续命令和 Xcode destination 均使用该 UUID，退出时关闭并删除它。临时
目录中的 `ExportProbe.xcresult`、`xcodebuild.log` 和可用时的 `summary.json` 作为
证据保留，路径由脚本打印。失败时先查看日志和结果包。

通过条件是退出码 0、结果包记录 3 项通过、0 项失败、0 项跳过，脚本输出
`T35 Simulator acceptance passed: 3 passed, 0 failed, 0 skipped`。

| 用例 | 运行时判据 |
| --- | --- |
| 私有 `tmp` 和 `Library/Caches`，各一项 | 正式校验返回夹具的 file URL 和完整 ZIP 字节。探针记录一次呈现尝试和一个实际挂载到窗口的 `UIActivityViewController`。XCUITest 等待系统的 `ActivityListView`，在其上方的 `PopoverDismissRegion` 内点击，等待列表消失和唯一的 `cancelled` 回执。回执在额外 2 秒观察期内保持不变，源 ZIP、同账号无关文件、另一合成账号同名 ZIP、其他夹具文件和链接均保留原样。 |
| 越界与符号链接 | 相似前缀的外部目录、账户目录内多一层的 ZIP、链接文件、链接账户目录各返回一次 `io_error`，零次尝试呈现面板，所有夹具文件字节和链接目标保持原样。 |

取消探针收到终局后的呈现回调时立即刷新结果。既有的 2 秒观察期会把这种晚到通知判为失败。

## 待验边界

- 独立宿主评审已在一次性 iPhone 17 / iOS 26.5 上验收两项取消和一项非法路径拒绝。
- 完整 Runner 的 Flutter 通道调用见下列宿主复跑步骤。

## 正式 Runner Flutter 通道验收

在已准备 Flutter SDK、锁定依赖、`app/ios/Flutter/Generated.xcconfig`、本地 SwiftPM
插件和 iOS Simulator runtime 的 ARM64 Mac 上，从归档根目录执行：

```bash
bash app/tool/t35/ios_export_simulator.sh --runner-build-only
bash app/tool/t35/ios_export_simulator.sh --runner \
  com.apple.CoreSimulator.SimRuntime.iOS-26-5 \
  com.apple.CoreSimulator.SimDeviceType.iPhone-17
```

`--runner-build-only` 编译链接 UI 驱动并尝试从正式 `Runner.xcworkspace` 构建未签名的
Debug Simulator `Runner.app`。`--runner` 使用相同构建参数，复用脚本的一次性模拟器创建、
UUID 定向和销毁流程。XCUITest 使用现有 Bundle ID 启动安装在该模拟器上的 Runner。

测试入口只通过该次构建的 `FLUTTER_TARGET` 指定。它把 13 分区合成 ZIP 交给生产暂存器，
通过 `PlatformPrivacyExportDelivery` 往返正式 `AppDelegate` 注册的
`cn.higheq/mobile-commerce`，走 `MobileCommerce` 和 `PrivacyExportShare`。该用例的输入由
本地夹具生成，实服登录、HTTP 下载和保存到「文件」各有独立验收。

XCUITest 等待 `ActivityListView`，观察其至少 4 秒并截图，再点击 `PopoverDismissRegion`
取消。Dart 检查一次派发、一次 `onPresented`、呈现后至少 2 秒收到一次 `cancelled` 平台回执，
并在呈现和回执时核对完整 ZIP 字节、所有权记录及无 `.part`。调用生产清理能力后，ZIP、
`.owner` 和 `.part` 均须不存在。XCUITest 核对 Dart 状态并等待 2 秒，确认状态稳定。

通过要求退出码 0、`summary.json` 记录 1 项通过、0 项失败、0 项跳过，且脚本在成功删除
Simulator 后发出 `T35_RUNNER_EXPORT_RESULT=PASS`。输出目录中的 `runner-build.log`、
`xcodebuild.log` 和 `RunnerExport.xcresult` 可用于复核。结果包保留系统面板截图和 Dart 状态。

- **已验**。新增 Dart 入口静态分析通过。Simulator SDK 编译并链接了新增 XCUITest，
  既有 `--build-only` 也通过。脚本语法、两份 Xcode 工程 plist 与 Runner workspace XML
  均通过离线检查。生产 ZIP 校验、交付持有与冷启动回收的 Dart CLI 检查通过，T35 隐私门禁
  7 项 Python 回归通过。
- **宿主实跑**（2026-11-24）：新建 iPhone 17 / iOS 26.5 Simulator，正式 Debug arm64 Runner 采用测试专属 Dart 入口，实际注册的生产通道呈现 UIKit 分享面板、收到取消回执并清理文件。XCTest 21.520 秒，1 项通过、0 失败、0 跳过；删除模拟器后输出 `T35_RUNNER_EXPORT_RESULT=PASS`，退出码 0。这不使用用户账号，也不代表已从正式隐私页完成真机交付。
  `flutter test --no-pub -r expanded test/privacy` 在加载用例前被共享 SDK 的
  `engine.stamp` 写入权限拦截。请回填宿主命令的实际退出码、测试计数和结果包路径。

## 存储到本机「文件」的独立验收

宿主从仓库根目录运行下列命令。此模式只执行
`ExportLocalFilesUITests.testSaveToOnMyiPhoneSurvivesSourceCleanup`。脚本创建并清除
独立的 iPhone 17 / iOS 26.5 Simulator。测试在系统分享列表内定位
**Save to Files** 或 **保存到“文件”**，经 **Browse / 浏览** 进入 **On My iPhone**
对应的本机根目录，再按系统 **Save / 存储 / 保存**。

```bash
bash app/tool/t35/ios_export_simulator.sh --local-files-only \
  com.apple.CoreSimulator.SimRuntime.iOS-26-5 \
  com.apple.CoreSimulator.SimDeviceType.iPhone-17
```

探针使用唯一名称将合成 ZIP 暂存在私有 `tmp`。生产桥回传一次 `completed`
后，探针确认源 ZIP 字节仍完整，然后删除源文件。XCTest 结束并重新启动探针，
确认源文件已经不存在，再从系统文档选择器的 **On My iPhone** 打开同名 ZIP。
测试先点文件单元格；若系统仅进入选中态并显示 **Open / 打开**，再点一次该按钮。
回调立即返回和需要确认两种系统行为都由同一条件轮询处理，不等待固定时长。
探针以原位打开模式读取选择器返回的 URL，要求其位于探针数据容器以外，并比较
完整 ZIP 字节。测试独立核对 141 字节及 SHA-256
`3779ff054d5dafa662957e83d6dfc1ae54f01fee5b8d6a1e2cdd9089341afe2a`。
探针的 Info.plist 向本机「文件」注册其 Documents 目录，以便系统提供本机位置。
验收将归档保存到 **On My iPhone** 本地根目录。

通过要求退出码 0、`summary.json` 显示 1 项通过、0 项失败、0 项跳过，
并在删除 Simulator 后输出 `T35_LOCAL_FILES_RESULT=PASS`。
`ExportProbe.xcresult` 的 `T35 local Files readback` 附件记录文件名、清理回执、
本机位置、字节数和摘要。若系统动作、保存位置或选择器不可用，命令返回非零。
宿主可用 `xcodebuild.log` 和结果包定位固定阶段。初次宿主运行停在动作选择阶段，
系统实际显示「保存到“文件”」，当时测试只找英文。

| 阶段 | 核对项 |
| --- | --- |
| `files.share-sheet`、`files.save-action` | 系统列表呈现，确切保存动作可点。 |
| `files.save-location`、`files.save-confirm`、`files.save-receipt`、`files.save-observation` | 到达本机根目录、确认存储、收到唯一 `completed` 回执并移除源 ZIP。观察窗仍为 2 秒。 |
| `files.restart`、`files.read-picker`、`files.read-location`、`files.read-selection`、`files.read-confirm`、`files.read-evidence` | 重启后源仍不存在，经系统选择器在同一本机位置选中确切文件；如系统要求确认则点 **Open / 打开**，再核对外部 URL、完整字节及 SHA-256。 |

探针会进一步用固定阶段标记暂存、源清理、取消选择、文件名、外部 URL、协调读取
和字节核对失败。读回失败时，诊断只记录探针的 `picker` 状态、固定状态类别、
同名夹具的元素角色/选中态、Open 是否可点及可见角色计数；不导出其他文件名、
位置或路径，并作为 `T35 local Files sanitized diagnostics` 附件保留。

**本次归档已验**。宿主实际失败停在 `files.read-evidence`，并记录了点击文件名
后 15 秒内无 `didPickDocumentsAt`。修复版改用文件单元格并增加条件确认，同时
在探针中记录非路径化的 picker 状态。`--build-only` 对生产桥完成类型检查，也
编译并链接了探针与 XCUITest；工程、plist、Shell 语法及夹具 141 字节/SHA-256
核对通过。

**宿主实跑**（2026-11-24）：在独占的新模拟器中，系统本机保存用例耗时 49.720 秒，1 项通过、0 失败、0 跳过；最终回执 `T35_LOCAL_FILES_RESULT=PASS`，退出码 0。进程重启后经选择器打开外部目标，141 字节及 SHA-256 与原夹具完全一致，源文件已不存在。另一次新模拟器运行原 3 项，均通过且未跳过。

**复验记录要求**。用全新未登录的 iPhone 17 / iOS 26.5 Simulator 复跑
上面两个独立命令，记录实际系统语种，分别核对原三项和本机保存一项各自的用例计数、
退出码和结果包。重点是本机读回是否在 `files.read-confirm` 找到并点击
**Open / 打开**，随后仍得到唯一、完整的外部 141 字节/SHA-256 证据。中英文系统的
实际根目录、存储按钮与重启读回仍待复验。若失败，回填首条固定失败阶段和脱敏后的
诊断附件。
