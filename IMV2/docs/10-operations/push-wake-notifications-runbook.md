# 推送通知（提及唤醒）运维手册

状态：入队、准入、消费与抑制链路均已实现；**默认未配置**，未配置时行为是"不发通知"，
不影响消息本身。启用需要运维显式创建活动并按窗口给设备预算。

## 这条链路做什么

房间日志是权威副本之后，消息内容只存在于房间事件日志里，客户端按房间游标恢复。被 `@`
的成员因此**不再**拥有逐用户可靠投递；他们收到的是**通知**：一条通用推送唤醒，唤醒
客户端去拉取房间。推送失败或未配置都不影响消息可见性——那正是"推送只是加速"的含义。

```text
消息接受事务
  └─ 事件写入房间日志（权威副本，客户端可恢复）
  └─ 在房间 owner 写入 mention_push_wake_intents（同一事务）
        └─ 有界 relay 转交控制库：回执去重、解析有效设备、写入 push_wake_outbox
              └─ 消费侧查询当前 owner 的静音事实，再按控制域活动和设备预算准入
              ├─ 是 → 交给推送提供方
              └─ 否 → 标记 suppressed（不报错、不重试、不阻塞消息）
```

## 默认行为

- owner 意图随消息记录；Gateway 总是运行 relay。推送配置 disabled 时直接关闭意图；控制库 `push_campaigns` 没有启用活动时，relay 记录去重回执但不产生设备通知行。
- 活动启用但缺少按 `(device_id, campaign_id, window_started_at)` 的预算行时，唤醒会被
  标记为 `suppressed`（原因 `device_budget_unavailable`），可以观测到"已配置但未供资"。
- 无论哪种情况，消息接受、幂等重放、房间日志拉取都**不受影响**。

## 启用提及通知

1. 在**控制库**创建并启用活动（活动标识是代码常量 `mention_wake`）：

```sql
INSERT INTO im_v2.push_campaigns (campaign_id, state, updated_at)
VALUES ('mention_wake', 'enabled', now())
ON CONFLICT (campaign_id) DO UPDATE SET state = excluded.state, updated_at = excluded.updated_at;
```

2. 在控制库为每台需要接收通知的设备、每个预算窗口写入预算。窗口按 **UTC 整点**对齐，与入队侧
   `date_trunc('hour', now())` 一致：

```sql
INSERT INTO im_v2.push_device_budgets
    (device_id, campaign_id, window_started_at, max_work_units, used_work_units,
     max_new_key_operations, used_new_key_operations)
VALUES (:device_id, 'mention_wake', date_trunc('hour', now()), 10, 0, 10, 0)
ON CONFLICT DO NOTHING;
```

   预算按窗口滚动供应；上一窗口用尽不会外溢到下一窗口，也不会因为缺供资而失败。

3. 关闭通知：把活动置为 `disabled`（消费侧会把待处理唤醒标记为 `campaignDisabled`）或停止
   供应新窗口预算。两者都不需要重启进程。

## 边界

- 单条消息最多通知 32 名被 @ 成员，每名成员最多 5 台设备（按最近活跃排序）。
- 入队只针对**有效**设备：未撤销、会话未过期、账号未停用。
- 唤醒是通用提示，不携带正文、不携带消息标识的语义保证；客户端必须按房间游标拉取内容。
- owner 意图与消息原子提交；控制唤醒与去重回执原子提交，目标提交、源删除之间崩溃可安全重放。
- 意图与唤醒保存独立房间标识，不对 `room_events` 建立外键；消息日志裁剪不等待可选通知。
- 通知以源创建时间计时，24 小时后终态关闭；控制去重回执至少保留七天。重放不会续期或再次解析新设备。
- 静音偏好属于房间 owner；准入前按控制目录查询当前 owner，读取失败时不发送通知。
