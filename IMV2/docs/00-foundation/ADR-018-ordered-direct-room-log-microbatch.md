# ADR-018：有序私聊 room-log 原子微批

状态：已接受并实施，受运行时开关保护
日期：2026-08-21；2026-08-27 按 R29 实现修订
所有者：消息平台主管

## 背景

ADR-017 已使普通纯文本私聊的 `messages` 行同时承担 canonical message 与 accepted-event
identity，并移除了该形态的独立 `room_events`、Planner、Delivery、Inbox、用户投影与 Sync Log
逐消息写入。真实主机 A/B 仍显示，单条消息的 PostgreSQL 热路径必须完成授权读取、房间顺序
锁定、canonical message 及其索引/WAL 写入，然后以同步提交确认。

把多个调用者的现有 `accept` 顺序放进一个外层事务不是本 ADR 的方案：它仍发出多次 SQL，且一条
业务拒绝或 PostgreSQL 错误会使“部分已提交 / 整批被报告失败”的语义无法成立。`fsync=off` 和
`synchronous_commit=off` 同样不是接受消息的默认方案，因为服务端不能 ACK 一条崩溃后可能丢失的
私聊消息。

## 决定

为仅包含普通文本、无附件、无提及、无回复、无转发且已使用 `room_log` 的 direct message 建立
一个显式的 `V2AtomicRoomWriteBatchStore` 边界。网关侧的 `V2SendMessageAdmissionBatcher` 使用
1...25ms 的有界等待，配置可收集 2...128 条请求；当前代码允许的上限不是生产推荐值，未测拓扑
仍从 8/16/32 开始。**只有 PostgreSQL Store 已一次原子提交对应兼容子批时才恢复客户端 ACK**。
默认关闭，未实现原子 SQL 时不得用普通 `V2RoomWriteStore.accept` 冒充批处理。

PostgreSQL 实现必须遵守：

1. 一个完整路径 SQL batch 可以包含同一房间的多个 command，但仅限于已建立、无待处理资料/首次回复/陌生人
   额度副作用，且已使用 durable room command credit 的 plain direct send。batcher 先给独立房间各一个
   公平席位，再用空余容量按 arrival order 填充这些房间的后续 command；PostgreSQL 对相同 `room_id`
   分配连续 cursor，并只把 `rooms`/`room_admission` 更新到该 room 的最后一个输入。任何冷启动、策略
   副作用、重复 operation key 或不满足前提的同房间组合都在写前回退单条路径。
2. 批内房间组按稳定 `room_id` 顺序取得 message-operation / room 锁，避免多房间事务与另一个批次
   形成 A→B / B→A 死锁；每个命令的 `(sender_id, client_message_id)` 唯一事实仍是幂等栅栏。
3. 逐条执行 member revision、冻结、block、陌生人额度、媒体、mention、reply 与 capacity 检查。
   任何有额外持久副作用（审核、陌生人额度消费、首次 reply 标记、profile/capability mutation）或
   既有 operation 的命令回退原单条事务，不能让其污染普通批。无副作用的 capacity rejection 可作为
   batch 内独立 outcome 返回。
4. 合格普通纯文本命令通过 JSONB set-based CTE 完成 `rooms`、需要时的 `room_admission` 和
   `messages(message_row event)` 写入，不再为该 accepted event 写独立 `room_events`。写入 input
   ordinal 与 accepted outcome 一一对应；结果计数不足或多余一律回滚并作为
   `corruptPersistenceState` 处理。
5. 事务重试使用同一 immutable request（含 message/event/plan ID）；提交之后才更新本地 direct
   policy cache、提交 shard credit、发布 foreground waterline 与 shadow 请求。
6. fast-append cache 只保存按 revision 固定的授权、membership、capacity profile 与 shard lease
   hint，不保存高频 room/timeline cursor。conditional SQL 先锁当前 room 行，再从该行原子分配下一
   sequence；peer append 不再仅因 cursor 变化造成无意义 fallback。
7. 批处理分类器只给出 advisory compatibility partition。缓存命中不是授权；每个 partition 仍在
   PostgreSQL 中重复验证完整 revision fence。相同 room 若在分类期间落入不同 partition，batcher
   必须退回一个完整原子批，禁止拆到不同事务。
8. shard credit 必须先由 PostgreSQL 原子预扣，再由 actor 发放。一个 Swift micro-batch 通过一次
   actor 调用消费已预留 credits，只在确实需要新的 durable reservation 时挂起；崩溃最多浪费未用
   额度，不能超卖 command window。

## 不变量

- ACK 表示整条 canonical 消息和 room cursor 的恢复事实已经在 durable PostgreSQL transaction 中提交。
- 同一 room 内的 accepted `room_sequence` 单调且没有洞；重试返回原结果，不新建 event。
- 批处理不改变授权的数据库真相，缓存只能作为预读优化，不能替代事务内的 revision-fenced 检查。
- room sequence 的权威值只来自持有 `rooms` 行锁的 PostgreSQL 事务，不来自进程缓存。
- 单条错误不应放大为整批回滚；若数据库级错误导致整批回滚，所有请求以同一个 retryable 错误返回，
  客户端以原 operation ID 重试。

## 渐进实施与回退

1. 已完成：领域层 immutable batch request、原子 Store 协议与 FIFO bounded batcher；没有原子 Store
   时不会启用。
2. 已完成：抽取 direct 普通文本的预检/持久化参数，加入 JSONB set-based CTE；真实 PostgreSQL
   集成测试覆盖两个已建立 direct room 的原子 append，以及富消息/策略副作用的单条回退。
3. 已完成：部署开关、批处理命中指标、独立房间与已建立 hot direct room 的 PostgreSQL 集成回归。
   该实现不支持 batch size 1，关闭即是等价 baseline。真实主机 A/B 已证明：两个成员的公网私聊在
   20ms 延迟下只能形成约 2 请求/批，P95 反而恶化；同一场景必须保持 1--2ms 互动延迟，除非实际
   队列填充已经证明可摊销更长等待。当前部署 profile 以 `400 requests / 1s` 作为 20ms 长等待的
   门槛，对应至少预测 8 条请求可摊销一批；真实主机 A/B 已验证双成员房间不命中、100 房间 600 msg/s
   命中并形成约 10.5 条/批。真实主机 A/B 仍须按 workload 分别决定是否启用。
4. 已完成：R29 将 cache/policy/credit/finalization 的 per-message actor hop 收敛为每 micro-batch
   有界调用，并按 fast/standard compatibility partition 执行。50,000 在线、500→5,000 msg/s
   单 Gateway 梯度已排空且无拒绝；适用边界和原始报告位置见
   [R29 capacity record](../09-capacity/direct-room-log-50000-gradient-r29-2026-08-27.md)。该记录没有
   显式 room-log pull、审核、媒体、回复或多 Gateway，不能外推为完整 IM 或生产 SLO。

将开关设为 `0` 或移除 batcher 即回退到当前单条事务；数据格式没有变化，不要求迁移或删除数据。

## 验证标准

每个 A/B arm 均从同一干净 schema/数据形状开始，保持 `fsync=on`、`synchronous_commit=on`、
`full_page_writes=on`，并记录：ACK/s、message/room-log/heartbeat p95/p99、失败率、每 message
transaction/WAL bytes/WAL fsync、top SQL、lock wait、checkpoint 与连接池队列。通过的前提是没有
logical event/message 计数差、sequence hole、重复 event ID 或授权回归；吞吐提高但 p99、错误率
或恢复一致性变差不算成功。对于 `message_row` 形态，审计必须确认对应独立 `room_events` 行为 0，
并通过 logical room-log pull 验证可恢复事件数，而不是继续要求两张表行数相等。
