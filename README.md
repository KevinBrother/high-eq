# 对话手记 · 情商训练 App

从一次自评开始，选一个场景练习表达，再通过复盘观察变化。自评分数和训练反馈用于练习，不是诊断。产品目标、免费与会员的界限见[本轮决策](docs/DECISIONS.md)。

## 从哪里开始

| 我想… | 入口 | 最短路径 |
| --- | --- | --- |
| 在手机上试用 | [Flutter App](app/README.md) | 配好[本地工具链](docs/local-development.md)，在 `app/` 安装锁定依赖并运行 `flutter run`。默认是离线示例，不发真实短信、不扣款、不读取健康数据。 |
| 启动真实 API | [Go 服务](server/README.md) | 从仓库根执行 `./server/dev.sh`。它启动 PostgreSQL、Redis 和 API，等待 `/v1/health` 就绪。手机端连接真实服务须使用设备可访问的受信 HTTPS 源站。 |
| 使用运营后台 | [Flutter Web 后台](admin/README.md) | 按说明构建页面、创建本地管理员并启动同源站点。没有默认账号；模型管理、提示词发布和统计使用后台权限，不接受手机端令牌。 |
| 验证手表原型 | [配对原型](watch/README.md) | `./watch/prototype/verify.sh` 检查协议及无签名构建；佩戴、锁屏、触感和正式审核是[独立验收项](docs/tasks/T36.md)。 |

## 开发与验收

- [任务卡和依赖](docs/tasks.md)定义要交付什么；[逐卡交接](docs/tasks/)记录实际验证了什么、哪些仍需人工或外部环境。合成用例通过不代表真实模型、支付或设备验收通过。
- App 和后台分别使用 [App OpenAPI](docs/api/app.yaml) 和 [Admin OpenAPI](docs/api/admin.yaml)。模块内数据如何归属和删除，见[数据库模型](docs/schema.md)及[内部事件目录](docs/api/events.md)。
- 接手下一卡前阅读 [AGENTS.md](AGENTS.md)、[工程约定](docs/CONVENTIONS.md)和依赖卡交接；跨模块差异登记在[变更队列](docs/CHANGES.md)。
