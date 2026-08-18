# ADR-014：消息投影正文单写与用户窄引用

状态：已接受并实施 expand 阶段
日期：2026-08-17
所有者：存储平台主管

## 背景

`user_projection_versions` 是每用户 Snapshot V3 的应用级 MVCC。旧模型把完整消息
JSON 写入每位接收者的每个版本；直接消息至少复制两次，群消息则随接收者线性放大。
实测样本约 202 万 projection rows、99.7 万条不同消息、约 2.5 GiB relation，正文
逻辑字节约 1.33 GiB 且直接消息接近完整双份。它同时放大 heap/TOAST、索引维护、
WAL、buffer cache 和 VACUUM，不是单纯磁盘容量问题。

用户是否收到消息、何时生效/失效是每用户事实，不能合并；消息同一 revision 的正文
和不可变 envelope 却是房间事实，可以共享。因此保留 `user_projection_versions` 的
`user_id + MVCC sequence + source_event_id + room scope`，把完整当前值移到物理 user
store 内的 `message_projection_states`，用户行只保存 `message_state_id`。

## 决定与不变量

- 每个 `(message_id, message_revision, variant_key)` 只有一个不可变 state；稳定 UUID
  由该语义键计算，使控制库、远端 user shard、重试和用户迁移独立收敛。
- `variant_key=0` 是当前 canonical 值，为未来按接收者生成安全变体保留显式命名空间，
  禁止偷偷按用户改写同一 state。
- 远端 user shard 的 state 保存一份自包含 Snapshot V3 消息值；控制库/同物理 user store
  对 revision 1 canonical accepted state 可把正文复用为同一不可变 `room_event`，state 只保留
  identity/revision/variant 元数据。`message_projection_state_values` 统一还原逻辑 payload，
  客户端 wire protocol 和 Snapshot V3 编码不变。
- `user_projection_versions` 仍是唯一授权与可见性事实。仅存在 shared state 绝不授权
  snapshot 或媒体下载；读取必须先命中该用户当前/基线时刻有效的 projection reference。
- state insert 使用单条 data-modifying CTE 完成 `INSERT ... ON CONFLICT DO NOTHING` 与
  逐字段/JSONB 等值校验。普通消息主写 CTE 直接创建 room-event-backed state，不增加一次
  应用/数据库往返；相同重试幂等，不同正文碰撞必须失败，不允许 last-write-wins。极少数并发
  `DO NOTHING` 冲突会用下一条语句的新 MVCC snapshot 再确认一次，避免把已提交的相同值误判
  为冲突，同时不使用会制造 heap/WAL 版本的 no-op `DO UPDATE`。
- 控制写事务先提交 message/event，再在同一事务创建 canonical state。跨 store fan-out
  每个物理目标 shard 复制一次 state，再提交每用户 inbox/sequence/log。
- 编辑、撤回和审核 redaction 生成新 revision；撤回 state 必须删除正文、附件、提及、
  entity、reply 和 forward 字段。历史 revision 只由仍存活的 MVCC/fan-out 引用保留。
- Snapshot builder 以 join 还原原 payload；媒体授权以用户引用 join state，不能从
  shared table 直接判断可见性。
- 用户 shard 迁移先复制所有被该用户 projection/log 引用的稳定 state，再复制引用；
  fingerprint 比较还原后的逻辑 payload 和 state identity。
- GC 只删除超过 grace、没有 projection/fan-out 引用、且不是控制库当前活跃 message
  revision 的 state；两条 `ON DELETE RESTRICT` FK 是并发竞争的最终保护。
- `room_events` 是 append-only 事实。数据库 trigger 拒绝 UPDATE/DELETE；逻辑 view 还会核对
  event ID、room、message、revision 和 event type，不匹配时 fail closed，不返回伪造正文。
- bounded `FOR UPDATE SKIP LOCKED` worker 只压缩 `payload = room_event.payload` 的 revision 1
  canonical state。没有同库 room event 的独立 user shard 保留一份 inline 正文，不引入跨库读。

## 迁移决定

采用 expand/dual/backfill/shared/contract，不执行一次性 200 万行 UPDATE：

1. current-2 expand 增加 nullable reference、新表、`NOT VALID` 后验证的约束和
   concurrent partial indexes；
2. `write=dual/read=prefer_shared`：新行双写，bounded `SKIP LOCKED` worker 为旧行挂
   reference，但保留 inline payload；
3. 指标与抽样一致性通过后切 `write=shared/read=prefer_shared`；worker 只有在 state
   JSONB 等值后才把 inline payload 置空；
4. inline/backfill 指标为零且稳定后切 `read=shared`；
5. 回滚窗口结束后才可人工执行 contract SQL。contract 不是 current-2 启动前置。

Snapshot keyset 的主键已覆盖 `user + kind + entity + valid_from` 排序前缀，读取 payload/source
仍必须访问 heap；原额外 `user_projection_versions_snapshot_scan_idx` 不能形成 index-only read，
却参与每个版本 INSERT/close，因此已由在线 migration 并发删除。shared/reference 压测必须使用
`docker-compose.gateway-shared.yml`；仅有代码能力而仍运行 dual/body 配置不会获得正文去重收益。

在上述用户投影 expand 之后，执行
`2026-08-18-message-projection-room-event-storage-expand.sql`：增加物理存储标记、逻辑 view、
append-only trigger 和 bounded compaction 索引。先部署能读逻辑 view 的 binary，再允许压缩；
压缩后不能直接回滚到只读 base-table nullable payload 的旧 binary。

运行步骤、审计 SQL 和回滚边界见
[message projection sharing runbook](../10-operations/message-projection-sharing-runbook.md)。

## 备选方案与拒绝理由

- 只压缩 JSONB/提升 ESSD：降低部分 I/O，不能消除 WAL、VACUUM、cache 和接收者倍增。
- 正文只留控制库、Snapshot 跨库查询：把用户同步正确性依赖改成跨库 read join，增加
  故障域和延迟，拒绝。
- 只保留最新 message row、不保留 revision state：会破坏正在固定 base sequence 上
  构建的 Snapshot V3，拒绝。
- 把每用户行完全删除：会丢失授权、membership removal 和 MVCC 生效区间，拒绝。
- 用 shard-local `BIGSERIAL`：跨 shard fan-out/迁移需要 ID remap，扩大重复与恢复边界，
  因而使用稳定 UUID。

## 预期与验证边界

以当前直接消息约两位接收者、平均 payload 约 698 B 的样本，正文 heap/TOAST 理论上
接近减半；控制库再复用已存在的 `room_event` 后，revision 1 state 不再保存第二份 canonical
JSONB。连同新增窄引用、state 元数据和索引，预期数据库 CPU、WAL 与 cache 压力进一步下降，
但读取多一次主键 join。所有百分比都是容量假设，不是生产承诺；必须用同一数据快照比较 transaction
rate、WAL bytes、buffer hit、p95/p99、relation/TOAST bytes 和 VACUUM 时间。群成员数越
大收益越高，但当前 standard fan-out 的其他每用户同步事实仍然线性存在。
