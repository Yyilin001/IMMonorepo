# ADR-010：Room 写入路由与消息存储拆分

> **历史归档（编号冲突）。** 本文与
> [09-capacity/ADR-010 容量与灾备](../../09-capacity/ADR-010-capacity-and-disaster-recovery.md)
> 共用 ADR-010 编号，且未登记在 [ADR 登记册](../../ADR-REGISTER.md)。房间/用户分片路由的当前决定见
> [ADR-006 路由与迁移](../ADR-006-routing-and-migration.md)，容量与灾备见 ADR-010 的容量版。
状态：阶段 1 已实施；阶段 2 等待容量目标与运维存储拓扑批准
日期：2026-08-21  
所有者：V2 存储/网关

## 问题与事实

单库直聊热路径已经消除了 per-recipient fan-out、room outbox 和独立
`room_events` 写入；普通高活跃直聊仍必须提交：

1. `rooms` 的单房间顺序水位线；
2. `messages` 的 canonical 正文及主键、timeline、idempotency 三个索引；
3. PostgreSQL WAL 和一次 synchronous commit。

8-vCPU 单 Gateway 的 1,500 在线、128-byte 直聊/room-log 负载中，32 条有界
append batch 已将 900 msg/s 的提交从约 4,140 降至约 2,700；950 msg/s 可严格
排空，1,000 msg/s 不能在 10 秒排空。这证明进一步读缓存、连接池或单纯增加
batch 延迟不会提供数量级提升。

现有 schema 已持久化 `rooms.room_shard_id`，所有后续 room mutation 都从 room
row 读取该值。负载环境已有 `rooms-load-00` 至 `rooms-load-07` 八个 admission
shard；新直聊已按规范化 pair 的固定 FNV-1a hash，从有序的
`IM_V2_DIRECT_ROOM_SHARD_ID` 集合选择一个 owner。逻辑 shard 只分散 admission
pool 行，不会在同一 PostgreSQL 实例中分散 `messages` 索引、WAL 或磁盘写入。

## 决定

将 room shard 作为 **持久化且不可隐式重算的 room 写入 owner**，分两步推进：

### 阶段 1：单库逻辑路由准备（已实施；不作为单机提速承诺）

- 只在直聊首次创建、pair advisory lock 持有期间，按规范化 pair 的稳定 hash
  选择一个可创建 shard；将结果写入 `rooms.room_shard_id`；
- 已有 room 永远按其持久化 `room_shard_id` 读写，配置变化不得重散列或迁移它；
- 每个可创建 shard 必须在启用路由前拥有有效
  `shard_admission_pools(room_shard_id, capacity_profile_id)` lease；
- 现行有序 shard 集的顺序是 route contract；变更采用 expand → create-on-new-route
  → drain/explicit migration → disable，绝不以 Gateway 环境变量覆盖已存在 room。

该阶段仅降低 shard-admission 行热点、建立可迁移的 owner 语义，并验证路由故障
处理；它不应被报告为同机 `messages` 写吞吐提升。

### 阶段 2：物理 room-store 拆分

- `RoomStoreRegistry` 把逻辑 room shard 映射到物理 PostgreSQL store/schema；地址
  只存在部署 registry，永不写入 room event、delivery 或客户端响应；
- 一个 room 的 `rooms` 水位线、memberships、messages、message revisions 和
  room event log 保持在同一 owner store，以继续使用单库事务保证顺序与授权；
- control store 保留账号、关系/block、route 控制面、fanout plan/delivery、outbox
  与跨 user projection 的 completion 计数；不引入分布式事务；
- 跨 store 用户投影沿用 ADR-006 的 inbox 唯一键、forwarding、重试与 completion
  release。消息 acceptance 只等待 room-store 提交；用户同步异步可靠投影。

## 明确不采用

- **把 `synchronous_commit` 关闭或使用 UNLOGGED canonical messages**：只能作为
  故障可丢失的压测模式，不能改善可靠 IM 的根因；
- **在单 PostgreSQL 上把 messages 按 room 分区并宣称水平扩展**：这可能改善索引
  局部性，但 global `message_id` 与 `(sender_user_id, client_message_id)` 幂等
  约束需要重新设计；它也不分散同一个 WAL writer/磁盘，不能作为数量级方案；
- **根据 hash 在每次命令时重新计算 room shard**：route 更新会把已有 room 写到
  错误 owner，破坏 sequence、membership fence 与幂等重放；
- **跨 room/user store 两阶段提交**：可用既有 delivery inbox/retry 达成 exactly-once
  可见投影，避免协调器把可用性和恢复复杂度引入热路径。

## 实施门槛与验证

阶段 1 已有的合入证据：

1. 创建幂等、pair 并发创建、缺失 lease 和固定 hash vector 的单元/PG 集成测试；
2. `rooms.room_shard_id` 是后续 mutation 的唯一 owner 来源，因此已有 room 不会被
   新 route 重散列；
3. 负载环境使用 8 个 logical shard；它只用于降低 admission contention，不作为
   `messages`/WAL 容量结论。

阶段 1 尚未实施的运维控制面是持久化 route epoch、shard disable 状态和
operator-only route 变更审计。这些是阶段 2 多物理 store 上线前的前置条件，不能
用环境变量变更替代。

阶段 2 的合入门槛：

1. 单 room owner store 崩溃、重试、幂等重放与 membership revoke 的故障注入；
2. control-to-user projection 在 target 不可达、重复 delivery 和 route forwarding
   下的 exactly-once 可见性证明；
3. 多个物理 PostgreSQL store 的同 payload / same-connection-profile A/B，采集
   per-store WAL bytes、fsync time、index bytes、queue depth 和 P95/P99；
4. 明确 room migration runbook。直接改写 `room_shard_id` 不是迁移。

## 回滚

阶段 1：停止向新 shard 创建 room，旧 room 不动；新 route epoch 只影响未来创建。
阶段 2：在 retention 窗口内将 route owner 回到旧 store，使用 ADR-006 的
forwarding/final-verify 语义。任何已写入的新 owner room 不可通过修改环境变量回滚。

## 2026-08-22 实现就绪度审计

本次审计的目的是区分已存在的**逻辑 admission shard**和可真正分散 PostgreSQL
WAL/索引/提交压力的**物理 room store**，防止以环境变量中多个 shard 名称误报容量。

已确认的阶段 1 事实：

1. `rooms.room_shard_id` 已被创建直聊时的稳定 direct-pair router 写入，并被后续
   room mutation 读取为 admission owner；现有 room 不会因运行时列表变化被重散列。
2. `V2DirectRoomShardRouter`、group 创建和 `shard_admission_pools` lease 已覆盖逻辑
   owner 的创建与容量栅栏。它们都仍在控制 PostgreSQL 的同一 schema/实例内。
3. 用户投影侧已经有可借鉴的物理 store registry 和版本化迁移基础：逻辑 user bucket
   映射由部署私有 `IM_V2_USER_SHARD_STORES_JSON` 提供，copy/verify、forwarding、
   cutover、retention 和 rollback 在 ADR-006 的边界内运行。

尚未实施、因此禁止提前宣称为物理 room 分片的部分：

1. Gateway 当前只构造一个 `PostgresV2RoomWriteStore(database: database)`；membership、
   withdraw、edit、reaction、moderation、group capability 和 room-log Store 也全部接收
   同一个 `database`。没有 `RoomStoreRegistry`，命令尚不能按已持久化 owner 转到不同
   PostgreSQL connection/store。
2. `IM_V2_DIRECT_ROOM_SHARD_ID` 是创建时的逻辑 shard 列表，而不是物理数据库地址
   registry；改变它不能移动已有 room，更不能分散现有 `messages` 索引或 WAL writer。
3. room acceptance 的控制面、room state 和部分 fan-out durable state 仍同库原子提交。
   在没有显式 outbox/inbox ownership split 前，不能把其中任意表直接挪到新库，也不能
   引入跨库事务或双写来“试运行”。

阶段 2 应按以下顺序实施，且每一步都应有独立故障注入与 A/B 证据：

1. 定义部署私有 `RoomStoreRegistry`：逻辑 room shard → `{database URL, schema, epoch}`；
   禁止把物理地址写入 room row、event、delivery、日志或客户端响应。启动时验证 registry
   唯一性、schema、连接池总额与每个物理 store 的 migration version。
2. 引入只读 `RoomRouteStore` 和带 epoch 的 room owner record；所有 room command 先按
   room ID 解析 owner，再由 registry 取得同一 owner store。每个 command transaction
   必须继续在一个 room store 内完成 room、membership、admission、message 和 event 的
   原子提交。
3. 先只让**新创建**的 room 写入第二个物理 store；禁止迁移历史 room。验证断连重试、
   operation-key 幂等、member revoke、同 room 连续写、cache miss、outbox retry 与
   目标 store 不可达时不会误写另一个 owner。
4. 仅在上述新 room 多 store 稳定后，按 ADR-006 类似的 copy → verify → forwarding →
   cutover → retention 流程迁移一个指定 room；切换和回滚均必须由 operator-only、epoch
   fenced API 驱动，不能由环境变量或人工 SQL 直接改 `room_shard_id`。
5. 在相同 payload、连接数、room 分布和可靠性设置下，采集每个 store 的 ACK/s、P95/P99、
   WAL bytes/fsync time、checkpoint、index I/O、锁等待、连接池队列及数据一致性审计。
   只有各 store 的写入确实分散且没有 sequence/authorization/idempotency 差异，才可以
   报告横向容量提升。

在用户明确批准新增物理 PostgreSQL store 之前，本 ADR 的实现状态保持“阶段 1 已实施”。
单机阶段继续以 `fsync=on`、`synchronous_commit=on`、`full_page_writes=on` 为基线，
并只接受不改变授权、幂等或 ACK 持久性语义的测得优化。
