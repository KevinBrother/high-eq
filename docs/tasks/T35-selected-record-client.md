# T35 隐私页选择并删除本人记录

正式入口为「我的 → 隐私与个人数据 → 浏览并选择我的记录」。按类别分页浏览，在确认框核对编号、时间和删除影响。关系人通过现有手记按完整编号辨认，级联删除须勾选确认。确认按钮在首次账号核对完成后启用，点按后再次核对当前登录租约。取消弹窗会作废尚未返回的确认。仅在收到严格删除回执且回读所选类别第一页后返回隐私页并提示刷新。删除已确认而列表回读失败时，「重试读取」只重发 GET。旧租约的列表和删除回执无法更新新账号页面。

## 接口与生成

| 客户端调用 | HTTP 契约 |
| --- | --- |
| `MobileEndpoints.listDataRecords({required AccountScope scope, required String kind, String? cursor, int? limit}) → Future<Json>` | `GET /v1/me/data/{kind}`。需要当前登录令牌。默认每页 20 条，范围 1–100。最多 300 字符的游标原样传回。响应为 `{items, next_cursor}`，结束游标为 `null`。 |
| `MobileEndpoints.deleteSource({required AccountScope scope, required String kind, required String id}) → Future<Json>` | `DELETE /v1/me/data/{kind}/{id}`，以记录定位页公开的 UUID 为准。 |
| `MobileEndpoints.deleteWindow({required AccountScope scope, required String startsAt, required String channel}) → Future<Json>` | `DELETE /v1/signal-windows?starts_at=…&channel=…`，原样发送定位页的 `recorded_at`，渠道为 `health` 或 `voice`。 |

列表类别为 `assessments`、`sessions`、`reviews`、`replies`、`contacts`、`manual_marks`、`signal_events` 和 `signal_windows`。定位条目为 `kind`、`label`、`recorded_at` 加 `id` 或 `channel`。关系人 `recorded_at` 为 `null`。两条 DELETE 都要求 HTTP 200、`application/json` 及唯一字段 `{"ok":true}`。页面使用 `AppApi.jsonGuarded` 发送 DELETE，在首次发送及 401 重放前同步核对当前账号和准入状态。

[公开 OpenAPI](../api/app.yaml) 是移动客户端生成的唯一输入。生成器沿列表成功响应的引用读取 `DataRecordPage` 和 `DataRecord` 的三个变体，从中生成记录定位与游标校验常量。两条 DELETE 都必须声明 `x-mobile-exact-success-status`，其值须为 2xx 整数，对应唯一一条明确声明的成功响应。当前两条路由都声明 200。操作枚举顺序、JSON 样例和 ZIP 内文件取自同一规范。

从仓库根目录使用已安装 PyYAML 的 Python 运行以下检查。更新公开契约后，运行生成器时去掉 `--check` 可重生成客户端代码和离线样例。

```sh
python3 -B -m unittest discover -s app/tool -p test_generate_api.py -v
python3 -B app/tool/generate_api.py --check
```

## 本次验证

- **单源生成已验**。本归档用 Python 3.10 和 PyYAML 复现删除 200 响应引起的 `KeyError`，修复后 11 项生成回归及 `--check` 通过。覆盖漏注解、非法或未声明的状态、额外 2xx、记录变体互斥键、共享正则及规范引用，核对生成的操作枚举顺序、选删 JSON 样例、ZIP 文件顺序和内容。Dart、样例和 Go 路由文件均与保留的归档生成物逐字节一致。合规离线套件 83 项通过。
- **完整规范与 Go 契约待宿主复验**。本归档缺少 `openapi_schema_validator`，可直接运行的 Go 为 1.22.6，服务端要求 1.26.0。复验命令见下节。

## 前轮客户端验证

- **已验**。正式 App 在基线的 `/privacy` 因缺失入口失败，接入后通过。新增取消竞态回归在退场动画期间释放迟到的 `GET /v1/me`。守卫加入前，迟到结果使确认流程异常退场。修复后取消保持在记录页，后续明确确认才发出 DELETE。
- **已验**。归档无套接字 Flutter runner 执行 85 项、0 失败，覆盖正式 iOS 分支登录、分页、两次账号核对、列表失败重试、同一 App A → B → A、八类定位、关系人级联确认、严格删除回执以及基线账号与导出回归。日志为 `../tmp/t35-records-regressions-final.log`。
- **已验**。移植后的实服旅程以临时内存响应回放，正式页面的下载、两个 iOS 阶段回执、第二页记录、唯一 DELETE、删除后只剩 20 条和 B 的独立列表断言通过。日志为 `../tmp/t35-records-live-replay.log`。Dart 静态分析、格式检查、生成物对照、ZIP 离线检查和 7 项既有 Python 门禁回归通过。
- **未验**。标准 `flutter test` 在共享 SDK 写 `engine.stamp` 时被拒绝。旧关系人 `flows_test.dart` 的「确认删除成功后才清理成长缓存」在基线和本卡的无套接字运行器都卡在 `pumpAndSettle`，需宿主标准 Flutter 复跑。正式 HTTP、PG17、普通 Redis、删除账本及实际 iOS 系统面板仍待宿主验证。

## 宿主复验

在仓库根目录使用 `scripts/contract-requirements.txt` 中的 Python 依赖以及 Go 1.26 运行公开契约和具名用例。

```sh
python3 -B scripts/check_contracts.py
go -C server test ./internal/api/app -count=1 -v \
  -run '^Test(DataRecordPageContract|WindowDeleteStartsAtContract|SelectedSourceDeleteContract)$'
```

使用可写 Flutter SDK，先在 `app/` 核对离线用例和静态分析。

```sh
flutter pub get --enforce-lockfile
flutter test --no-pub -r expanded test/privacy test/contacts
dart analyze lib test tool/t35/ui_selected_record_test.dart
```

按[隐私账号卡的宿主配置](T35-privacy-profile-closure.md#宿主复验)配置一次性的隔离 PG17、普通 Redis、删除账本和数字回环 API。每次运行向 `T35_RECORD_DEV_TICKET_A` 与 `T35_RECORD_DEV_TICKET_B` 注入映射到两个不同新合成账号的一次性 Apple 票，并将 `T35_ORIGIN` 指向该 API。在 `app/` 执行以下命令。

```sh
flutter test --no-pub -r expanded tool/t35/ui_selected_record_test.dart
```

旅程从正式登录页登录 A，经「我的」进入隐私页。B 用独立会话作为隔离对照。核对第二次打开确认框后按钮已启用、唯一 DELETE 得到 HTTP 200 和严格 JSON 回执、同类别第一页读回并返回隐私页。前后两份 A 的 ZIP 只相差所选记录，B 的列表前后完全相同。宿主旅程以合成桥交付回执，实际保存或分享仍需 iOS 宿主验证。
