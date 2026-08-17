# Message projection sharing rollout runbook

状态：current-2 代码、在线 expand SQL、回填/GC 和聚合指标已提供；执行生产变更仍需
数据库备份、容量审批、真实数据抽样和回滚决策人。本 runbook 不把本机测试当作生产
证据。

## 变更物与硬门槛

- clean bootstrap：`IMV2/sql/schema.sql`（`im-v2-current-2`）；
- 旧库在线扩展：
  `IMV2/sql/changes/2026-08-17-message-projection-sharing-expand.sql`；
- fan-out accepted-message 窄引用扩展：
  `IMV2/sql/changes/2026-08-17-fanout-payload-reference-expand.sql`；
- control-store accepted body 复用扩展：
  `IMV2/sql/changes/2026-08-18-message-projection-room-event-storage-expand.sql`；
- 最终不可逆 contract：
  `IMV2/sql/changes/2026-08-17-message-projection-sharing-contract.sql`；
- 所有控制库和每个物理 user-shard `(database, schema)` 必须先完成 expand；任一未完成，
  current-2 gateway 会因 schema readiness 失败而拒绝监听。

变更前记录每个物理库的备份/PITR 恢复点和以下基线：

```sql
SELECT pg_total_relation_size('im_v2.user_projection_versions') AS projection_bytes,
       pg_total_relation_size('im_v2.message_projection_states') AS state_bytes;
SELECT COUNT(*) FILTER (WHERE projection_kind = 'message') AS message_versions,
       COUNT(*) FILTER (WHERE projection_kind = 'message' AND payload IS NOT NULL) AS inline_rows,
       COUNT(*) FILTER (WHERE projection_kind = 'message' AND message_state_id IS NOT NULL) AS referenced_rows
FROM im_v2.user_projection_versions;
```

旧库在 expand 前没有 state table，第一条 relation 查询应只查询现有表。不得把连接串、
message/user/room ID 或 payload 贴入工单和日志。

## Phase 1：expand 与 dual

1. 先在 staging 用生产 schema dump 执行 expand，并确认 canonical drift 测试等价；
2. 在每个库独立执行 expand SQL。`CREATE INDEX CONCURRENTLY` 失败时先查询
   `pg_index.indisvalid`，只删除同名 invalid index 后重试失败语句；不要重跑已成功的
   非幂等 `ALTER TABLE`；
3. 部署 current-2：

```text
IM_V2_MESSAGE_PROJECTION_WRITE_MODE=dual
IM_V2_MESSAGE_PROJECTION_READ_MODE=prefer_shared
IM_V2_MESSAGE_PROJECTION_STATE_RETENTION_SECONDS=604800
IM_V2_FANOUT_PAYLOAD_WRITE_MODE=body
```

4. 确认新 message 的 state/reference/inline 三者都有，Snapshot、增量同步、编辑、撤回、
   redaction、附件下载和跨物理 shard fan-out 正常；
5. 观察 `im_v2_message_projection_backfill_estimated_rows` 向零收敛。它来自 partial-index
   planner estimate，运行 `ANALYZE im_v2.user_projection_versions` 后再作切换判断。

回填使用 bounded transaction、`FOR UPDATE SKIP LOCKED` 和 migration fence；不能用一个
全表 UPDATE 替代。若出现 `message projection backfill failed`，停止切换，检查首个错误
legacy payload/state collision；不得跳过坏行或手改 state。

## Phase 2：shared 写入与正文收缩

只有以下条件全部满足才切换：

- backfill estimate 经 `ANALYZE` 后为 0，且精确审计也为 0；
- Snapshot payload 与 inline 基线抽样完全相等；
- fan-out/user projection paused backlog 为 0；
- PostgreSQL WAL、replica lag、CPU、locks 和 autovacuum 在批准范围内。

精确审计：

```sql
SELECT COUNT(*) AS missing_reference
FROM im_v2.user_projection_versions
WHERE projection_kind = 'message' AND message_state_id IS NULL;

SELECT COUNT(*) AS mismatched_dual_payload
FROM im_v2.user_projection_versions AS version
JOIN im_v2.message_projection_state_values AS state
  ON state.state_id = version.message_state_id
WHERE version.projection_kind = 'message'
  AND version.payload IS NOT NULL
  AND version.payload <> state.payload;

SELECT COUNT(*) AS broken_reference
FROM im_v2.user_projection_versions AS version
LEFT JOIN im_v2.message_projection_state_values AS state
  ON state.state_id = version.message_state_id
WHERE version.projection_kind = 'message' AND state.state_id IS NULL;
```

三项必须为 0。随后滚动配置为：

```text
IM_V2_MESSAGE_PROJECTION_WRITE_MODE=shared
IM_V2_MESSAGE_PROJECTION_READ_MODE=prefer_shared
```

shared 模式下同一 backfill worker 会先比较 `state.payload = version.payload`，再在同一事务
清空 inline payload。观察：

- `im_v2_message_projection_inline_payload_estimated_rows` → 0；
- `im_v2_message_projection_references_estimated_rows` 与 message projection 总量同阶；
- `im_v2_message_projection_states_relation_bytes` 的增长与 distinct message revisions 同阶，
  而不是 recipient rows；
- Snapshot failure、媒体 403、投影 poison、replica lag 和 WAL 不得恶化。

清空 JSONB 会产生 dead tuples，relation 文件不会立即缩小。先让 autovacuum 回收可复用
空间；是否 `pg_repack`/维护窗口重写表必须由 DBA 单独审批，禁止在线 `VACUUM FULL`。

所有 binary 都已具备 `COALESCE(fanout payload, message state)` 读取能力，并且 fan-out
nullable-payload expand 已在每个物理 user store 验证后，才切换：

```text
IM_V2_FANOUT_PAYLOAD_WRITE_MODE=reference
```

该模式只收缩 `message.accepted` 且 event payload 与 state payload 完全相等的行；编辑、撤回、
审核和其他增量 delta 继续保留 payload。独立的 bounded backfill 使用
`FOR UPDATE SKIP LOCKED` 清理历史 accepted-message 副本。以下三项必须为 0：

```sql
SELECT COUNT(*) AS accepted_inline
FROM im_v2.fanout_sync_payloads AS shared
JOIN im_v2.room_events AS event ON event.event_id = shared.source_event_id
WHERE event.event_type = 'message.accepted'
  AND shared.projection_kind = 'message' AND shared.payload IS NOT NULL;

SELECT COUNT(*) AS accepted_missing_state
FROM im_v2.fanout_sync_payloads AS shared
JOIN im_v2.room_events AS event ON event.event_id = shared.source_event_id
LEFT JOIN im_v2.message_projection_state_values AS state
  ON state.state_id = shared.message_state_id
WHERE event.event_type = 'message.accepted'
  AND shared.projection_kind = 'message' AND state.state_id IS NULL;

SELECT COUNT(*) AS accepted_payload_mismatch
FROM im_v2.fanout_sync_payloads AS shared
JOIN im_v2.room_events AS event ON event.event_id = shared.source_event_id
JOIN im_v2.message_projection_state_values AS state
  ON state.state_id = shared.message_state_id
WHERE event.event_type = 'message.accepted'
  AND shared.projection_kind = 'message'
  AND COALESCE(shared.payload, state.payload) <> event.payload;
```

控制 schema 的 accepted revision 1 state 还会把重复正文压缩到 room event。先确认 view 逻辑
值与事件完全相等，再观察 bounded worker 把以下第一项收敛为 0；独立 user shard 没有同库
room event，保留 inline 属正常情况：

```sql
SELECT COUNT(*) AS compactable_inline
FROM im_v2.message_projection_states AS state
JOIN im_v2.room_events AS event ON event.event_id = state.state_event_id
WHERE state.payload_storage = 'inline'
  AND state.message_revision = 1 AND state.variant_key = 0
  AND state.payload = event.payload;

SELECT COUNT(*) AS broken_room_event_reference
FROM im_v2.message_projection_states AS state
LEFT JOIN im_v2.message_projection_state_values AS value
  ON value.state_id = state.state_id
WHERE state.payload_storage = 'room_event' AND value.state_id IS NULL;
```

第二项必须始终为 0。压缩产生 dead tuples，沿用 autovacuum/repack 边界，禁止在线
`VACUUM FULL`。

## Phase 3：strict shared read 与 contract

精确确认 missing reference、broken reference、inline payload 都为 0，并完成至少一个完整
业务高峰和一次 gateway restart 后，切：

```text
IM_V2_MESSAGE_PROJECTION_WRITE_MODE=shared
IM_V2_MESSAGE_PROJECTION_READ_MODE=shared
```

全新空库或已经完成上述精确审计的单机测试环境可使用
`IMV2/docker-compose.gateway-shared.yml` 固化这组 shared/reference 配置；不得仅因为文件名
存在就把该 overlay 套到未回填的旧库。

继续保留 expand 约束和 partial indexes一个批准的回滚观察窗。只有观察窗结束、数据库
备份可恢复、所有旧 binary 已禁止部署时，才人工执行 contract SQL。该脚本会要求每个
message row 为窄引用并删除两个迁移期索引；执行前再次保存三项精确审计结果。

## 回滚

- **dual 阶段/尚未清空 inline**：回滚 binary 或配置到 `write=inline/read=inline`，state
  与 reference 可保留，不影响旧读；修复后重新从 dual 开始。
- **shared 收缩已经开始但 contract 未执行**：不能回滚到不识别 state 的 current-1
  binary。使用 current-2 的 `write=dual/read=prefer_shared` 停止继续收缩并维持可读；若
  必须回到 current-1，只能从收缩前备份/PITR 恢复并按事件窗口重放。
- **contract 已执行**：只支持 current-2 shared 路径；回退架构需要新的经审批 expand，
  不能临时 drop constraint 或批量伪造 payload。

任何阶段都不得删除 `message_projection_states`、解除 RESTRICT FK、推进用户 checkpoint
或跳过 fan-out delivery 来“恢复服务”。

## 收尾证据

保存不含标识和正文的：schema contract、配置 phase、三项审计计数、relation/TOAST/index
bytes、WAL bytes/s、DB CPU、buffer hit、autovacuum 时长、Snapshot p95/p99、消息端到端
p95/p99、错误率、replica lag、开始/结束时间、审批和回滚决策。最终收益必须来自同一
数据分布和同一负载的前后对比，不能用理论 25%–40% 替代。
