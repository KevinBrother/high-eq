# WLEIS 题库

来源：Wong, C. S., & Law, K. S. (2002). The effects of leader and follower emotional intelligence on performance and attitude: An exploratory study. The Leadership Quarterly, 13(3), 243–274.
已获作者商用授权（2026 年 11 月），授权函另行归档。

- 基准：英文原文（作者授权版本），不得改动。
- App 展示：中文。作者没有官方中文版，中文为按原文逐题自行翻译的正式版本（`zh_status: final`）。

## 指导语

下面的句子描述了人们在情绪方面的一些表现。请根据你平时的真实情况，选择最符合你的程度。答案没有对错之分。

## 选项（1–7 分）

1 非常不同意 · 2 不同意 · 3 有点不同意 · 4 说不清 · 5 有点同意 · 6 同意 · 7 非常同意
（原文锚点：1 = Strongly disagree，7 = Strongly agree）

```yaml
version: wleis-2026-11
zh_status: final          # 自行翻译的正式版
scale: { min: 1, max: 7 }
reverse_scored: []        # 原文无反向计分题
dimensions:
  SEA: { name: 自我情绪评估, app_ability: 自我觉察, items: [1, 2, 3, 4] }
  OEA: { name: 他人情绪评估, app_ability: 读懂别人, items: [5, 6, 7, 8] }
  UOE: { name: 情绪运用, app_ability: 自我激励, items: [9, 10, 11, 12] }
  ROE: { name: 情绪调节, app_ability: 自我管理, items: [13, 14, 15, 16] }
items:
  - { id: 1,  dim: SEA, en: "I have a good sense of why I have certain feelings most of the time.", zh: "大多数时候，我都清楚自己为什么会有某种感受。" }
  - { id: 2,  dim: SEA, en: "I have good understanding of my own emotions.", zh: "我很了解自己的情绪。" }
  - { id: 3,  dim: SEA, en: "I really understand what I feel.", zh: "我真正明白自己的感受。" }
  - { id: 4,  dim: SEA, en: "I always know whether or not I am happy.", zh: "我总是知道自己是否开心。" }
  - { id: 5,  dim: OEA, en: "I always know my friends' emotions from their behavior.", zh: "我总能从朋友的行为中了解他们的情绪。" }
  - { id: 6,  dim: OEA, en: "I am a good observer of others' emotions.", zh: "我很善于观察别人的情绪。" }
  - { id: 7,  dim: OEA, en: "I am sensitive to the feelings and emotions of others.", zh: "我对他人的感受和情绪很敏感。" }
  - { id: 8,  dim: OEA, en: "I have good understanding of the emotions of people around me.", zh: "我很了解身边人的情绪。" }
  - { id: 9,  dim: UOE, en: "I always set goals for myself and then try my best to achieve them.", zh: "我总是为自己设定目标，然后尽最大努力去实现。" }
  - { id: 10, dim: UOE, en: "I always tell myself I am a competent person.", zh: "我总是告诉自己，我是一个有能力的人。" }
  - { id: 11, dim: UOE, en: "I am a self-motivated person.", zh: "我是一个能自我激励的人。" }
  - { id: 12, dim: UOE, en: "I would always encourage myself to try my best.", zh: "我总是鼓励自己尽最大努力。" }
  - { id: 13, dim: ROE, en: "I am able to control my temper and handle difficulties rationally.", zh: "我能控制自己的脾气，理性地处理困难。" }
  - { id: 14, dim: ROE, en: "I am quite capable of controlling my own emotions.", zh: "我很有能力控制自己的情绪。" }
  - { id: 15, dim: ROE, en: "I can always calm down quickly when I am very angry.", zh: "当我非常生气时，我总能很快冷静下来。" }
  - { id: 16, dim: ROE, en: "I have good control of my own emotions.", zh: "我能很好地控制自己的情绪。" }
```

## 计分

- 维度分 = 该维度 4 题平均分（1–7）
- 总分 = 四个维度分的平均
- 展示用百分制 = (维度分 − 1) ÷ 6 × 100，先用未取整的百分制数值分档、显示时再取整；自评文案与区间见 docs/standards.md 第二节
- 16 题全部作答才计分；中途退出保存进度，下次续答
