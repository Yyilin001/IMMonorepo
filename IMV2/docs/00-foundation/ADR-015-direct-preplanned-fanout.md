# ADR-015：私聊权威受众直达投递

状态：已接受并实施，可配置灰度
日期：2026-08-17
所有者：消息平台主管

## 背景

标准 fan-out 为未知规模的群受众设计：消息提交后写 `room_outbox`，Planner 再 claim、
按 membership revision 枚举、创建 completion units 与 deliveries。私聊受众却固定为
direct pair 的两位成员，继续执行通用枚举会增加一次 outbox 写入、Planner claim/publish、
plan 状态更新和索引扫描，并把 ACK 后的投递启动延迟绑定到 Planner cadence。

本优化只消除已经可由同一权威事务确定的规划工作，不改变消息接受、权限、Inbox、重试、
用户序列或同步语义。

## 决定

`IM_V2_DIRECT_FANOUT_MODE=preplanned` 时，私聊消息接受事务执行：

```text
锁定 room / admission / direct pair / revision-fenced memberships
  -> 写 message + room_event + immutable message state
  -> 创建 state=planned、enumerated_target_count=2 的 fanout plan
  -> 创建一个 target_count=2 的 completion unit
  -> 为两位权威成员各创建一个 routed delivery
  -> 提交
```

consumer inbox、user sync sequence/log、重试和 completion release 保持原样。若 target user
store 与控制 schema 已由组合根证明同库，新鲜 direct delivery 在一个事务中直接
`pending -> terminal`，不先写 claim token/retry count；远端分片、迁移转发、失败重试和过期
lease 仍走原 claim-token 协议。快路径单事务行数不得超过同库
`IM_V2_FANOUT_DELIVERY_COMMIT_BATCH_SIZE`，不能用更大的 claim limit 隐式扩大锁、回滚和 WAL
边界。同库 fresh worker 按 source event 分配固定数据库 lane，并在 delivery 事务内只写一次
shared payload/reference；消息接受事务不承担该投影写入。群聊和任何非私聊事件继续走
Planner。

## 安全与一致性不变量

- 接收者绝不来自请求、缓存或调用方数组，只从已锁定的 `direct_room_pairs` 与
  `room_memberships` 推导；membership 必须在事件提交 revision 上有效。
- pair 必须恰好对应发送者和策略层已确定的对端，权威目标必须恰好为 2。0、1、3 或重复
  目标都抛出 `corruptPersistenceState`，整个消息事务回滚，不降级成单边投递。
- 发送资格、陌生人开关/额度、冻结房间、账号类型、媒体所有权、幂等与 admission 检查均在
  fast path 之前执行；fast path 不拥有也不绕过授权逻辑。
- 两个 route 必须来自同一事务读取的 router configuration/override。route 配置暂不可用时，
  只能创建互斥的 `planning + room_outbox`，不得同时存在 partial direct work。
- plan、completion unit、两个 delivery 与消息同事务提交；宕机不存在“消息已接受但可靠
  投递记录尚未创建”的窗口。
- 同一 source event 的两位接收者归属同一 fresh lane。跨 replica 再以 non-blocking source
  advisory lock 选出唯一 materializer；未取得锁的事务释放候选行稍后重试，不等待也不争抢
  `(source_event_id,projection_kind)` 唯一键。远端 target 仍在自己的物理 store 建立引用。
- `(source_event_id,target_user_id,projection_kind)`、inbox 和 immutable state 冲突仍按原
  幂等/等值验证处理，禁止 last-write-wins。
- shared state 不是可见性授权。增量同步、Snapshot 与媒体下载仍必须先命中该用户的
  delivery/projection reference。
- fresh direct projection 在持有 delivery row lock 后获取每用户 route advisory share lock，
  再重新读取 route/migration；stale route 不得写旧 owner，forwarding/verified migration 不得
  走同库快路径。异常行回落到普通 lease lane，以便 retry policy 最终 pause poison work。
- fresh claim 按 source event 使用固定 8 个数据库 hash lane；任意较小 worker 数只接管与
  自身 index 同余的 lane。这样调整进程并发不改变所有权、同一事件的两个 target 不被进程内
  worker 拆开，同时 PostgreSQL 可使用表达式索引避免重复扫描全部 pending delivery。

## 回退与兼容

运行时默认仍是 `planner`。两种模式写相同的 plan/delivery schema，旧 Planner 能处理
route 缺失的 fallback 行，Delivery Worker 不区分来源，因此可以滚动切换：

- 回退只需设置 `IM_V2_DIRECT_FANOUT_MODE=planner` 并滚动重启；
- 已 preplanned 的 deliveries 继续排空，不需要数据迁移；
- 禁止删除或人工补写 fallback outbox；Planner 的幂等约束负责恢复。

## 预期与验证边界

私聊占主导时，预规划预计先降低约 15%–30% 的数据库事务/索引工作；同库 fresh delivery
再消除每目标一次非 HOT claim UPDATE 和重复 route/migration 往返。ACK 后 delivery 可见延迟
不再等待 Planner poll。该数字是容量假设，不是承诺；必须用相同连接数、消息大小、数据库参数和同一
数据分布对比 ACK/s、端到端 p95/p99、WAL bytes/message、DB CPU、lock wait 与 backlog。

正确性门槛包括：两目标 cardinality、零 accepted-message outbox、route 缺失回退、腐坏受众
整笔回滚、重复命令、进程重启、Delivery 重试、completion release、跨 user-shard route 和
wire payload 等价。操作与审计见
[direct preplanned fan-out runbook](../10-operations/direct-preplanned-fanout-runbook.md)。

## 拒绝的方案

- 在 ACK 后由内存直接推两条 socket：丢失宕机恢复、离线同步和 inbox 幂等，拒绝。
- 接受客户端提供的两位接收者：扩大越权投递面，拒绝。
- route 缺失时只写已解析的一侧：产生不可修复的非对称会话，拒绝。
- 删除 plan/completion/delivery：会破坏 admission 释放、重试和现有可观测性，拒绝。
