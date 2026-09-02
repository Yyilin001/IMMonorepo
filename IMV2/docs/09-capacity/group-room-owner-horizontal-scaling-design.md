# 群聊 room-owner 横向扩展设计

状态：房间热路径、创建 saga、标准 fan-out、核心消息派生写与 read receipt owner 边界已实现；完整控制面仍在补齐（2026-09-02）

## 1. 目标与不可修改的语义

目标是提升真实 `large_group_hybrid` 路径的整体容量，而不是降低压测工作量：

- 消息成功 ACK 之前仍需完成 owner PostgreSQL 的持久化事务；
- 每个房间保留严格递增且无重复的 `room_sequence`；
- 在线且主动订阅房间的连接仍接收完整事件；
- Core NATS 只承担低延迟实时传输，PostgreSQL room log 与 durable wake outbox 继续承担恢复正确性；
- 不能通过减少在线观众、跳过 room-log、隐藏队列、关闭 WAL 或把 durable 工作留到测试结束后，制造容量提升。

当前 v40 的纯群聊基线为 10 个热房间、约 100 个在线观众/房间、10,000 msg/s、30 秒：300,000/300,000 ACK，30,000,000 个接收者事件，消息 P50/P95/P99 为 25/58/79 ms。这个基线同时产生约 1,000,000 个接收者事件应用/秒。

2026-09-02 的 v64 回归使用相同真实路径重复验证了 300,000/300,000 ACK、
零跳过、零消息失败、零 sequence 缺口和零恢复拉取；三次稳定样本的消息 P95
为 62–66 ms，发送 Gateway 使用约 2.9–3.0 个 CPU 核。本文后续的资源下界
以这个较新的可重复基线为准，而不是只采用一次最优样本。

## 2. 当前代码已经具备什么

| 能力 | 当前实现 | 结论 |
|---|---|---|
| 持久化 owner 目录 | `room_owner_routes(room_id, room_shard_id, route_epoch)` | 方向正确；地址不进入业务数据 |
| 多 PostgreSQL append | `V2RoutedRoomWriteStore` | 已按 owner 并行执行不同物理库的批事务 |
| 多 PostgreSQL room-log read | `V2RoutedGroupEventLogStore` | 已按相同 owner 读取权威日志 |
| Gateway 本地兴趣 | `V2DeviceConnectionRegistry` + `V2NATSGroupEventWakeBroker` | 已按房间动态 SUB/UNSUB；NATS 只路由到有本地观众的 Gateway |
| durable group wake | `V2RoutedGroupEventWakeStore` | 已并行轮询每个物理 owner，并保留 lease 归属、限额轮转和部分 owner 故障隔离 |
| 群创建 owner 固定 | `group_room_creation_intents` + `V2RoutedGroupMessagingStore` | inline audience 已先持久化 owner/ID/请求摘要，再执行 owner transaction 和控制库 route finalize；丢响应重试不会重新 hash |
| 群创建成员资格 | 控制库事务内验证并冻结精确成员 relation | inline 与 staged 都不依赖 owner 的 profile 副本；双 PostgreSQL 已验证 owner profile 为 0 时仍只按控制 manifest 创建 |
| staged 100k 群创建 | `intent_members` + `intent_pages` | 以最多 512 人/页、页号、SHA-256 digest、唯一 final page 传输；owner 校验页连续性与精确总数后在本地事务创建 |
| 成员、编辑、撤回、reaction | `V2RoutedRoomMutationStores` | 已按同一 room owner 写入；加群的全局身份在控制库一次快照读取，owner 仍权威校验角色、revision 与当前成员关系 |
| 群能力与 moderation | `V2RoutedGroupCapabilitiesStore` + `V2RoutedModerationStore` | 已 owner 化；普通管理员与 trusted safety 都回到权威 room transaction |
| 内容审核 | `V2RoutedContentReviewWorker` | 每个物理 owner 独立 claim，违规裁决再按 room route 执行 redaction；单 owner 故障不阻塞健康 owner |
| read receipt | `V2RoutedReadReceiptStore` + owner candidate/control visibility 两阶段查询 | 群回执写入 room owner；读者候选由 owner 按消息与成员 revision 过滤，控制库再按最新账号状态、隐私偏好补全；私聊投影/偏好保留控制域 |
| forward、成员目录 | 多个 Store 仍固定使用控制库 | 尚未 owner 化；仍需拆分 source/room 查询与控制面 hydration |
| standard fan-out planner/outbox | `V2RoutedFanoutPipeline` | 每个物理 owner 有独立 relay/planner/delivery/completion worker；健康 owner 在另一 owner 故障时继续恢复 |

因此，现有代码已经越过“只分片 append”的骨架阶段：群创建、初始成员、
`room.created` standard fan-out、后续成员变更以及消息编辑/撤回/reaction 已进入
相同 owner 事务域，群能力、moderation 与审核也已按 owner 推进。但它还不是完成
的全功能数据库分片；forward source read、房间成员目录与 owner
迁移协议仍需闭环后才能生产启用。

### 2.2 Read receipt 所有权闭环（2026-09-02）

- `room_read_receipts` 与 `read_receipt_operations` 随 `room_id` 写入 owner，和
  `rooms.room_sequence`、成员 revision 处于同一事务域；
- 群回执成功路径仍是单条条件 CTE，owner 路由没有重新引入房间行锁；
- owner 专用入口遇到 direct room 会显式返回 `notGroup`，由原控制路径继续执行
  双方偏好判断、reciprocal Sync projection 和 shadow forwarding；
- 读者列表先从 owner 取得仅含 `(user_id, read_sequence)` 的稳定游标候选，再到
  控制库过滤 inactive/disabled/opt-out 并补全公开身份；每个公开请求最多扫描
  `pageSize * 10` 个候选，避免大量隐藏用户造成无界跨库工作；
- `V2CachedRoomShardRouter` 缓存的只有 owner route，默认 250k 条、64 个独立锁桶、
  5 分钟 TTL。权限、成员、消息与游标从不进入该缓存，miss 仍由控制库目录解析。

新增 7 个路由/分页测试，并在独立临时 PostgreSQL 数据库跑通原有完整回执集成
场景：单调推进、幂等冲突、direct fallback、Sync 投影、历史/当前成员约束、游标、
隐藏账号，以及新的 owner candidate/control visibility 组合。

### 2.3 Append/receipt 锁兼容性修复与 12.5k A/B（2026-09-02）

把 10 个热群合并到 4 条 append lane 后，旧实现暴露出真实死锁：消息批次先以
`FOR UPDATE` 锁住一组 `rooms` 行，回执批次在外键检查中取得另一组房间的
`KEY SHARE`，两个多房间事务以不同顺序等待。第一版修复给两条路径增加同一组
房间 advisory lock，虽然把死锁增量降为零，却把可并行的 sequence 更新与回执
也全部串行化，属于正确但性能不可接受的过度加锁。

最终修复遵循 PostgreSQL 行锁语义：消息 append 只更新 `room_sequence` 与
`timeline_sequence`，不改变任何可被外键引用的 key，因此使用
`FOR NO KEY UPDATE` 即可串行化同一房间的 append，同时不阻塞回执外键所需的
`KEY SHARE`。房间 advisory lock 被删除；消息 operation lock 与回执
operation/`(room,user)` state lock 仍按数值全局排序，幂等和单调语义不变。

同一 500 sender + 500 passive、10 个热群、双方各 500 receipt/s、完整实时
room-log 下发的 30 秒 A/B：

| 版本/lanes | ACK/目标 | 发送 P95 | append SQL 均值 | receipt 锁 SQL 均值 | 死锁增量 |
|---|---:|---:|---:|---:|---:|
| v72 / 4（房间 advisory fence） | 304,783 / 375,000 | 707 ms | 12.085 ms | 18.182 ms | 0 |
| v73 / 4（兼容行锁） | 363,848 / 375,000 | 391 ms | 5.038 ms | 0.251 ms | 0 |
| v73 / 8（当前 4c 最佳） | 374,862 / 375,000 | 199 ms | 3.022 ms | 0.276 ms | 0 |
| v73 / 16 | 373,721 / 375,000 | 278 ms | 2.749 ms | 0.282 ms | 0 |

8 lane 的批次并发与 CPU 调度平衡最好；16 lane 虽略降 SQL 时间，却增加 Swift
任务调度和 CPU 抢占，尾延迟反弹。该值是当前 4 vCPU Gateway 的实测部署参数，
不是跨规格硬编码默认值。额外的独立临时数据库回归以 32 轮反向房间顺序并发执行
跨两群 append 与 receipt，消息、回执全部提交且 `pg_stat_database.deadlocks`
保持不变。

## 2.1 不同压测口径不能直接比较

2026-08-30 的“混合群聊”只有约 536 条输入消息/s，是旧实现上的复合负载：它同时
包含 20/200/1,000/5,000 人 standard fan-out、12,400 delivery/s 的提供速率、
Sync 拉取，以及当时尚未优化的 Hybrid 写入路径。它测到的是逐用户投递与 Sync
竞争，不能代表当前 Hybrid room-log 模式的上限。

2026-09-01 的 v40 纯 Hybrid 真实链路已经验证 10,000 msg/s，并让两个 Gateway
在 30 秒内完整应用 30,000,000 个接收者事件，P95 为 58 ms、无缺口或恢复 pull。
因此，“加入群聊后从 10k 掉到 536”不是当前结论；真正的结论是两种群模式的
成本模型不同：

- `large_group_hybrid`：每条消息做一次 canonical append，在线观众按兴趣实时
  接收，离线/恢复从 room log 拉取；已验证 10k msg/s / 约 1M 在线事件应用/s；
- `standard_fanout`：每条消息按成员生成 delivery、用户 Sync Log 和投影；吞吐
  同时受输入 msg/s 与 delivery/s 约束，不能只看消息条数。

## 3. 为什么单库表分区不能带来 30 倍

PostgreSQL declarative partitioning 仍在同一个 server、同一组 CPU、buffer cache 与 WAL 系统内。它可以缩小索引、改善 pruning 和历史数据维护，但不能把一条房间写事务分散到 30 台写节点。官方文档也明确提醒 partition 数量会增加规划和 session 内存成本。

真正的水平分片必须让不同 `room_id` 的完整 canonical row set 位于不同 PostgreSQL primary：

```text
room A ──> owner shard 00 ──> PostgreSQL primary 00 / WAL 00
room B ──> owner shard 01 ──> PostgreSQL primary 01 / WAL 01
room C ──> owner shard 02 ──> PostgreSQL primary 02 / WAL 02
```

同一房间不能用普通 hash partition 并行写多个 primary，因为 `room_sequence`、成员 revision、撤回/编辑顺序和幂等状态必须在一个事务域内串行化。横向收益来自“许多房间分散”，不是把同一个超热房间任意多主写入。

## 4. 目标数据边界

### 4.1 控制库只保存目录与全局身份

- `room_owner_routes`：房间到逻辑 owner 的权威映射；
- `group_room_creation_intents`：群创建 saga 的幂等意图、输入摘要、预分配 ID、owner、状态；
- 账号、设备、全局 profile 与禁用状态；
- owner 拓扑版本与迁移状态。

控制库不保存已分片房间的第二份 canonical 消息、成员或 room sequence。

### 4.2 owner 库保存一个房间的完整事务域

- `rooms`, `group_rooms`, `room_memberships`, `room_admission`；
- `messages`, `message_payloads`, `room_events`；
- 编辑、撤回、reaction 与成员操作幂等表；
- `group_event_wake_outbox`；
- 该房间所需的 standard fan-out plan/outbox（如果仍支持 standard 模式）。

所有会推进 `room_sequence` 或 `membership_revision` 的命令必须只在 owner 库完成一次事务，不能先写控制库再异步复制 canonical 状态。

## 5. 群创建必须使用可恢复 saga

群创建没有既存 `room_id` 路由，且控制库与 owner 库无法使用普通 PostgreSQL 本地事务原子提交。正确流程不是双写后祈祷成功，而是显式 saga：

1. 控制库按 `(actor_user_id, operation_id)` 加幂等锁，校验输入、账号状态和初始成员，生成固定的 `room_id/event_id/plan_id`。
2. 使用带版本的 owner 集合做稳定选择，并把 `owner_shard_id`、ID、规范化输入摘要和成员 manifest 记录为 `prepared` intent。重试只能复用该 owner，不能重新 hash。
3. 将 intent 按有界页面复制到 owner staging 表；每页用 `(intent_id, page_no, digest)` 幂等。
4. owner 在一个事务中重新验证 manifest 完整性，创建全部 canonical room rows、初始 event、admission 与本地 operation ledger，并把 owner intent 标为 committed。
5. 控制库写入 `room_owner_routes` 并把 creation intent 标为 committed，然后才向客户端返回 created。若第 4 步成功、第 5 步失败，重试只做 finalize，不删除 owner 房间。
6. sweeper 处理长期 prepared/orphan intent；只能依据 durable state 恢复或隔离，不能猜测回滚。

安全要求：客户端不能提供数据库地址或 owner；所有 owner ID 来自部署拓扑。输入摘要不一致必须返回 idempotency conflict。owner 必须验证控制 intent 的 immutable ID、版本与摘要，不能把 Gateway 内存状态当权威。

## 6. 成员与消息管理命令 owner 化

以下 Store 必须增加与 `V2RoutedRoomWriteStore` 相同的 route-first adapter：

- `V2RoomMembershipStore`；
- `V2MessageWithdrawalStore`；
- `V2MessageEditStore`；
- `V2MessageReactionStore`；
- `V2GroupCapabilitiesStore`；
- `V2RoomMembershipDirectoryStore` 的房间视角读取；
- room-scoped moderation、read receipt 与 forward source read。

路由之后，授权仍必须在 owner 事务中使用 owner 的成员与消息行判断。路由缓存只能缓存 immutable owner route；未来若支持迁移，必须有 epoch fence、显式 invalidation 和旧 owner forwarding/reject 协议，不能用无期限内存 hash 替代目录。

当前“添加新成员”在控制库一次查询中读取 actor/target 的 active/disable 状态，
随后把带精确用户 ID 的进程内 capability 传给 owner；owner 对幂等 replay 先返回原
结果，对新操作仍校验本地角色、成员 revision、目标当前成员状态与容量。其语义是
“身份在控制快照线性化点有效”，账号之后被禁用仍由认证/连接撤销 fence 立即阻止
新命令，不会重写历史成员关系。若产品要求“disable 与并发加群在两个数据库间也
具有单一全序”，则必须再增加 durable identity epoch/fence，而不能用普通异步缓存
声称绝对即时。

内容审核按物理 owner 并行 claim；违规结果通过同一个 room router 回到权威 owner
执行 revision-fenced redaction。部分 owner 失败只减少该 owner 的推进速度，全部
owner 失败才让 runtime pass 抛错并进入现有重试节奏。

## 7. Gateway/session fan-out

现有 NATS room subject + Gateway 本地引用计数订阅可以保留：

```text
owner commit
  ├─ post-commit live payload ─> NATS room subject
  └─ durable wake outbox ──────> NATS room subject (repair hint)

NATS interest graph
  ├─ Gateway A（有本地观众）──> 只遍历 A 的本地 session
  ├─ Gateway B（无观众）──────> 不接收
  └─ Gateway C（有本地观众）──> 只遍历 C 的本地 session
```

Core NATS 是 at-most-once，因此不能取代 room log/outbox；它的优势是 location-transparent、interest-based routing。一个 Gateway 不应订阅全局 wildcard 后再丢弃无关房间，也不应使用 queue group，因为同一房间在多个 Gateway 都有观众时，每个相关 Gateway 都必须收到一份。

对于巨型群，session fan-out 要像 Discord relay 一样拆到多个 Gateway。每个 Gateway 只保存和遍历自己的本地连接，不复制全群成员数组。若产品允许“未打开房间的被动连接只收 badge/watermark”，可以进一步减少工作，但这属于明确的客户端语义方案，不能偷偷用于当前全事件基线。

## 8. 实施阶段与验收

### 阶段 A：现有房间热路径双 owner PoC

- 两个独立 PostgreSQL 实例/primary，相同 schema；
- 预置房间均匀写入两个 owner，并在控制库固定 `room_owner_routes`；
- 两个以上 Gateway 使用同一 owner registry；
- append、room-log、durable wake 都从 owner 执行；
- kill 任意一个 owner、Gateway 或 NATS，验证故障只影响对应 room，恢复后 cursor 无缺口。

### 阶段 B：完整房间生命周期

- 已实现 creation intent、精确成员 manifest、分页 staged saga；
- 已 owner 化成员、编辑、撤回、reaction 与 standard fan-out；
- 已 owner 化群能力、moderation 与内容审核；
- 已拆分 read receipt 的 room/global 数据边界；待拆分 forward source read 与成员目录；
- 增加 schema rollout readiness：所有 owner 在新代码接流量前必须完成同一 expand migration；
- 加入 owner 维度的低基数 metrics，不能把 `room_id` 放进 metrics label。

### 阶段 C：容量矩阵

固定每个房间约 100 个主动在线观众、128 B 消息、真实 ACK/room-log/NATS/客户端应用：

| owner PostgreSQL | Gateway | 热房间 | 输入档位 |
|---:|---:|---:|---:|
| 1 | 2 | 10 | 10k msg/s 基线 |
| 2 | 4 | 40+ | 10k / 15k / 20k msg/s |
| 4 | 8 | 80+ | 20k / 30k / 40k msg/s |
| 8 | 16 | 160+ | 40k / 60k / 80k msg/s |

每档至少 5 分钟稳态，并报告 ACK、event 完整率、P50/P95/P99、每 owner CPU/WAL/commit latency、每 Gateway CPU/queue/event-loop lag、NATS bytes/drops、恢复 pull。只有在增加 owner/Gateway 后吞吐近似线性、延迟不恶化且无缺口，才能外推更大规模。

## 9. 30 倍的硬约束

以当前 10k msg/s、约 100 在线观众/房间为基线，30 倍意味着约 300k msg/s 与 30M 接收者事件应用/秒。即便数据库 append 完全线性扩展，Gateway 编码、NATS 传输、socket write 和客户端消费仍要共同扩大约 30 倍。

因此：

- 对“许多房间的集群总吞吐”，通过足够多独立 owner primary 和 Gateway，架构上可横向逼近 30 倍；
- 对“单个严格有序超热房间”，当前单 owner sequence 模型不能达到任意 30 倍，需要独立日志 sequencer、批量 sequence range 或改变排序语义，且仍不能消除对在线观众的 O(audience) 输出；
- 在当前 2 台小规格 Gateway、1 个 PostgreSQL primary 上，代码微优化不可能把真实路径提升 30 倍。此前 append SQL 约 1.7 ms/批、sender Gateway 已使用约 3.4/4 核，剩余常数优化只能给百分比收益。

### 9.1 从实测外推的最低资源量

这里的外推不是容量承诺，只用于证明单机 30 倍为什么在物理上不成立：

| 资源 | 10k msg/s 实测量级 | 300k msg/s 线性下界 |
|---|---:|---:|
| 发送 Gateway CPU | 约 2.9 核 | 约 87 核，尚未计入跨节点协调余量 |
| PostgreSQL append executor | 30 秒内约 40 秒累计执行时间 | 仅主 append 约 40 个持续 CPU 核 |
| WAL | 约 242 MB / 300k 消息 | 约 242 MB/s 持续 WAL，未计 checkpoint/FPI 波动 |
| 在线事件应用 | 约 1M recipient-events/s | 约 30M recipient-events/s |
| 128 B 正文净载荷 | 约 128 MB/s 聚合 | 至少 3.84 GB/s；协议、TLS 与 ACK 后更高 |

同样的 10 个热房间若直接把输入放大 30 倍，还会把每个房间从约 1k msg/s
推到约 30k msg/s。`room_sequence` 的单房间严格全序要求这些更新经过同一个
owner 的串行化点，不能通过增加普通 Gateway 消除。集群 30 倍必须同时增加
热房间数量并把它们均匀分布到多个 owner；“单一超热房间 30 倍”是另一项需要
专用 sequencer/日志设计的目标。

### 9.2 已否决的常数优化

2026-09-02 使用相同 10k msg/s 场景做了两组只改 Swift 所有权表达的 ARM A/B：

| 版本 | 改动 | ACK | 消息 P95 | 队列峰值 | 发送 Gateway CPU | 结论 |
|---|---|---:|---:|---:|---:|---|
| v64 | 稳定基线 | 300k/300k | 62–66 ms | 15–27 | 约 294%–302% | 保留 |
| v65 | 整体请求改为不可变 `final class` | 300k/300k | 70–74 ms | 41–161 | 约 330%–345% | 回退；每消息堆分配和局部性损失大于 ARC 收益 |
| v66 | 协议/actor 边界显式 `consuming` | 300k/300k | 66–71 ms | 35–59 | 约 295%–322% | 回退；无可重复收益，第二轮尾延迟和恢复拉取恶化 |

这两项都没有删减授权、事务、WAL、room-log 或实时投递，所以其失败可以归因
于实现成本，而不是测试口径变化。后续不应再用“把所有值类型换成 class”作为
通用性能方案；只有新的 profile 指向某个具体复制边界，才做局部、可回退 A/B。

## 10. 参考实现与官方资料

- Discord Maxjourney（passive sessions 与 relay 拆分 fan-out）：https://discord.com/blog/maxjourney-pushing-discords-limits-with-a-million-plus-online-users-in-a-single-server
- Discord 5M concurrent users（guild process 与 session process）：https://discord.com/blog/how-discord-scaled-elixir-to-5-000-000-concurrent-users
- Slack Flannel（边缘层、懒加载与实时连接）：https://slack.engineering/flannel-an-application-level-edge-cache-to-make-slack-scale-/
- Slack Koi Pond（真实客户端行为的负载测试）：https://slack.engineering/load-testing-with-koi-pond/
- NATS Core / subject interest / at-most-once：https://docs.nats.io/learn/core-nats/
- NATS Subjects：https://docs.nats.io/concepts/subjects
- PostgreSQL partitioning：https://www.postgresql.org/docs/current/ddl-partitioning.html
- PostgreSQL WAL：https://www.postgresql.org/docs/current/wal-intro.html
- PostgreSQL row-level lock compatibility（`NO KEY UPDATE` 不阻塞 `KEY SHARE`）：https://www.postgresql.org/docs/current/explicit-locking.html
- Vitess sharding（独立数据库 shard 与 topology routing）：https://vitess.io/docs/24.0/overview/whatisvitess/
