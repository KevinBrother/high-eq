# 情商训练 App 文档

从[一页决策摘要](DECISIONS.md)了解本轮范围；分配开发工作时直接取[任务卡](tasks.md)，不需要查找历次评审记录。

| 文件 | 用途 |
| --- | --- |
| [产品与技术架构](architecture.md) | 产品闭环、模块边界、收费与开发顺序 |
| [开发任务](tasks.md) | 8 个阶段、36 个任务编号；T32A（P5 免费）与 T32B（P6 会员）分开交付，T36 在 P0 先做手表技术验证 |
| [标准体系](standards.md) | WLEIS、NVC、两档情绪判定与训练参考分 |
| [WLEIS 题库](wleis_items.md) | 授权版题目与 T08 使用的 YAML |
| [评分提示词](standards/scoring_prompt.md) | 规则、JSON Schema、基础标注和回归样例 |
| [对练扣次表](standards/quota.md) | 同一会话的扣次、退款和断线重试 |
| [手表与数据接口](standards/watch.md) | 平台边界与真机验证入口 |
| [隐私与授权](standards/privacy.md) | 同意流程、源数据和副本的保存、删除及导出 |
| [工程约定](CONVENTIONS.md) · [变更队列](CHANGES.md) | 技术栈、命名、接口与任务交接 |
| [数据库模型](schema.md) | 迁移、表职责、生命周期与清理协议 |
| [T01 交接](tasks/T01.md) · [T02 交接](tasks/T02.md) | 当前工程与数据层的交付及验证边界 |
