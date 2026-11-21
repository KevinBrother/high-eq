# 情商训练 App

Flutter 手机端与运营后台、Go 模块化单体、Swift 手表端。先看[本轮决策](docs/DECISIONS.md)和[任务依赖](docs/tasks.md)，再按[工程约定](docs/CONVENTIONS.md)进入模块。

| 入口 | 内容 |
| --- | --- |
| [app](app/) · [admin](admin/) · [watch](watch/) | 客户端工程边界，当前没有可启动的 UI |
| [server](server/) | PostgreSQL 迁移与隔离验证命令 |
| [数据模型](docs/schema.md) | ER 图、表职责、数据清理与后续任务边界 |
| [任务交接](docs/tasks/) | 已实施任务、验证方法及待办 |
