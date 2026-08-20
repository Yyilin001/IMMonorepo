# ADR-018：有序私聊 room-log 原子微批

状态：已接受，实施中
日期：2026-08-21
所有者：消息平台主管

## 背景

ADR-017 已使普通私聊只有 `messages` 与 `room_events` 两个不可缺少的消息事实，并移除了
Planner、Delivery、Inbox、用户投影与 Sync Log 的逐消息重复写入。真实主机 A/B 仍显示，单条
消息的 PostgreSQL 热路径必须完成授权读取、房间顺序锁定、两条 canonical 记录及其索引/WAL
写入，然后以同步提交确认。

把多个调用者的现有 `accept` 顺序放进一个外层事务不是本 ADR 的方案：它仍发出多次 SQL，且一条
业务拒绝或 PostgreSQL 错误会使“部分已提交 / 整批被报告失败”的语义无法成立。`fsync=off` 和
`synchronous_commit=off` 同样不是接受消息的默认方案，因为服务端不能 ACK 一条崩溃后可能丢失的
私聊消息。

## 决定

为仅包含普通文本、无附件、无提及、无回复、无转发且已使用 `room_log` 的 direct message 建立
一个显式的 `V2AtomicRoomWriteBatchStore` 边界。网关侧的 `V2SendMessageAdmissionBatcher` 最多等待
2ms，最多收集 16--32 条请求；**只有 PostgreSQL Store 已一次原子提交整批时才恢复客户端 ACK**。
默认关闭，未实现原子 SQL 时不得用普通 `V2RoomWriteStore.accept` 冒充批处理。

PostgreSQL 实现必须遵守：

1. 先按 `room_id` 分组，保持同一房间的到达顺序；一个 SQL batch 对同一房间至多取一个可持久化
   command，其余命令留到下一轮，避免同一 `rooms` 行被无定义地重复 `UPDATE`。
2. 批内房间组按稳定 `room_id` 顺序取得 message-operation / room 锁，避免多房间事务与另一个批次
   形成 A→B / B→A 死锁；每个命令的 `(sender_id, client_message_id)` 唯一事实仍是幂等栅栏。
3. 逐条执行 member revision、冻结、block、陌生人额度、媒体、mention、reply 与 capacity 检查。
   任何有额外持久副作用（审核、陌生人额度消费、首次 reply 标记、profile/capability mutation）或
   业务拒绝的命令回退原单条事务，不能让其污染普通批。
4. 合格命令只通过一个 JSONB/`UNNEST` 输入的 CTE 完成 `rooms`、`room_admission`、`messages` 和
   `room_events` 写入。写入 input ordinal 与 accepted outcome 一一对应；结果计数不足或多余一律
   回滚并作为 `corruptPersistenceState` 处理。
5. 事务重试使用同一 immutable request（含 message/event/plan ID）；提交之后才更新本地 direct
   policy cache、提交 shard credit、发布 foreground waterline 与 shadow 请求。

## 不变量

- ACK 表示整条 canonical 消息和 room cursor 的恢复事实已经在 durable PostgreSQL transaction 中提交。
- 同一 room 内的 accepted `room_sequence` 单调且没有洞；重试返回原结果，不新建 event。
- 批处理不改变授权的数据库真相，缓存只能作为预读优化，不能替代事务内的 revision-fenced 检查。
- 单条错误不应放大为整批回滚；若数据库级错误导致整批回滚，所有请求以同一个 retryable 错误返回，
  客户端以原 operation ID 重试。

## 渐进实施与回退

1. 已完成：领域层 immutable batch request、原子 Store 协议与 FIFO bounded batcher；没有原子 Store
   时不会启用。
2. 实施中：抽取 direct 普通文本的预检/持久化参数，加入单条与多条都使用的 batch CTE，并以真实
   PostgreSQL 集成测试验证重试、顺序、幂等、权限变更和错误计数。
3. 验证后：增加部署开关，先以 batch size 1 验证等价，再依次测试 8、16、32 和 1--2ms delay。

将开关设为 `0` 或移除 batcher 即回退到当前单条事务；数据格式没有变化，不要求迁移或删除数据。

## 验证标准

每个 A/B arm 均从同一干净 schema/数据形状开始，保持 `fsync=on`、`synchronous_commit=on`、
`full_page_writes=on`，并记录：ACK/s、message/room-log/heartbeat p95/p99、失败率、每 message
transaction/WAL bytes/WAL fsync、top SQL、lock wait、checkpoint 与连接池队列。通过的前提是没有
消息/事件计数差、sequence hole、重复 event 或授权回归；吞吐提高但 p99、错误率或恢复一致性变差
不算成功。
