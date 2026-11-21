# Apple Watch · 配对验证入口

[T36 交接与真机清单](../docs/tasks/T36.md)记录两个独立门槛：技术待验证；原型未提交 App Review。此目录没有生产 target。

- `prototype/T36.xcodeproj`：直接用 Xcode 打开。`T36Phone` 内嵌 `T36Watch`。不依赖 Flutter、服务器、账号或订阅。
- `prototype/Watch`：同意后开启测试会话、采样计数、请求轻震、停止；`Phone`：最近快照、手动指令及回执；`Shared`：仅实时消息、会话令牌与过期检查。
- 从仓库根运行 `./watch/prototype/verify.sh`：合成协议检查与通用设备无签名构建；不安装、不采集、不上传。实际佩戴、配对和审核请按交接清单单独记录。

GitHub Actions 的 `Watch prototype` 在原型代码或其工作流变更时复跑同一脚本，也可手动触发。作业不签名、不安装、不读取设备数据；其绿色结果不是配对真机技术结论，也不是苹果审核放行证据。
