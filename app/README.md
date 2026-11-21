# 手机客户端 · T16 起

Flutter iOS / Android，状态管理用 Riverpod。共用网络、授权状态和账号隔离存储放 `lib/core/`；页面和状态按业务放 `lib/features/<feature>/`。以 T03 的 App 契约为准，拒绝健康或麦克风权限不能影响免费标记。
