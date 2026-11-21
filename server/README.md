# 服务端

当前交付 PostgreSQL 17 数据模型，尚无 HTTP 服务。模型说明与清理边界见 [schema.md](../docs/schema.md)。

## 验证迁移

需 Docker、`openssl`、golang-migrate v4（含 PostgreSQL driver）。从仓库根运行：

```sh
./server/tests/migrations.sh
```

脚本只创建临时数据库容器，绑定随机本地端口，退出即销毁，不读取 `.env` 或连接已有库。依次进行：空库 up → SQL 约束/级联检查 → down 清空 → 再次 up。可用 `PG_TEST_IMAGE` 指定预下载的 PG17 镜像 ID。
