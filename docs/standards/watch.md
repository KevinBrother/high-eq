# 手表品牌与数据接口

本轮支持三类手表：Apple Watch 的当下本人提醒须对应版本获苹果正式放行，华为手表手环和接入安卓 Health Connect 的手表只做基线和事后复盘。调研得出一个要改的地方：HRV 测量很稀疏，不能用于实时判定。

## 各平台对比

| 手表 | 接口 | 心率 | HRV | 实时性 | 本轮用途 |
| --- | --- | --- | --- | --- | --- |
| Apple Watch | HealthKit；实时用手表端 App + WatchConnectivity | 有 | 有（SDNN，新系统加了 RMSSD） | 后台心率约 5 分钟一次；手表 App 运行采集会话时约 5 秒一次 | 基线、事后复盘；放行后可做本人提醒 |
| 华为手表/手环（安卓） | 华为运动健康 Health Kit | 有（受限权限，需人工审核） | 待真机确认 | 经云端同步，有延迟 | 基线、事后复盘 |
| 三星等接入 Health Connect 的手表 | 安卓 Health Connect | 有 | 有（RMSSD） | 连续心率不立即同步到手机 | 基线、事后复盘 |
| 小米、OPPO、vivo 等 | 取决于厂商 App 是否写入 Health Connect | 待真机确认 | 待真机确认 | 待确认 | 本轮不承诺 |

## 关键事实

- **Apple Watch 后台心率**：苹果 2024 年的白皮书写明，静止时每 5 分钟尝试写一次心率到 HealthKit；运动或主动测量时是每 5 秒一次。第三方 App 没有接口可以提高采样频率。→ 当下提醒必须由手表端 App 开启采集会话，不能靠后台数据。
- **Apple Watch HRV**：默认每 4 小时测一次心电间期，开了心律不齐通知为 2 小时。→ HRV 只用于个人基线和日级趋势，不参与实时判定。
- **华为**：第三方 App 在用户授权后可读取华为手表上传到运动健康 App 的心率等数据；心率属于受限数据，申请后要人工审核。华为手表还有“心率广播”功能，可以实时把心率共享给第三方 App，可作为下一轮安卓当下提醒的方案。
- **Health Connect**：支持心率和 HRV（RMSSD）。三星为省电，手表的连续心率不会马上同步到手机。

## 对标准文档和任务的影响

1. 本人自动提醒必须有实时心率异常，且至少一类语音信号同窗异常；HRV 不参与。安卓/华为历史心率不得用于触发或补发提醒。只有两类语音异常时，手机只提示对话节奏，不自动更新个人画像。
2. **T36（P0）**用真机验证显式对话模式、锁屏/后台、步频、耗电、通信与结束采集，并形成审核说明和结论。技术状态为**待验证**，尚无正式放行结论。技术通过即可开始 T31 开发、测试和送审；苹果正式放行前生产关闭、T17 不展示自动提醒卖点。免费 T32A 在 P5 独立交付；T32B 负责会员功能。
3. T28：开工前由项目方申请华为 Health Kit 心率权限；小米、OPPO、vivo 是否写入 Health Connect 需真机确认，本轮不承诺。

## 来源

- [Apple Watch 心率与 HRV 采样频率解读（引用苹果 2024 白皮书）](https://blakecrosley.com/blog/five-second-heart-rate-healthkit)
- [Apple 开发者论坛：第三方无法改变采样率](https://developer.apple.com/forums/thread/774136)
- [华为 Health Service Kit 概览](https://developer.huawei.com/consumer/en/doc/HMSCore-Guides/overview-0000001177423513)
- [华为手表心率广播](https://consumer.huawei.com/en/support/content/en-us15827504/)
- [Health Connect 数据类型](https://developer.android.com/guide/health-and-fitness/health-connect/plan/data-types?authuser=5)
- [通过 Health Connect 读取三星健康数据](https://developer.samsung.com/health/blog/en/health/blog/accessing-samsung-health-data-through-health-connect)
