# Go 单体服务

从仓库根运行 `./server/dev.sh`。需要 Docker Compose v2、OpenSSL、curl。脚本只在 `build/t04/dev.env` 首次生成开发数据库口令与 256 位字段密钥；不会加载项目 `.env`。不要上传此文件，保留开发库时也要保留密钥。默认仅在本机 `127.0.0.1:8080` 监听，冲突时使用 `HEQ_PORT=18080 ./server/dev.sh`。

- 就绪：`curl -i http://127.0.0.1:8080/v1/health` → `200 {"ok":true}`；任一依赖不健康则 500，不泄露地址、密钥或堆栈。
- `./server/dev.sh logs api` 查看结构化日志；`./server/dev.sh down` 停服务但保留卷。PG 与删除登记是**不同的卷**，不要单独清空/回滚登记卷来修复启动失败。
- `./server/tests/runtime.sh` 创建、核验、销毁独立的 Compose 测试项目，不连接开发库。`./server/tests/migrations.sh` 另用临时 PG17 走全量 up / SQL 约束 / down / up（需 `migrate` v4 CLI）。
- [T04 交接](../docs/tasks/T04.md)：如何新增接口、注册模块、处理事件和故障。[结构与删除协议](../docs/schema.md)；[单体事件目录](../docs/api/events.md)。

本卡只交付公共基础设施；不提供登录、支付、画像或个人导出等业务端点。Compose 是开发配置，不能充当生产部署。

**新迁移必须能从已发布的版本升级。** 从仓库根 `git fetch origin`，暂存自己的 up/down 文件后运行 `python3 scripts/migration_history/check.py origin/main :index`。若开发期间已有版本号更大的迁移合入，请调整**尚未发布**的这对文件再提交。`Migration history` CI 对比实际提交的 Git blob 和版本号，不允许重写、移除已发布 SQL，也不允许追加比已发布版本更早的新迁移。它补充而非替代空库 up/down 与业务数据验证。
