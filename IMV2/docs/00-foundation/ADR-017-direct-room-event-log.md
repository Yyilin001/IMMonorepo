# ADR-017：私聊以房间事件日志作为可靠恢复源

状态：已接受，受运行时开关保护
日期：2026-08-19
所有者：消息平台主管

## 背景

ADR-015 已消除了私聊的 Planner 枚举，但每条消息仍为固定的两位成员创建 Delivery、共享
投影引用、用户 Sync Log 和 completion 状态。对于私聊，这些记录是同一条已授权消息的重复
可恢复副本，也是单库写入、索引维护和 WAL 的主要放大来源。

## 决定

`IM_V2_DIRECT_FANOUT_MODE=room_log` 时，私聊 `message.accepted` 在一个事务内只提交：

```text
room/admission 更新 + messages + 可选审核任务 + media/mention 引用 + room_events
```

`room_events` 是唯一可靠消息流；每个客户端按自己的 room cursor 拉取并将“事件和新 cursor”
原子地写入本地库。在线通知只发送 room waterline 提示，不是数据源，也不影响 ACK。直聊仍先
执行 pair、双向 block、陌生人策略/额度、冻结、成员 revision、媒体所有权、幂等和 admission
检查；目标用户不可由客户端输入决定。

群聊维持现有 Planner/Hybrid 模式。`planner` 与 `preplanned` 保留为回退和兼容模式。

## 安全与一致性

- 每次 pull 和 subscribe 都检查调用者当前是活动成员；每条事件还以提交时 membership revision
  过滤，因而无法经由旧 cursor 读取入会前或离开后的内容。
- 发送事务中消息和 `room_events` 同时提交；失败会整笔回滚，不能出现“已 ACK 但没有恢复记录”。
- 客户端仅在拥有直聊 identity/profile 且未记录授权拒绝时才拉取；拒绝状态跨重启保存。
- 幂等重放返回相同消息结果；事件不会复制到 fanout/delivery/inbox/projection/sync-log message
  表中。

## 范围和已知边界

本期仅切换 `message.accepted`，这是压测写入热点。消息编辑、撤回、reaction 及 moderation
mutation 仍走既有 fanout 路径；它们在下一期需使用同一 room-event contract，切换前不得声称
私聊所有 mutation 已零 fanout。关闭内容审核只关闭可选审核任务，不改变以上可靠性边界。

## 回退

将开关改回 `preplanned` 或 `planner` 并滚动重启。新旧消息都保留 `messages` 与 `room_events`，
不需要转换或删除数据；回退后仅新消息恢复旧投递流。出现授权异常、事件/消息计数不一致、错误率
或延迟超预算时立即回退，并保留 WAL、指标与聚合审计证据。

## 验证

真实环境对比必须使用相同快照、连接数、消息大小和客户端读取模型，并记录 ACK/s、p95/p99、
WAL bytes/message、DB CPU/IO、锁等待与各 fanout 表增量。压测客户端必须同时按 room cursor
拉取，不能只测写 ACK。
